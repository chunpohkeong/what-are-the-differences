import Foundation

/// One file in a three-way folder merge.
public struct FolderMergeItem: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable { case unchanged, modified, added, deleted, absent }
    public enum Action: String, Sendable { case takeLeft, takeRight, delete, conflict }

    public var id: String { relativePath }
    public var relativePath: String
    public var left: Change
    public var right: Change
    public var action: Action
}

/// Decides each file by comparing both sides with base (contents, not dates). Empty folders are ignored.
public func planFolderMerge(base: URL, left: URL, right: URL, options: FolderCompareOptions = .init()) throws -> [FolderMergeItem] {
    let b = try listFiles(base, options), l = try listFiles(left, options), r = try listFiles(right, options)
    return try Set(b.keys).union(l.keys).union(r.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
        func change(_ side: URL?) throws -> FolderMergeItem.Change {
            switch (b[path], side) {
            case (nil, nil): .absent
            case (nil, _?): .added
            case (_?, nil): .deleted
            case let (base?, side?): try same(base, side) ? .unchanged : .modified
            }
        }
        let lc = try change(l[path]), rc = try change(r[path])
        let sidesEqual: Bool = switch (l[path], r[path]) {
        case (nil, nil): true
        case let (a?, c?): try same(a, c)
        default: false
        }
        let action: FolderMergeItem.Action
        if sidesEqual { action = l[path] == nil ? .delete : .takeLeft }
        else if lc == .unchanged || lc == .absent { action = rc == .deleted ? .delete : .takeRight }
        else if rc == .unchanged || rc == .absent { action = lc == .deleted ? .delete : .takeLeft }
        else { action = .conflict }
        return FolderMergeItem(relativePath: path, left: lc, right: rc, action: action)
    }
}

/// Copies for every resolved item into `output`; conflicts and deletions write nothing.
public func folderMergeOps(_ items: [FolderMergeItem], left: URL, right: URL, output: URL) -> [SyncOp] {
    items.compactMap { item in
        switch item.action {
        case .takeLeft: .copy(from: left.appending(path: item.relativePath), to: output.appending(path: item.relativePath))
        case .takeRight: .copy(from: right.appending(path: item.relativePath), to: output.appending(path: item.relativePath))
        case .delete, .conflict: nil
        }
    }
}

private func same(_ a: URL, _ b: URL) throws -> Bool {
    let sa = try a.resourceValues(forKeys: [.fileSizeKey]).fileSize, sb = try b.resourceValues(forKeys: [.fileSizeKey]).fileSize
    return sa == sb ? try sameContents(a, b) : false
}

private func listFiles(_ root: URL, _ options: FolderCompareOptions) throws -> [String: URL] {
    var files: [String: URL] = [:]
    func walk(_ dir: URL, _ prefix: String) throws {
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = url.lastPathComponent
            if options.excludeMasks.contains(where: { fnmatch($0, name, 0) == 0 }) { continue }
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if (v.isDirectory ?? false) && !(v.isSymbolicLink ?? false) {
                try walk(url, path)
            } else if options.includeMasks.contains(where: { fnmatch($0, name, 0) == 0 }) {
                files[path] = url
            }
        }
    }
    try walk(root, "")
    return files
}
