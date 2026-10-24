import Foundation

public enum TextLoadError: Error, LocalizedError {
    case binary(URL)
    case undecodable(URL)

    public var errorDescription: String? {
        switch self {
        case let .binary(url): "\(url.lastPathComponent) looks like a binary file."
        case let .undecodable(url): "\(url.lastPathComponent) could not be decoded as text."
        }
    }
}

/// A text file with "\n"-normalized content plus what is needed to write it back unchanged.
public struct TextDocument: Sendable {
    public var text: String
    public var encoding: String.Encoding
    public var lineEnding: String
    public var hasBOM: Bool

    public init(text: String = "", encoding: String.Encoding = .utf8, lineEnding: String = "\n", hasBOM: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    public static func load(_ url: URL) throws -> TextDocument {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data.prefix(3))
        var encoding = String.Encoding.utf8, bom = false, body = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true; body = data.dropFirst(3)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; bom = true; body = data.dropFirst(2)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; bom = true; body = data.dropFirst(2)
        } else if data.prefix(8000).contains(0) {
            throw TextLoadError.binary(url)
        }

        var raw = String(data: body, encoding: encoding)
        if raw == nil, encoding == .utf8 {
            encoding = .isoLatin1
            raw = String(data: body, encoding: .isoLatin1)
        }
        guard let raw else { throw TextLoadError.undecodable(url) }

        let ending = raw.contains("\r\n") ? "\r\n" : raw.contains("\r") ? "\r" : "\n"
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return TextDocument(text: text, encoding: encoding, lineEnding: ending, hasBOM: bom)
    }

    /// Bytes for `text` using this document's encoding, line ending and BOM.
    public func data(for text: String) throws -> Data {
        let out = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        guard var data = out.data(using: encoding) else { throw TextLoadError.undecodable(URL(fileURLWithPath: "/")) }
        if hasBOM {
            switch encoding {
            case .utf16LittleEndian: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            default: data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            }
        }
        return data
    }
}
