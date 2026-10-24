import Foundation

public let hexBytesPerRow = 16

public func hexRowCount(_ a: Data, _ b: Data) -> Int {
    (max(a.count, b.count) + hexBytesPerRow - 1) / hexBytesPerRow
}

/// Rows whose 16 bytes differ at the same offsets (or exist on one side only).
/// shortcut: compares by offset, so one inserted byte marks every later row; upgrade to a byte-level diff if insert-heavy binaries matter.
public func differingHexRows(_ a: Data, _ b: Data) -> [Int] {
    let rows = hexRowCount(a, b)
    return a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in
            (0..<rows).filter { row in
                let start = row * hexBytesPerRow
                let la = max(0, min(hexBytesPerRow, a.count - start)), lb = max(0, min(hexBytesPerRow, b.count - start))
                if la != lb { return true }
                return memcmp(pa.baseAddress! + start, pb.baseAddress! + start, la) != 0
            }
        }
    }
}

/// Bytes of one row; shorter than 16 at the end of the data.
public func hexRow(_ data: Data, _ row: Int) -> [UInt8] {
    let start = row * hexBytesPerRow
    guard start < data.count else { return [] }
    return [UInt8](data[start..<min(start + hexBytesPerRow, data.count)])
}
