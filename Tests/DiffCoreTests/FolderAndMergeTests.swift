import Foundation
import Testing
@testable import DiffCore

/// Builds left/ and right/ trees in a fresh temp dir. Values are file contents; nil makes a directory.
private func makeTree(_ files: [String: String?], at root: URL, mtime: Date) throws {
    for (path, content) in files {
        let url = root.appending(path: path)
        if let content {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "delta-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func folderCompareStatuses() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
    let l = root.appending(path: "left"), r = root.appending(path: "right")
    try makeTree(["same.txt": "x", "sub/deep.txt": "1", "onlyL.txt": "l", "edit.txt": "aaa", "samesize.txt": "abc", ".DS_Store": "junk"], at: l, mtime: old)
    try makeTree(["same.txt": "x", "sub/deep.txt": "1", "onlyR/": nil, "samesize.txt": "xyz"], at: r, mtime: old)
    try makeTree(["edit.txt": "bbbb"], at: r, mtime: new)

    let index = indexEntries(try compareFolders(left: l, right: r))
    #expect(index["same.txt"]?.status == .same)
    #expect(index["sub"]?.status == .same)
    #expect(index["sub/deep.txt"]?.status == .same)
    #expect(index["onlyL.txt"]?.status == .leftOnly)
    #expect(index["onlyR"]?.status == .rightOnly)
    #expect(index["edit.txt"]?.status == .rightNewer)
    #expect(index[".DS_Store"] == nil)
    // Same size and time looks equal unless contents are checked.
    #expect(index["samesize.txt"]?.status == .same)
    let deep = indexEntries(try compareFolders(left: l, right: r, options: .init(compareContents: true)))
    #expect(deep["samesize.txt"]?.status == .differs)

    let masked = indexEntries(try compareFolders(left: l, right: r, options: .init(includeMasks: ["*.md"])))
    #expect(masked["same.txt"] == nil && masked["sub"] != nil)
}

@Test func syncPlanPerMode() {
    let L = URL(fileURLWithPath: "/L"), R = URL(fileURLWithPath: "/R")
    func e(_ name: String, _ s: EntryStatus) -> FolderEntry { FolderEntry(name: name, relativePath: name, status: s) }
    let entries = [e("a", .leftOnly), e("b", .rightOnly), e("c", .leftNewer), e("d", .rightNewer), e("f", .differs), e("g", .same)]
    let p = { (n: String, s: URL) in s.appending(path: n) }

    #expect(planSync(entries, left: L, right: R, mode: .updateRight) == [.copy(from: p("a", L), to: p("a", R)), .copy(from: p("c", L), to: p("c", R))])
    #expect(planSync(entries, left: L, right: R, mode: .updateBoth) == [
        .copy(from: p("a", L), to: p("a", R)), .copy(from: p("b", R), to: p("b", L)),
        .copy(from: p("c", L), to: p("c", R)), .copy(from: p("d", R), to: p("d", L)),
    ])
    #expect(planSync(entries, left: L, right: R, mode: .mirror) == [
        .copy(from: p("a", L), to: p("a", R)), .trash(p("b", R)), .copy(from: p("c", L), to: p("c", R)),
        .copy(from: p("d", L), to: p("d", R)), .copy(from: p("f", L), to: p("f", R)),
    ])
}

private extension FolderEntry {
    init(name: String, relativePath: String, status: EntryStatus) {
        self.init(name: name, relativePath: relativePath, left: nil, right: nil, status: status, children: nil)
    }
}

@Test func fileOperationsCopyAndDryRun() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appending(path: "a.txt"), dst = root.appending(path: "out/nested/a.txt")
    try "hi".write(to: src, atomically: true, encoding: .utf8)
    let ops = FileOperations()

    #expect(await ops.run([.copy(from: src, to: dst)], dryRun: true).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dst.path))
    #expect(await ops.run([.copy(from: src, to: dst)]).isEmpty)
    #expect(try String(contentsOf: dst, encoding: .utf8) == "hi")
    let failures = await ops.run([.copy(from: root.appending(path: "missing"), to: root.appending(path: "x"))])
    #expect(failures.count == 1)
}

@Test func mergeClean() {
    let base = ["a", "b", "c", "d", "e"]
    let left = ["a", "B", "c", "d", "e"], right = ["a", "b", "c", "D", "e", "f"]
    let chunks = merge3(base: base, left: left, right: right)
    #expect(!chunks.contains { $0.kind == .conflict })
    #expect(renderMerge(chunks, base: base, left: left, right: right) == ["a", "B", "c", "D", "e", "f"])
}

@Test func mergeConflictAndMarkers() {
    let base = ["a", "b", "c"], left = ["a", "L", "c"], right = ["a", "R", "c"]
    let chunks = merge3(base: base, left: left, right: right)
    #expect(chunks.map(\.kind) == [.stable, .conflict, .stable])
    let out = renderMerge(chunks, base: base, left: left, right: right)
    #expect(out == ["a", "<<<<<<< LEFT #1", "L", "||||||| BASE", "b", "=======", "R", ">>>>>>> RIGHT", "c"])
    let blocks = findConflicts(in: out)
    #expect(blocks == [ConflictBlock(id: 1, lines: 1..<8, left: ["L"], base: ["b"], right: ["R"])])
}

@Test func mergeSameChangeBothSides() {
    let base = ["a", "b"], same = ["a", "X", "b"]
    let chunks = merge3(base: base, left: same, right: same)
    #expect(chunks.contains { $0.kind == .both })
    #expect(renderMerge(chunks, base: base, left: same, right: same) == same)
}

@Test func mergeDeleteVersusModifyConflicts() {
    let base = ["a", "b", "c"], left = ["a", "c"], right = ["a", "B2", "c"]
    #expect(merge3(base: base, left: left, right: right).map(\.kind) == [.stable, .conflict, .stable])
}

@Test func mergeEmptyBase() {
    let chunks = merge3(base: [], left: ["x"], right: ["y"])
    #expect(chunks.map(\.kind) == [.conflict])
}
