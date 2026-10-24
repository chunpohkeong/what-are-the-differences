import AppKit
import DiffCore

@MainActor final class FolderCompareModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", differences = "Differences", same = "Same", orphans = "Orphans"
        var id: String { rawValue }
    }

    /// File changes waiting for the user to confirm.
    struct PendingOps: Identifiable {
        let id = UUID()
        let title: String
        let ops: [SyncOp]
        let destructive: Bool
    }

    /// What a chosen path turned out to be: a folder, an extracted archive, or a saved snapshot.
    struct Side {
        var source: FolderSource
        /// Real folder holding the files; nil for snapshots.
        var root: URL?
        /// Only plain folders accept copies, deletes and sync.
        var writable: Bool
    }

    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var left: Side?
    @Published private(set) var right: Side?
    @Published private(set) var entries: [FolderEntry] = []
    @Published private(set) var index: [String: FolderEntry] = [:]
    @Published var filter: Filter = .all
    @Published var compareContents = false
    /// Show files that differ only in timestamp as different; off treats them as the same.
    @Published var showMinor = true
    /// File masks separated by ';'. A leading '-' excludes, e.g. "*.swift;-build;-.DS_Store".
    @Published var masksText = "*;-.DS_Store"
    /// Flat list of files instead of the folder tree.
    @Published var flatten = false
    @Published var expanded = Set<String>()
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var selection = Set<String>()
    @Published var pending: PendingOps?
    @Published var showSync = false
    @Published var syncMode: SyncMode = .updateRight
    @Published var syncProgress: Double?
    @Published var syncFailures: [FileOperations.Failure] = []
    /// Timestamped activity shown in the log pane: compares, file operations, saves, errors.
    @Published private(set) var log: [String] = []
    weak var window: NSWindow?
    private let fileOps = FileOperations()
    /// shortcut: extracted archives stay in the temp folder until macOS clears it; delete them on close if disk use matters.
    private var extracted: [URL: URL] = [:]
    private var compareTask: Task<Void, Never>?

    /// One visible table row: an entry and its indent level.
    struct Row: Identifiable {
        let entry: FolderEntry
        let depth: Int
        var id: String { entry.id }
    }

    var visibleEntries: [FolderEntry] { filtered(entries) }

    /// Rows after filtering, folder expansion, and flattening.
    var rows: [Row] {
        var out: [Row] = []
        func walk(_ list: [FolderEntry], _ depth: Int) {
            for e in list {
                if flatten {
                    if let kids = e.children { walk(kids, 0); continue }
                    var flat = e
                    flat.name = e.relativePath
                    out.append(Row(entry: flat, depth: 0))
                } else {
                    out.append(Row(entry: e, depth: depth))
                    if let kids = e.children, expanded.contains(e.id) { walk(kids, depth + 1) }
                }
            }
        }
        walk(visibleEntries, 0)
        return out
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func expandAll() { expanded = Set(index.values.filter { $0.children != nil }.map(\.id)) }

    func collapseAll() { expanded = [] }

    enum SelectKind { case all, differences, leftOnly, rightOnly, newerLeft, newerRight }

    func select(_ kind: SelectKind) {
        selection = Set(rows.map(\.entry).filter { e in
            switch kind {
            case .all: true
            case .differences: e.status != .same
            case .leftOnly: e.status == .leftOnly
            case .rightOnly: e.status == .rightOnly
            case .newerLeft: e.status == .leftNewer
            case .newerRight: e.status == .rightNewer
            }
        }.map(\.id))
    }

    /// Copies each selected item from the side where it is newer or the only copy. Items that merely differ are skipped.
    func smartCopyOps(_ ids: Set<String>) -> [SyncOp] {
        ids.sorted().flatMap { id -> [SyncOp] in
            switch index[id]?.status {
            case .leftOnly, .leftNewer: copyOps([id], toRight: true)
            case .rightOnly, .rightNewer: copyOps([id], toRight: false)
            default: []
            }
        }
    }

    func stop() {
        compareTask?.cancel()
    }
    var canSync: Bool { left?.writable == true && right?.writable == true }

    /// File counts by status (folders are not counted).
    var counts: (same: Int, differ: Int, leftOnly: Int, rightOnly: Int) {
        var c = (same: 0, differ: 0, leftOnly: 0, rightOnly: 0)
        for e in index.values where !e.isDirectory {
            switch e.status {
            case .same: c.same += 1
            case .leftOnly: c.leftOnly += 1
            case .rightOnly: c.rightOnly += 1
            default: c.differ += 1
            }
        }
        return c
    }

    /// "3 files, 1.2 MB · 763 GB free" for one side's status bar.
    func sideStats(left isLeft: Bool) -> String {
        guard let side = isLeft ? left : right else { return "" }
        let files = index.values.compactMap { isLeft ? $0.left : $0.right }.filter { !$0.isDirectory }
        var text = "\(files.count) file\(files.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file))"
        if side.writable, let root = side.root,
           let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            text += " · \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
        }
        return text
    }

    func note(_ message: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
    }

    func swap() {
        (leftURL, rightURL) = (rightURL, leftURL)
        note("Swapped sides")
        refresh()
    }

    func refresh() {
        guard let l = leftURL, let r = rightURL else { return }
        isBusy = true
        let started = Date()
        let tokens = masks(masksText)
        let include = tokens.filter { !$0.hasPrefix("-") }, exclude = tokens.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
        let options = FolderCompareOptions(compareContents: compareContents, includeMasks: include.isEmpty ? ["*"] : include,
                                           excludeMasks: exclude, ignoreTimestamps: !showMinor)
        let known = extracted
        compareTask?.cancel()
        compareTask = Task {
            do {
                let (ls, rs, result) = try await Task.detached(priority: .userInitiated) { () -> (Side, Side, [FolderEntry]) in
                    let ls = try Self.resolve(l, extracted: known), rs = try Self.resolve(r, extracted: known)
                    return (ls, rs, try compareFolders(left: ls.source, right: rs.source, options: options))
                }.value
                for (url, side) in [(l, ls), (r, rs)] where isArchive(url) { extracted[url] = side.root }
                left = ls
                right = rs
                entries = result
                index = indexEntries(result)
                selection = selection.filter { index[$0] != nil }
                // First load opens the folders that contain differences.
                if expanded.isEmpty { expanded = Set(index.values.filter { $0.children != nil && $0.status != .same }.map(\.id)) }
                let c = counts
                note("Compared \(l.path) ↔ \(r.path): \(c.differ) different, \(c.leftOnly + c.rightOnly) orphans, \(c.same) same "
                     + "(\(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(2)))) s)")
            } catch is CancellationError {
                note("Stopped")
            } catch {
                errorMessage = error.localizedDescription
                note("Error: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    nonisolated private static func resolve(_ url: URL, extracted: [URL: URL]) throws -> Side {
        if url.pathExtension == FolderSnapshot.fileExtension {
            return Side(source: .snapshot(try FolderSnapshot.read(url)), root: nil, writable: false)
        }
        if isArchive(url) {
            let dir = try extracted[url] ?? extractArchive(url)
            return Side(source: .directory(dir), root: dir, writable: false)
        }
        return Side(source: .directory(url), root: url, writable: true)
    }

    /// Copies for the selected items that exist on the source side, into a writable destination.
    func copyOps(_ ids: Set<String>, toRight: Bool) -> [SyncOp] {
        guard let src = (toRight ? left : right)?.root, let dst = toRight ? right : left, dst.writable, let dstRoot = dst.root else { return [] }
        return ids.sorted().compactMap { index[$0] }.compactMap { e in
            guard (toRight ? e.left : e.right) != nil else { return nil }
            return .copy(from: src.appending(path: e.relativePath), to: dstRoot.appending(path: e.relativePath))
        }
    }

    func trashOps(_ ids: Set<String>, onLeft: Bool) -> [SyncOp] {
        guard (onLeft ? left : right)?.writable == true else { return [] }
        return ids.sorted().compactMap { index[$0] }.compactMap { e in (onLeft ? e.left : e.right).map { .trash($0.url) } }
    }

    func syncPlan() -> [SyncOp] {
        guard canSync, let l = left?.root, let r = right?.root else { return [] }
        return planSync(entries, left: l, right: r, mode: syncMode)
    }

    func run(_ ops: [SyncOp], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [FileOperations.Failure] {
        let failures = await fileOps.run(ops, progress: progress)
        let failed = Set(failures.map(\.op))
        for op in ops where !failed.contains(op) {
            switch op {
            case let .copy(from, to): note("Copied \(describe(from)) → \(describe(to))")
            case let .trash(url): note("Moved to Trash: \(describe(url))")
            }
        }
        for f in failures { note("Failed: \(f.message)") }
        if !failures.isEmpty {
            errorMessage = failures.map(\.message).joined(separator: "\n")
        }
        refresh()
        return failures
    }

    func open(_ id: String) {
        guard let e = index[id], let a = e.left, let b = e.right, a.isDirectory == b.isDirectory, !a.isSnapshot, !b.isSnapshot else { return }
        WindowManager.shared.open(OpenRequest(kind: a.isDirectory ? .folder : (OpenRequest.Kind.detect([a.url.path, b.url.path]) ?? .text),
                                              paths: [a.url.path, b.url.path]))
    }

    func saveSnapshot(left isLeft: Bool) {
        guard let root = (isLeft ? left : right)?.root, (isLeft ? left : right)?.writable == true else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = root.lastPathComponent + "." + FolderSnapshot.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FolderSnapshot.capture(root).write(to: url)
            note("Saved snapshot \(url.path)")
        } catch { errorMessage = error.localizedDescription }
    }

    func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "folder-compare.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = htmlFolderReport(entries: entries, leftName: leftURL?.path ?? "left", rightName: rightURL?.path ?? "right")
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            note("Saved report \(url.path)")
        } catch { errorMessage = error.localizedDescription }
    }

    /// Path shown to the user, e.g. "right/sub/file.txt".
    func describe(_ url: URL) -> String {
        for (root, name) in [(left?.root, "left"), (right?.root, "right")] {
            if let root, url.path.hasPrefix(root.path + "/") { return name + "/" + url.path.dropFirst(root.path.count + 1) }
        }
        return url.path
    }

    private func filtered(_ list: [FolderEntry]) -> [FolderEntry] {
        list.compactMap { e in
            guard let kids = e.children else { return keep(e) ? e : nil }
            let shown = filtered(kids)
            if shown.isEmpty, !keep(e) { return nil }
            var copy = e
            copy.children = shown
            return copy
        }
    }

    private func keep(_ e: FolderEntry) -> Bool {
        switch filter {
        case .all: true
        case .differences: e.status != .same
        case .same: e.status == .same
        case .orphans: e.status == .leftOnly || e.status == .rightOnly
        }
    }

    private func masks(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
