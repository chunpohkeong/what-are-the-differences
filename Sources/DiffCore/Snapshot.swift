import Foundation

/// A saved listing of a folder (paths, sizes, dates) that can stand in for one side of a folder compare.
public struct FolderSnapshot: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var modified: Date
        public var isDirectory: Bool
    }

    public var root: String
    public var created: Date
    public var items: [Item]

    public static let fileExtension = "deltasnap"

    public static func capture(_ folder: URL) throws -> FolderSnapshot {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        let root = folder.standardizedFileURL.path
        var items: [Item] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root])
        }
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            items.append(Item(path: path, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast,
                              isDirectory: (v.isDirectory ?? false) && !(v.isSymbolicLink ?? false)))
        }
        return FolderSnapshot(root: root, created: Date(), items: items)
    }

    public static func read(_ url: URL) throws -> FolderSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FolderSnapshot.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum ArchiveError: Error, LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case let .failed(message): "Could not open archive: \(message)" }
    }
}

public func isArchive(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return [".zip", ".jar", ".tar", ".tgz", ".tar.gz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz", ".7z"].contains { name.hasSuffix($0) }
}

/// Extracts into a new temporary folder with the system bsdtar, which refuses absolute and `..` paths by default.
public func extractArchive(_ url: URL) throws -> URL {
    let dest = FileManager.default.temporaryDirectory.appending(path: "delta-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
    tar.arguments = ["-xf", url.path, "-C", dest.path]
    let err = Pipe()
    tar.standardError = err
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
        throw ArchiveError.failed(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "bsdtar failed")
    }
    return dest
}
