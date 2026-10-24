import CoreGraphics
import Foundation
import Testing
@testable import DiffCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "delta-more-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: Hex

@Test func hexRowsByOffset() {
    let a = Data((0..<40).map { UInt8($0) })
    var b = a
    b[20] = 0xFF
    #expect(hexRowCount(a, b) == 3)
    #expect(differingHexRows(a, a).isEmpty)
    #expect(differingHexRows(a, b) == [1])
    #expect(differingHexRows(a, a.prefix(35)) == [2])
    #expect(hexRow(a, 2) == [UInt8](32..<40))
}

// MARK: Tables

@Test func csvParsing() {
    let rows = parseDelimited("a,\"b,c\",\"say \"\"hi\"\"\"\n1,\"two\nlines\",3\n", separator: ",")
    #expect(rows == [["a", "b,c", "say \"hi\""], ["1", "two\nlines", "3"]])
    #expect(parseDelimited("x\ty\n", separator: "\t") == [["x", "y"]])
    #expect(parseDelimited("a,,b", separator: ",") == [["a", "", "b"]])
}

@Test func tableDiffByKey() {
    let l = [["id", "name"], ["1", "ann"], ["2", "bob"], ["3", "cy"]]
    let r = [["id", "name"], ["3", "cy"], ["2", "BOB"], ["4", "dee"]]
    let d = diffTables(l, r, keyColumns: [0])
    #expect(d.map(\.kind) == [.same, .leftOnly, .changed, .same, .rightOnly])
    #expect(d[2].changedColumns == [1])
}

@Test func tableDiffWithoutKeyAndDuplicates() {
    let d = diffTables([["a"], ["b"], ["c"]], [["a"], ["B"], ["c"], ["d"]])
    #expect(d.map(\.kind) == [.same, .changed, .same, .rightOnly])
    let dup = diffTables([["k", "1"], ["k", "2"]], [["k", "1"], ["k", "3"]], keyColumns: [0])
    #expect(dup.map(\.kind) == [.same, .changed])
}

// MARK: Images

private func image(_ w: Int, _ h: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let (r, g, b) = fill(x, y), i = (y * w + x) * 4
        px[i] = r; px[i + 1] = g; px[i + 2] = b
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Test func imageCompareToleranceAndSize() {
    let a = image(4, 4) { _, _ in (100, 100, 100) }
    let b = image(4, 4) { x, y in x == 1 && y == 2 ? (110, 100, 100) : (100, 100, 100) }
    #expect(compareImages(a, a).differingPixels == 0)
    #expect(compareImages(a, b).differingPixels == 1)
    #expect(compareImages(a, b, tolerance: 10).differingPixels == 0)
    let wide = image(6, 4) { _, _ in (100, 100, 100) }
    let d = compareImages(a, wide)
    #expect(d.width == 6 && d.height == 4 && d.differingPixels == 8)
    #expect(d.mask?.width == 6)
}

// MARK: Patches

@Test func patchRoundTrips() throws {
    let cases: [([String], [String])] = [
        (["a", "b", "c"], ["a", "B", "c"]),
        ([], ["new", "file"]),
        (["gone", "too"], []),
        ((1...30).map(String.init), (1...30).map(String.init).filter { $0 != "3" } + ["31"]),
        (["x"], ["start", "x", "end"]),
    ]
    for (a, b) in cases {
        let patch = unifiedDiff(left: a, right: b, hunks: diffLines(a, b), leftName: "a", rightName: "b")
        #expect(try applyPatch(patch, to: a) == b)
    }
}

@Test func patchToleratesOffsetAndRejectsMismatch() throws {
    let a = ["1", "2", "3", "4", "5"], b = ["1", "2", "THREE", "4", "5"]
    let patch = unifiedDiff(left: a, right: b, hunks: diffLines(a, b), leftName: "a", rightName: "b")
    #expect(try applyPatch(patch, to: ["0", "0"] + a) == ["0", "0"] + b)
    #expect(throws: PatchError.hunkFailed(1)) { try applyPatch(patch, to: ["unrelated"]) }
    #expect(throws: PatchError.self) { try applyPatch("not a patch", to: a) }
}

// MARK: Snapshots and archives

@Test func snapshotRoundTripAndCompare() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appending(path: "d")
    try write("hello", dir.appending(path: "a.txt"))
    try write("x", dir.appending(path: "sub/b.txt"))
    let snap = try FolderSnapshot.capture(dir)
    #expect(Set(snap.items.map(\.path)) == ["a.txt", "sub", "sub/b.txt"])
    let file = root.appending(path: "s.deltasnap")
    try snap.write(to: file)
    let back = try FolderSnapshot.read(file)
    #expect(back.items.count == snap.items.count && back.root == snap.root)

    try write("changed!", dir.appending(path: "a.txt"))
    try write("new", dir.appending(path: "c.txt"))
    let index = indexEntries(try compareFolders(left: .snapshot(back), right: .directory(dir)))
    #expect(index["a.txt"]?.status != .same)
    #expect(index["c.txt"]?.status == .rightOnly)
    #expect(index["sub/b.txt"]?.status == .same)
}

