/// RFC 4180 style parsing: quoted fields may hold separators, doubled quotes and newlines.
public func parseDelimited(_ text: String, separator: Character) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = ""
    var inQuotes = false, fieldStarted = false
    var chars = text.makeIterator()
    var pending: Character? = nil
    while let c = pending ?? chars.next() {
        pending = nil
        if inQuotes {
            if c == "\"" {
                if let next = chars.next() {
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else { inQuotes = false }
            } else { field.append(c) }
        } else if c == "\"", !fieldStarted {
            inQuotes = true; fieldStarted = true
        } else if c == separator {
            row.append(field); field = ""; fieldStarted = false
        } else if c == "\n" || c == "\r\n" {
            row.append(field); rows.append(row); row = []; field = ""; fieldStarted = false
        } else {
            field.append(c); fieldStarted = true
        }
    }
    if fieldStarted || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

public struct TableRowDiff: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable { case same, changed, leftOnly, rightOnly }
    public var id: Int
    public var kind: Kind
    public var left: [String]?
    public var right: [String]?
    public var changedColumns: [Int]
}

/// Matches rows by key columns when given (duplicate keys pair up in order), otherwise by a line diff of whole rows.
public func diffTables(_ left: [[String]], _ right: [[String]], keyColumns: [Int] = []) -> [TableRowDiff] {
    var out: [TableRowDiff] = []
    func add(_ l: [String]?, _ r: [String]?) {
        let cols = max(l?.count ?? 0, r?.count ?? 0)
        let changed = (l != nil && r != nil) ? (0..<cols).filter { cell(l!, $0) != cell(r!, $0) } : []
        let kind: TableRowDiff.Kind = l == nil ? .rightOnly : r == nil ? .leftOnly : changed.isEmpty ? .same : .changed
        out.append(TableRowDiff(id: out.count, kind: kind, left: l, right: r, changedColumns: changed))
    }

    if keyColumns.isEmpty {
        let sep = "\u{1F}"
        for h in diffLines(left.map { $0.joined(separator: sep) }, right.map { $0.joined(separator: sep) }) {
            if h.kind == .equal {
                for (i, j) in zip(h.left, h.right) { add(left[i], right[j]) }
            } else {
                let paired = min(h.left.count, h.right.count)
                for k in 0..<paired { add(left[h.left.lowerBound + k], right[h.right.lowerBound + k]) }
                for i in h.left.dropFirst(paired) { add(left[i], nil) }
                for j in h.right.dropFirst(paired) { add(nil, right[j]) }
            }
        }
        return out
    }

    func keys(_ rows: [[String]]) -> [String] {
        var seen: [String: Int] = [:]
        return rows.map { row in
            let k = keyColumns.map { cell(row, $0) }.joined(separator: "\u{1F}")
            seen[k, default: 0] += 1
            return k + "#\(seen[k]!)"
        }
    }
    let lk = keys(left), rk = keys(right)
    var rightIndex: [String: Int] = [:]
    for (j, k) in rk.enumerated() { rightIndex[k] = j }
    var used = Set<Int>()
    for (i, k) in lk.enumerated() {
        if let j = rightIndex[k] { used.insert(j); add(left[i], right[j]) } else { add(left[i], nil) }
    }
    for j in right.indices where !used.contains(j) { add(nil, right[j]) }
    return out
}

func cell(_ row: [String], _ column: Int) -> String { column < row.count ? row[column] : "" }
