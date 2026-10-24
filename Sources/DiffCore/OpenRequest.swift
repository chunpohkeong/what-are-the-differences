import Foundation

/// What the CLI asks the app to open, carried as a `delta://open?...` URL.
public struct OpenRequest: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, folder, merge, hex, table, picture, folderMerge }

    public var kind: Kind
    /// Two-way kinds: [left, right]; merge and folderMerge: [left, right, base].
    public var paths: [String]
    public var output: String?
    /// File the app creates when the window closes, so `delta --wait` can return.
    public var waitMarker: String?

    public init(kind: Kind, paths: [String] = [], output: String? = nil, waitMarker: String? = nil) {
        self.kind = kind
        self.paths = paths
        self.output = output
        self.waitMarker = waitMarker
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "delta"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue)]
            + paths.map { URLQueryItem(name: "path", value: $0) }
            + [output.map { URLQueryItem(name: "output", value: $0) }, waitMarker.map { URLQueryItem(name: "wait", value: $0) }].compactMap { $0 }
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "delta", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let kind = items.first(where: { $0.name == "kind" })?.value.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(kind: kind,
                  paths: items.filter { $0.name == "path" }.compactMap(\.value),
                  output: items.first { $0.name == "output" }?.value,
                  waitMarker: items.first { $0.name == "wait" }?.value)
    }
}

extension OpenRequest.Kind {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp"]

    /// The session that fits these paths, or nil when they cannot be compared together.
    public static func detect(_ paths: [String]) -> OpenRequest.Kind? {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let folders = urls.map { url -> Bool in
            var dir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &dir)
            return dir.boolValue || isArchive(url) || url.pathExtension == FolderSnapshot.fileExtension
        }
        if urls.count == 3 { return folders.allSatisfy { $0 } ? .folderMerge : folders.contains(true) ? nil : .merge }
        guard urls.count == 2, folders[0] == folders[1] else { return nil }
        if folders[0] { return .folder }
        let exts = urls.map { $0.pathExtension.lowercased() }
        if exts.allSatisfy(imageExtensions.contains) { return .picture }
        if exts.allSatisfy({ $0 == "csv" || $0 == "tsv" }) { return .table }
        if exts.contains("pdf") { return .text }
        return urls.contains(where: looksBinary) ? .hex : .text
    }
}

/// NUL bytes in the first 8 KB (UTF-16 with a BOM is text).
public func looksBinary(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 8000) else { return false }
    if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
    return head.contains(0)
}
