import Foundation

public enum PatchError: Error, LocalizedError, Equatable {
    case malformed(String)
    case hunkFailed(Int)

    public var errorDescription: String? {
        switch self {
        case let .malformed(line): "Not a unified diff near: \(line)"
        case let .hunkFailed(n): "Hunk \(n) does not match the file."
        }
    }
}

/// Applies a single-file unified diff. Each hunk is placed at its stated line, or the nearest exact match of its context.
public func applyPatch(_ patch: String, to original: [String]) throws -> [String] {
    let lines = patch.components(separatedBy: "\n")
    var hunks: [(start: Int, count: Int, old: [String], new: [String])] = []
    var i = 0
    while i < lines.count {
        guard lines[i].hasPrefix("@@") else { i += 1; continue }
        let header = lines[i]
        guard let minus = header.split(separator: " ").first(where: { $0.hasPrefix("-") }) else { throw PatchError.malformed(header) }
        let parts = minus.dropFirst().split(separator: ",").map { Int($0) }
        guard let start = parts.first ?? nil else { throw PatchError.malformed(header) }
        let oldCount = parts.count > 1 ? (parts[1] ?? 1) : 1
        let plus = header.split(separator: " ").first { $0.hasPrefix("+") }
        let newParts = plus?.dropFirst().split(separator: ",").map { Int($0) } ?? []
        let newCount = newParts.count > 1 ? (newParts[1] ?? 1) : 1
        var old: [String] = [], new: [String] = []
        i += 1
        while i < lines.count, old.count < oldCount || new.count < newCount {
            let line = lines[i]
            if line.hasPrefix("\\") { i += 1; continue } // "\ No newline at end of file"
            let body = String(line.dropFirst())
            switch line.first {
            case " ": old.append(body); new.append(body)
            case "-": old.append(body)
            case "+": new.append(body)
            case nil: old.append(""); new.append("") // some tools trim the space of empty context lines
            default: throw PatchError.malformed(line)
            }
            i += 1
        }
        hunks.append((start, oldCount, old, new))
    }
    guard !hunks.isEmpty else { throw PatchError.malformed(lines.first ?? "") }

    var result = original, delta = 0, minStart = 0
    for (n, h) in hunks.enumerated() {
        let expected = (h.count == 0 ? h.start : h.start - 1) + delta
        guard let pos = locate(h.old, in: result, near: expected, from: minStart) else { throw PatchError.hunkFailed(n + 1) }
        result.replaceSubrange(pos..<(pos + h.old.count), with: h.new)
        delta += h.new.count - h.old.count
        minStart = pos + h.new.count
    }
    return result
}

private func locate(_ block: [String], in lines: [String], near expected: Int, from minStart: Int) -> Int? {
    let last = lines.count - block.count
    guard last >= minStart else { return nil }
    let anchor = min(max(expected, minStart), last)
    if block.isEmpty { return anchor }
    for d in 0...max(anchor - minStart, last - anchor) {
        for pos in [anchor + d, anchor - d] where pos >= minStart && pos <= last {
            if lines[pos..<(pos + block.count)].elementsEqual(block) { return pos }
        }
    }
    return nil
}
