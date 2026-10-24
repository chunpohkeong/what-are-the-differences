import Foundation

/// Character-level changes inside one changed line pair, as UTF-16 ranges ready for NSTextView.
public func inlineDiff(_ left: String, _ right: String) -> (left: [NSRange], right: [NSRange]) {
    let a = Array(left), b = Array(right)
    let ua = utf16Offsets(a), ub = utf16Offsets(b)
    var l: [NSRange] = [], r: [NSRange] = []
    for h in diffSequences(a, b) where h.kind == .change {
        if !h.left.isEmpty { l.append(NSRange(location: ua[h.left.lowerBound], length: ua[h.left.upperBound] - ua[h.left.lowerBound])) }
        if !h.right.isEmpty { r.append(NSRange(location: ub[h.right.lowerBound], length: ub[h.right.upperBound] - ub[h.right.lowerBound])) }
    }
    return (l, r)
}

private func utf16Offsets(_ chars: [Character]) -> [Int] {
    var offsets = [0]
    offsets.reserveCapacity(chars.count + 1)
    for c in chars { offsets.append(offsets.last! + c.utf16.count) }
    return offsets
}
