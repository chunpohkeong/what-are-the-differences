import Foundation

/// Runs file operations one at a time. Nothing is hard-deleted: replaced and removed items go to the Trash,
/// which is also the undo path.
public actor FileOperations {
    public struct Failure: Sendable, Hashable {
        public var op: SyncOp
        public var message: String
    }

    public init() {}

    @discardableResult
    public func run(_ ops: [SyncOp], dryRun: Bool = false, progress: (@Sendable (Int, Int) -> Void)? = nil) -> [Failure] {
        var failures: [Failure] = []
        let fm = FileManager.default
        for (i, op) in ops.enumerated() {
            if !dryRun {
                do {
                    switch op {
                    case let .copy(from, to):
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if fm.fileExists(atPath: to.path) { try fm.trashItem(at: to, resultingItemURL: nil) }
                        try fm.copyItem(at: from, to: to)
                    case let .trash(url):
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    }
                } catch {
                    failures.append(Failure(op: op, message: error.localizedDescription))
                }
            }
            progress?(i + 1, ops.count)
        }
        return failures
    }
}
