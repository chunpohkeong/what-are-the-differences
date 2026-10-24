import Foundation
import Testing
@testable import DiffCore

/// Rebuilds the right side from the left using the hunks; proves hunks are complete and correct.
private func apply(_ hunks: [DiffHunk], _ left: [String], _ right: [String]) -> [String] {
    hunks.flatMap { $0.kind == .equal ? Array(left[$0.left]) : Array(right[$0.right]) }
}

@Test func emptyInputs() {
    #expect(diffLines([], []).isEmpty)
}

@Test func identical() {
    let a = ["a", "b", "c"]
    #expect(diffLines(a, a) == [DiffHunk(kind: .equal, left: 0..<3, right: 0..<3)])
}

@Test func allInsertAndAllDelete() {
    #expect(diffLines([], ["x", "y"]) == [DiffHunk(kind: .change, left: 0..<0, right: 0..<2)])
    #expect(diffLines(["x", "y"], []) == [DiffHunk(kind: .change, left: 0..<2, right: 0..<0)])
}

@Test func midFileChange() {
    let a = ["1", "2", "3", "4", "5"], b = ["1", "2", "X", "4", "5", "6"]
    let h = diffLines(a, b)
    #expect(h == [
        DiffHunk(kind: .equal, left: 0..<2, right: 0..<2),
        DiffHunk(kind: .change, left: 2..<3, right: 2..<3),
        DiffHunk(kind: .equal, left: 3..<5, right: 3..<5),
        DiffHunk(kind: .change, left: 5..<5, right: 5..<6),
    ])
    #expect(apply(h, a, b) == b)
}

@Test func interleavedEditsReconstruct() {
    let a = ["a", "b", "c", "d", "e", "f", "g"], b = ["b", "c", "x", "e", "y", "g", "h"]
    #expect(apply(diffLines(a, b), a, b) == b)
}

@Test func whitespaceAndCaseOptions() {
    let a = ["let  x = 1", "Foo"], b = ["let x = 1  ", "foo"]
    #expect(diffLines(a, b).contains { $0.kind == .change })
    #expect(diffLines(a, b, options: .init(ignoreWhitespace: true, ignoreCase: true)).allSatisfy { $0.kind == .equal })
}

@Test func mapLineFollowsHunks() {
    let h = diffLines(["1", "2", "3", "4"], ["1", "new", "new", "2", "3", "4"])
    #expect(mapLine(0, hunks: h, fromLeft: true) == 0)
    #expect(mapLine(1, hunks: h, fromLeft: true) == 3)
    #expect(mapLine(2, hunks: h, fromLeft: false) == 1)
    #expect(mapLine(4, hunks: h, fromLeft: true) == 6)
}

@Test func splitLinesHandlesTrailingNewline() {
    #expect(splitLines("") == [])
    #expect(splitLines("a\nb\n") == ["a", "b"])
    #expect(splitLines("a\n\nb") == ["a", "", "b"])
}

@Test func inlineDiffUsesUTF16Ranges() {
    let (l, r) = inlineDiff("let 😀 = 1", "let 😀 = 22")
    #expect(l == [NSRange(location: 9, length: 1)])
    #expect(r == [NSRange(location: 9, length: 2)])
}

@Test func largeFilePerformance() {
    let a = (0..<100_000).map { "line \($0)" }
    var b = a
    for i in stride(from: 500, to: 100_000, by: 1000) { b[i] = "changed \(i)" }
    let start = Date()
    let h = diffLines(a, b)
    #expect(Date().timeIntervalSince(start) < 1.0)
    #expect(h.filter { $0.kind == .change }.count == 100)
}

@Test func unifiedDiffFormat() {
    let a = ["a", "b", "c"], b = ["a", "B", "c"]
    let text = unifiedDiff(left: a, right: b, hunks: diffLines(a, b), leftName: "l", rightName: "r")
    #expect(text == "--- l\n+++ r\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
    #expect(unifiedDiff(left: a, right: a, hunks: diffLines(a, a), leftName: "l", rightName: "r").isEmpty)
}

@Test func textDocumentRoundTripsLineEndingsAndBOM() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "delta-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data([0xEF, 0xBB, 0xBF]) + "a\r\nb\r\n".data(using: .utf8)!
    try original.write(to: url)
    let doc = try TextDocument.load(url)
    #expect(doc.text == "a\nb\n")
    #expect(doc.lineEnding == "\r\n" && doc.hasBOM)
    #expect(try doc.data(for: doc.text) == original)
}

@Test func binaryFilesAreRejected() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "delta-\(UUID()).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0x00, 0x01, 0x02]).write(to: url)
    #expect(throws: TextLoadError.self) { try TextDocument.load(url) }
}

@Test func openRequestRoundTrip() {
    let r = OpenRequest(kind: .merge, paths: ["/a b/l.txt", "/r&x.txt", "/base?.txt"], output: "/o.txt", waitMarker: "/tmp/m")
    #expect(OpenRequest(url: r.url) == r)
}
