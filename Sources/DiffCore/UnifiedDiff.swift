/// Standard unified diff text (`diff -u` style) for the given hunks.
public func unifiedDiff(left: [String], right: [String], hunks: [DiffHunk], leftName: String, rightName: String, context: Int = 3) -> String {
    let changes = hunks.indices.filter { hunks[$0].kind == .change }
    guard !changes.isEmpty else { return "" }
    var out = "--- \(leftName)\n+++ \(rightName)\n"
    var g = 0
    while g < changes.count {
        var end = g
        while end + 1 < changes.count,
              hunks[changes[end + 1]].left.lowerBound - hunks[changes[end]].left.upperBound <= 2 * context { end += 1 }
        let first = hunks[changes[g]], last = hunks[changes[end]]
        let before = min(context, first.left.lowerBound, first.right.lowerBound)
        let after = min(context, left.count - last.left.upperBound, right.count - last.right.upperBound)
        let ls = first.left.lowerBound - before, le = last.left.upperBound + after
        let rs = first.right.lowerBound - before, re = last.right.upperBound + after
        func header(_ start: Int, _ count: Int) -> String { count == 0 ? "\(start),0" : "\(start + 1),\(count)" }
        out += "@@ -\(header(ls, le - ls)) +\(header(rs, re - rs)) @@\n"
        for idx in max(0, changes[g] - 1)...min(hunks.count - 1, changes[end] + 1) {
            let h = hunks[idx]
            if h.kind == .equal {
                for i in max(h.left.lowerBound, ls)..<max(min(h.left.upperBound, le), max(h.left.lowerBound, ls)) { out += " \(left[i])\n" }
            } else {
                for i in h.left { out += "-\(left[i])\n" }
                for j in h.right { out += "+\(right[j])\n" }
            }
        }
        g = end + 1
    }
    return out
}
