import DiffCore
import Foundation

let usage = """
usage: delta <left> <right> [<base>] [--output <path>] [--wait] [--text] [--report <file.html>]

  delta a.txt b.txt              Text Compare (PDFs compare as text)
  delta a.bin b.bin              Hex Compare (any binary file)
  delta a.csv b.csv              Table Compare (.csv / .tsv)
  delta a.png b.png              Picture Compare
  delta dirA dirB                Folder Compare (folders, .zip/.tar archives, .deltasnap snapshots)
  delta local remote base --output merged
                                 Text Merge, saving to merged
  delta dirL dirR dirBase --output dirOut
                                 Folder Merge into dirOut
  --text     print a unified diff instead of opening the app (text files only)
  --report   write an HTML report instead of opening the app (text files or folders)
  --wait     block until the window closes (git difftool / mergetool)

exit status: 0 same or merged cleanly, 1 different or conflicts left, 2 error
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("delta: \(message)\n".utf8))
    exit(2)
}

var paths: [String] = []
var output: String?
var wait = false
var textMode = false
var report: String?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--output", "-o":
        guard let value = args.popFirst() else { fail("--output needs a file path") }
        output = URL(fileURLWithPath: value).standardizedFileURL.path
    case "--wait", "-w": wait = true
    case "--text", "-t": textMode = true
    case "--report":
        guard let value = args.popFirst() else { fail("--report needs a file path") }
        report = value
    case "--help", "-h": print(usage); exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        paths.append(URL(fileURLWithPath: arg).standardizedFileURL.path)
    }
}
guard paths.count == 2 || paths.count == 3 else { fail("expected 2 or 3 paths\n\n\(usage)") }

for path in paths where !FileManager.default.fileExists(atPath: path) { fail("no such file: \(path)") }
guard let kind = OpenRequest.Kind.detect(paths) else { fail("cannot compare a file with a folder") }

func lines(_ path: String) -> [String] {
    do { return splitLines(try TextDocument.load(URL(fileURLWithPath: path)).text) } catch { fail(error.localizedDescription) }
}

/// 0 when the two files have no line differences, else 1.
func diffStatus(_ a: String, _ b: String) -> Int32 {
    diffLines(lines(a), lines(b)).contains { $0.kind == .change } ? 1 : 0
}

if textMode {
    guard kind == .text else { fail("--text compares exactly two text files") }
    let a = lines(paths[0]), b = lines(paths[1])
    let hunks = diffLines(a, b)
    print(unifiedDiff(left: a, right: b, hunks: hunks, leftName: paths[0], rightName: paths[1]), terminator: "")
    exit(hunks.contains { $0.kind == .change } ? 1 : 0)
}

if let report {
    let html: String
    let differs: Bool
    switch kind {
    case .text:
        let a = lines(paths[0]), b = lines(paths[1]), hunks = diffLines(a, b)
        html = htmlTextReport(left: a, right: b, hunks: hunks, leftName: paths[0], rightName: paths[1])
        differs = hunks.contains { $0.kind == .change }
    case .folder:
        do {
            let entries = try compareFolders(left: URL(fileURLWithPath: paths[0]), right: URL(fileURLWithPath: paths[1]))
            html = htmlFolderReport(entries: entries, leftName: paths[0], rightName: paths[1])
            differs = entries.contains { $0.status != .same }
        } catch { fail(error.localizedDescription) }
    default: fail("--report works for two text files or two folders")
    }
    do { try Data(html.utf8).write(to: URL(fileURLWithPath: report)) } catch { fail(error.localizedDescription) }
    exit(differs ? 1 : 0)
}

if output != nil, kind != .merge, kind != .folderMerge { fail("--output needs three files or three folders: <left> <right> <base>") }

let marker = wait ? FileManager.default.temporaryDirectory.appending(path: "delta-\(UUID().uuidString).done").path : nil
let request = OpenRequest(kind: kind, paths: paths, output: output, waitMarker: marker)

// Prefer the app this binary ships in (Delta.app/Contents/MacOS/delta), even through a symlink.
let appURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = (appURL?.pathExtension == "app" ? ["-a", appURL!.path] : ["-b", "local.delta.app"]) + [request.url.absoluteString]
do {
    try open.run()
    open.waitUntilExit()
} catch {
    fail("could not launch Delta: \(error.localizedDescription)")
}
guard open.terminationStatus == 0 else { fail("could not launch Delta (is Delta.app built and registered?)") }

guard let marker else { exit(0) }
// shortcut: polls a marker file; if the app is force-quit the marker never appears and this waits until interrupted.
while !FileManager.default.fileExists(atPath: marker) { usleep(250_000) }
try? FileManager.default.removeItem(atPath: marker)

switch kind {
case .text: exit(diffStatus(paths[0], paths[1]))
case .merge:
    guard let output, FileManager.default.fileExists(atPath: output) else { exit(1) }
    exit(findConflicts(in: lines(output)).isEmpty ? 0 : 1)
default: exit(0)
}