@Test func archiveExtracts() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("inside", root.appending(path: "src/in.txt"))
    let zip = root.appending(path: "a.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", root.appending(path: "src").path, zip.path]
    try ditto.run(); ditto.waitUntilExit()
    #expect(isArchive(zip) && isArchive(URL(fileURLWithPath: "/x.tar.gz")) && !isArchive(URL(fileURLWithPath: "/x.txt")))
    let out = try extractArchive(zip)
    defer { try? FileManager.default.removeItem(at: out) }
    #expect(try String(contentsOf: out.appending(path: "in.txt"), encoding: .utf8) == "inside")
    #expect(throws: ArchiveError.self) { try extractArchive(root.appending(path: "src/in.txt")) }
}

// MARK: Reports

@Test func reportsEscapeHTML() {
    let a = ["<b>&"], b = ["<i>"]
    let html = htmlTextReport(left: a, right: b, hunks: diffLines(a, b), leftName: "l\"", rightName: "r")
    #expect(html.contains("&lt;b&gt;&amp;") && html.contains("&lt;i&gt;") && !html.contains("<b>&"))
    #expect(html.contains("class=\"chg\""))
    let entry = FolderEntry(name: "<x>", relativePath: "<x>", left: nil, right: nil, status: .rightOnly, children: nil)
    #expect(htmlFolderReport(entries: [entry], leftName: "L", rightName: "R").contains("&lt;x&gt;"))
}

// MARK: Folder merge

@Test func folderMergeDecisions() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appending(path: "base"), left = root.appending(path: "left"), right = root.appending(path: "right")
    let files: [(String, String?, String?, String?)] = [
        // path, base, left, right
        ("same.txt", "1", "1", "1"),
        ("leftEdit.txt", "1", "L", "1"),
        ("rightEdit.txt", "1", "1", "R"),
        ("bothSame.txt", "1", "X", "X"),
        ("conflict.txt", "1", "L", "R"),
        ("leftDeleted.txt", "1", nil, "1"),
        ("deleteVsEdit.txt", "1", nil, "R"),
        ("addedLeft.txt", nil, "new", nil),
        ("addedBothDiff.txt", nil, "a", "b"),
    ]
    for (path, b, l, r) in files {
        if let b { try write(b, base.appending(path: path)) }
        if let l { try write(l, left.appending(path: path)) }
        if let r { try write(r, right.appending(path: path)) }
    }
    let items = Dictionary(uniqueKeysWithValues: try planFolderMerge(base: base, left: left, right: right).map { ($0.relativePath, $0.action) })
    #expect(items == [
        "same.txt": .takeLeft, "leftEdit.txt": .takeLeft, "rightEdit.txt": .takeRight, "bothSame.txt": .takeLeft,
        "conflict.txt": .conflict, "leftDeleted.txt": .delete, "deleteVsEdit.txt": .conflict,
        "addedLeft.txt": .takeLeft, "addedBothDiff.txt": .conflict,
    ])
    let out = root.appending(path: "out")
    let ops = folderMergeOps(try planFolderMerge(base: base, left: left, right: right), left: left, right: right, output: out)
    #expect(ops.contains(.copy(from: right.appending(path: "rightEdit.txt"), to: out.appending(path: "rightEdit.txt"))))
    #expect(!ops.contains { if case let .copy(_, to) = $0 { to.lastPathComponent == "conflict.txt" } else { false } })
}

@Test func detectsSessionKind() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, _ data: Data = Data("x".utf8)) throws -> String {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url.path
    }
    let a = try file("a.txt"), b = try file("b.txt"), bin = try file("b.bin", Data([0, 1, 2]))
    #expect(OpenRequest.Kind.detect([a, b]) == .text)
    #expect(OpenRequest.Kind.detect([a, bin]) == .hex)
    #expect(OpenRequest.Kind.detect([try file("1.png"), try file("2.JPG")]) == .picture)
    #expect(OpenRequest.Kind.detect([try file("1.csv"), try file("2.tsv")]) == .table)
    #expect(OpenRequest.Kind.detect([root.path, try file("z.zip")]) == .folder)
    #expect(OpenRequest.Kind.detect([root.path, root.path, root.path]) == .folderMerge)
    #expect(OpenRequest.Kind.detect([a, b, a]) == .merge)
    #expect(OpenRequest.Kind.detect([a, root.path]) == nil)
}

@Test func ignoringTimestampsTreatsDateOnlyChangesAsSame() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let l = root.appending(path: "l"), r = root.appending(path: "r")
    try write("abc", l.appending(path: "touched.txt"))
    try write("abc", r.appending(path: "touched.txt"))
    try write("abc", l.appending(path: "edited.txt"))
    try write("abcd", r.appending(path: "edited.txt"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: l.appending(path: "touched.txt").path)
    #expect(indexEntries(try compareFolders(left: l, right: r))["touched.txt"]?.status == .rightNewer)
    let minor = indexEntries(try compareFolders(left: l, right: r, options: .init(ignoreTimestamps: true)))
    #expect(minor["touched.txt"]?.status == .same)
    #expect(minor["edited.txt"]?.status == .differs)
}
