/// One region of a three-way merge, with its line ranges in each input.
public struct MergeChunk: Sendable, Hashable {
    public enum Kind: Sendable {
        /// Unchanged on both sides.
        case stable
        /// Changed on the left only; take left.
        case left
        /// Changed on the right only; take right.
        case right
        /// Both sides made the identical change.
        case both
        /// Both sides changed the same region differently.
        case conflict
    }
    public var kind: Kind
    public var base: Range<Int>
    public var left: Range<Int>
    public var right: Range<Int>
}

/// diff3: diff base against each side, group overlapping or touching changes, classify each group.
public func merge3(base: [String], left: [String], right: [String]) -> [MergeChunk] {
    let changes = (diffLines(base, left).filter { $0.kind == .change }.map { (isLeft: true, hunk: $0) }
        + diffLines(base, right).filter { $0.kind == .change }.map { (isLeft: false, hunk: $0) })
        .sorted { $0.hunk.left.lowerBound < $1.hunk.left.lowerBound } // `left` of a base-vs-side hunk is the base range

    var chunks: [MergeChunk] = []
    var dL = 0, dR = 0, pos = 0, i = 0
    while i < changes.count {
        let lo = changes[i].hunk.left.lowerBound
        var hi = changes[i].hunk.left.upperBound
        var j = i + 1
        while j < changes.count, changes[j].hunk.left.lowerBound <= hi {
            hi = max(hi, changes[j].hunk.left.upperBound); j += 1
        }
        let group = changes[i..<j]
        if pos < lo { chunks.append(MergeChunk(kind: .stable, base: pos..<lo, left: (pos + dL)..<(lo + dL), right: (pos + dR)..<(lo + dR))) }

        let growL = group.filter(\.isLeft).reduce(0) { $0 + $1.hunk.right.count - $1.hunk.left.count }
        let growR = group.filter { !$0.isLeft }.reduce(0) { $0 + $1.hunk.right.count - $1.hunk.left.count }
        let lr = (lo + dL)..<(hi + dL + growL), rr = (lo + dR)..<(hi + dR + growR)
        let hasL = group.contains(where: \.isLeft), hasR = group.contains { !$0.isLeft }
        let kind: MergeChunk.Kind = hasL && hasR ? (left[lr] == right[rr] ? .both : .conflict) : hasL ? .left : .right
        chunks.append(MergeChunk(kind: kind, base: lo..<hi, left: lr, right: rr))

        dL += growL; dR += growR; pos = hi; i = j
    }
    if pos < base.count {
        chunks.append(MergeChunk(kind: .stable, base: pos..<base.count, left: (pos + dL)..<(base.count + dL), right: (pos + dR)..<(base.count + dR)))
    }
    return chunks
}

/// Merged lines. Conflicts become marker blocks tagged with the chunk index so the UI can find them again.
public func renderMerge(_ chunks: [MergeChunk], base: [String], left: [String], right: [String]) -> [String] {
    chunks.enumerated().flatMap { index, c -> [String] in
        switch c.kind {
        case .stable: Array(base[c.base])
        case .left, .both: Array(left[c.left])
        case .right: Array(right[c.right])
        case .conflict:
            ["<<<<<<< LEFT #\(index)"] + left[c.left] + ["||||||| BASE"] + base[c.base] + ["======="] + right[c.right] + [">>>>>>> RIGHT"]
        }
    }
}

/// A conflict marker block found in (possibly hand-edited) merge output.
public struct ConflictBlock: Sendable, Hashable {
    /// Chunk index from the `#n` tag, if present.
    public var id: Int?
    public var lines: Range<Int>
    public var left: [String]
    public var base: [String]
    public var right: [String]
}

public func findConflicts(in lines: [String]) -> [ConflictBlock] {
    var blocks: [ConflictBlock] = []
    var i = 0
    while i < lines.count {
        guard lines[i].hasPrefix("<<<<<<<") else { i += 1; continue }
        let start = i
        let id = lines[i].split(separator: "#").last.flatMap { Int($0) }
        var section = 0, l: [String] = [], b: [String] = [], r: [String] = []
        i += 1
        while i < lines.count, !lines[i].hasPrefix(">>>>>>>") {
            if lines[i].hasPrefix("|||||||") { section = 1 }
            else if lines[i].hasPrefix("=======") { section = 2 }
            else if section == 0 { l.append(lines[i]) }
            else if section == 1 { b.append(lines[i]) }
            else { r.append(lines[i]) }
            i += 1
        }
        guard i < lines.count else { break } // unterminated block: leave it alone
        blocks.append(ConflictBlock(id: id, lines: start..<(i + 1), left: l, base: b, right: r))
        i += 1
    }
    return blocks
}
