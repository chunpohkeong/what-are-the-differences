import Foundation

public struct FileInfo: Sendable, Hashable {
    public var url: URL
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool
    /// Came from a saved snapshot: no file exists to read or copy.
    public var isSnapshot = false
}

/// Where one side of a folder compare gets its listing.
public enum FolderSource: Sendable {
    case directory(URL)
    case snapshot(FolderSnapshot)
}

public enum EntryStatus: String, Sendable, Hashable {
    case same, leftNewer, rightNewer, differs, leftOnly, rightOnly
}

/// One name present on either side. Directories present on both sides carry `children`; everything else has `nil`.
public struct FolderEntry: Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public var name: String
    public var relativePath: String
    public var left: FileInfo?
    public var right: FileInfo?
    public var status: EntryStatus
    public var children: [FolderEntry]?

    public var isDirectory: Bool { (left ?? right)?.isDirectory ?? false }
}

public struct FolderCompareOptions: Sendable, Hashable {
    /// Byte-compare files whose size matches but whose timestamps differ (or always, to catch same-mtime edits).
    public var compareContents: Bool
    /// Glob masks a file name must match (directories are always walked).
    public var includeMasks: [String]
    /// Glob masks that hide files and directories.
    public var excludeMasks: [String]
    /// Treat files that differ only in modification time as the same ("minor" differences).
    public var ignoreTimestamps: Bool

    public init(compareContents: Bool = false, includeMasks: [String] = ["*"], excludeMasks: [String] = [".DS_Store"], ignoreTimestamps: Bool = false) {
        self.compareContents = compareContents
        self.includeMasks = includeMasks
        self.excludeMasks = excludeMasks
        self.ignoreTimestamps = ignoreTimestamps
    }
}

public func compareFolders(left: URL, right: URL, options: FolderCompareOptions = .init()) throws -> [FolderEntry] {
    try compareFolders(left: .directory(left), right: .directory(right), options: options)
}

public func compareFolders(left: FolderSource, right: FolderSource, options: FolderCompareOptions = .init()) throws -> [FolderEntry] {
    try compareLevel(lister(left, options), lister(right, options), relative: "", options: options)
}

/// Lists one folder level (by relative path) as name → info.
private typealias Lister = (String) throws -> [String: FileInfo]

private func lister(_ source: FolderSource, _ options: FolderCompareOptions) -> Lister {
    switch source {
    case let .directory(root):
        return { rel in try listDirectory(rel.isEmpty ? root : root.appending(path: rel), options: options) }
    case let .snapshot(snapshot):
        let root = URL(fileURLWithPath: snapshot.root)
        var byParent: [String: [String: FileInfo]] = [:]
        for item in snapshot.items {
            let name = (item.path as NSString).lastPathComponent
            if matches(name, options.excludeMasks) { continue }
            if !item.isDirectory, !matches(name, options.includeMasks) { continue }
            byParent[(item.path as NSString).deletingLastPathComponent, default: [:]][name] =
                FileInfo(url: root.appending(path: item.path), size: item.size, modified: item.modified, isDirectory: item.isDirectory, isSnapshot: true)
        }
        return { byParent[$0] ?? [:] }
    }
}

private func compareLevel(_ left: Lister, _ right: Lister, relative: String, options: FolderCompareOptions) throws -> [FolderEntry] {
    try Task.checkCancellation() // lets a Stop button end a long compare between folders
    let l = try left(relative), r = try right(relative)
    return try Set(l.keys).union(r.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
        let path = relative.isEmpty ? name : relative + "/" + name
        let a = l[name], b = r[name]
        var entry = FolderEntry(name: name, relativePath: path, left: a, right: b, status: .same, children: nil)
        switch (a, b) {
        case (_?, nil): entry.status = .leftOnly
        case (nil, _?): entry.status = .rightOnly
        case let (a?, b?) where a.isDirectory && b.isDirectory:
            let kids = try compareLevel(left, right, relative: path, options: options)
            entry.children = kids
            entry.status = kids.allSatisfy { $0.status == .same } ? .same : .differs
        case let (a?, b?) where a.isDirectory != b.isDirectory:
            entry.status = .differs
        case let (a?, b?):
            entry.status = try fileStatus(a, b, compareContents: options.compareContents && !a.isSnapshot && !b.isSnapshot,
                                          ignoreTimestamps: options.ignoreTimestamps)
        default:
            break
        }
        return entry
    }
}

private func fileStatus(_ a: FileInfo, _ b: FileInfo, compareContents: Bool, ignoreTimestamps: Bool) throws -> EntryStatus {
    if ignoreTimestamps {
        guard a.size == b.size else { return .differs }
        return compareContents ? (try sameContents(a.url, b.url) ? .same : .differs) : .same
    }
    let timeDelta = a.modified.timeIntervalSince(b.modified)
    let sameTime = abs(timeDelta) < 2 // FAT and some network volumes store 2-second timestamps
    if a.size == b.size, sameTime, !compareContents { return .same }
    if a.size == b.size, compareContents, try sameContents(a.url, b.url) { return .same }
    if sameTime { return .differs }
    return timeDelta > 0 ? .leftNewer : .rightNewer
}

private func listDirectory(_ dir: URL, options: FolderCompareOptions) throws -> [String: FileInfo] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    var result: [String: FileInfo] = [:]
    for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) {
        let name = url.lastPathComponent
        let values = try url.resourceValues(forKeys: Set(keys))
        // Symlinks are compared as files and never followed, so link loops cannot recurse forever.
        let isDir = (values.isDirectory ?? false) && !(values.isSymbolicLink ?? false)
        if matches(name, options.excludeMasks) { continue }
        if !isDir, !matches(name, options.includeMasks) { continue }
        result[name] = FileInfo(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast, isDirectory: isDir)
    }
    return result
}

private func matches(_ name: String, _ masks: [String]) -> Bool {
    masks.contains { fnmatch($0, name, 0) == 0 }
}

/// Streams both files in 64 KB chunks; stops at the first differing chunk.
public func sameContents(_ a: URL, _ b: URL) throws -> Bool {
    let ha = try FileHandle(forReadingFrom: a), hb = try FileHandle(forReadingFrom: b)
    defer { try? ha.close(); try? hb.close() }
    while true {
        let da = try ha.read(upToCount: 65_536) ?? Data(), db = try hb.read(upToCount: 65_536) ?? Data()
        if da != db { return false }
        if da.isEmpty { return true }
    }
}

/// Flattened lookup by relative path, including nested entries.
public func indexEntries(_ entries: [FolderEntry]) -> [String: FolderEntry] {
    var index: [String: FolderEntry] = [:]
    func walk(_ list: [FolderEntry]) { for e in list { index[e.relativePath] = e; walk(e.children ?? []) } }
    walk(entries)
    return index
}
