import Foundation

public enum SyncMode: String, CaseIterable, Sendable, Identifiable {
    /// Copy new and newer files from left to right. Never deletes.
    case updateRight
    /// Copy new and newer files in both directions. Never deletes.
    case updateBoth
    /// Make right identical to left, including moving right-only items to the Trash.
    case mirror

    public var id: String { rawValue }
}

public enum SyncOp: Sendable, Hashable {
    /// Copy file or folder; an existing destination goes to the Trash first.
    case copy(from: URL, to: URL)
    case trash(URL)
}

public func planSync(_ entries: [FolderEntry], left: URL, right: URL, mode: SyncMode) -> [SyncOp] {
    var ops: [SyncOp] = []
    func walk(_ list: [FolderEntry]) {
        for e in list {
            if let kids = e.children { walk(kids); continue }
            let l = left.appending(path: e.relativePath), r = right.appending(path: e.relativePath)
            switch (e.status, mode) {
            case (.same, _): break
            case (.leftOnly, _), (.leftNewer, _): ops.append(.copy(from: l, to: r))
            case (.rightOnly, .updateBoth), (.rightNewer, .updateBoth): ops.append(.copy(from: r, to: l))
            case (.rightOnly, .mirror): ops.append(.trash(r))
            case (.rightNewer, .mirror), (.differs, .mirror): ops.append(.copy(from: l, to: r))
            case (.rightOnly, .updateRight), (.rightNewer, .updateRight), (.differs, _): break
            }
        }
    }
    walk(entries)
    return ops
}
