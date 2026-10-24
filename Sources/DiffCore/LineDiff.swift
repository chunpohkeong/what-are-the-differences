import Foundation

/// How lines are compared. Line endings never matter: text is normalized to "\n" on load.
public struct DiffOptions: Sendable, Hashable {
    public var ignoreWhitespace: Bool
    public var ignoreCase: Bool

    public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreCase = ignoreCase
    }

    func key(_ line: String) -> String {
        var s = line
        if ignoreWhitespace { s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if ignoreCase { s = s.lowercased() }
        return s
    }
}

/// A run of lines that is either identical on both sides or changed.
/// A change with an empty `left` is a pure insertion; with an empty `right`, a pure deletion.
public struct DiffHunk: Sendable, Hashable {
    public enum Kind: Sendable { case equal, change }
    public var kind: Kind
    public var left: Range<Int>
    public var right: Range<Int>

    public init(kind: Kind, left: Range<Int>, right: Range<Int>) {
        self.kind = kind
        self.left = left
        self.right = right
    }
}

/// Line diff. Hunks are contiguous and cover both inputs completely.
public func diffLines(_ left: [String], _ right: [String], options: DiffOptions = .init()) -> [DiffHunk] {
    var ids: [String: Int] = [:]
    func intern(_ line: String) -> Int {
        let key = options.key(line)
        if let id = ids[key] { return id }
        ids[key] = ids.count
        return ids.count - 1
    }
    return diffSequences(left.map(intern), right.map(intern))
}

func diffSequences<T: Hashable>(_ a: [T], _ b: [T]) -> [DiffHunk] {
    let n = a.count, m = b.count
    var prefix = 0
    while prefix < n, prefix < m, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < n - prefix, suffix < m - prefix, a[n - 1 - suffix] == b[m - 1 - suffix] { suffix += 1 }

    let midA = Array(a[prefix..<(n - suffix)]), midB = Array(b[prefix..<(m - suffix)])
    var removed = [Bool](repeating: false, count: midA.count)
    var inserted = [Bool](repeating: false, count: midB.count)
    // shortcut: stdlib Myers keeps O(D²) trace memory; two huge, almost totally different files get slow. Upgrade to linear-space Myers if that shows up.
    for change in midB.difference(from: midA) {
        switch change {
        case let .remove(offset, _, _): removed[offset] = true
        case let .insert(offset, _, _): inserted[offset] = true
        }
    }

    var hunks: [DiffHunk] = []
    func add(_ kind: DiffHunk.Kind, _ l: Range<Int>, _ r: Range<Int>) {
        guard !(l.isEmpty && r.isEmpty) else { return }
        if let last = hunks.last, last.kind == kind {
            hunks[hunks.count - 1] = DiffHunk(kind: kind, left: last.left.lowerBound..<l.upperBound, right: last.right.lowerBound..<r.upperBound)
        } else {
            hunks.append(DiffHunk(kind: kind, left: l, right: r))
        }
    }

    add(.equal, 0..<prefix, 0..<prefix)
    var i = 0, j = 0
    while i < midA.count || j < midB.count {
        let i0 = i, j0 = j
        if (i < midA.count && removed[i]) || (j < midB.count && inserted[j]) {
            while i < midA.count, removed[i] { i += 1 }
            while j < midB.count, inserted[j] { j += 1 }
            add(.change, (prefix + i0)..<(prefix + i), (prefix + j0)..<(prefix + j))
        } else {
            while i < midA.count, j < midB.count, !removed[i], !inserted[j] { i += 1; j += 1 }
            if i == i0 { // cannot happen with a correct difference; never loop forever
                add(.change, (prefix + i)..<(prefix + midA.count), (prefix + j)..<(prefix + midB.count))
                break
            }
            add(.equal, (prefix + i0)..<(prefix + i), (prefix + j0)..<(prefix + j))
        }
    }
    add(.equal, (n - suffix)..<n, (m - suffix)..<m)
    return hunks
}

/// Maps a line on one side to the matching line on the other side, for synced scrolling.
public func mapLine(_ line: Int, hunks: [DiffHunk], fromLeft: Bool) -> Int {
    for h in hunks {
        let src = fromLeft ? h.left : h.right, dst = fromLeft ? h.right : h.left
        if line < src.upperBound {
            let offset = line - src.lowerBound
            return h.kind == .equal ? dst.lowerBound + offset : dst.lowerBound + min(offset, max(dst.count - 1, 0))
        }
    }
    return hunks.last.map { fromLeft ? $0.right.upperBound : $0.left.upperBound } ?? 0
}

/// Splits normalized text into lines; a trailing "\n" does not create an extra empty line.
public func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}
