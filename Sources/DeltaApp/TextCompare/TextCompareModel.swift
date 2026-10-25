import AppKit
import DiffCore
import PDFKit

@MainActor final class TextCompareModel: ObservableObject {
    enum Side: Hashable { case left, right }

    @Published private(set) var urls: [Side: URL] = [:]
    @Published private(set) var hunks: [DiffHunk] = []
    @Published private(set) var lineCounts = (left: 0, right: 0)
    @Published var options = DiffOptions() { didSet { recompute(delay: false) } }
    @Published private(set) var dirty: Set<Side> = []
    /// Text that did not come from a plain text file (clipboard, PDF, patch result), shown in place of a path.
    @Published private(set) var labels: [Side: String] = [:]
    /// PDF sides: saving goes through a Save panel so the PDF is never overwritten with text.
    private var readOnly: Set<Side> = []
    @Published var errorMessage: String?
    @Published private(set) var current: Int?
    /// Bumped when text is replaced from disk, so the views reload it.
    @Published private(set) var loadToken = 0
    @Published private(set) var scrollToken = 0
    private(set) var scrollTarget = (left: 0, right: 0)
    /// Copy one difference across; executed by the text views so it can be undone.
    @Published private(set) var copyToken = 0
    private(set) var copyRequest: (hunk: Int, fromLeft: Bool)?
    /// Line the caret is on, for the line-details pane.
    @Published private(set) var cursor: (side: Side, line: Int)?
    /// Lines the current hunks were computed from.
    private(set) var lines: [Side: [String]] = [:]
    private(set) var texts: [Side: String] = [.left: "", .right: ""]
    private var docs: [Side: TextDocument] = [:]
    private var diffTask: Task<Void, Never>?

    /// Which lines the panes show. Anything but `.all` is a read-only filtered view.
    enum ViewMode { case all, diffs, same, context }

    /// Filtered text for both panes. `numbers` gives each shown line's original number (nil for a "⋯" gap).
    struct Display {
        var left: String
        var right: String
        var leftNumbers: [Int?]
        var rightNumbers: [Int?]
        var hunks: [DiffHunk]
    }

    @Published var viewMode: ViewMode = .all { didSet { rebuildDisplay() } }
    @Published private(set) var display: Display?
    @Published private(set) var displayToken = 0
    @Published var fontSize: CGFloat = 12
    weak var window: NSWindow?

    var changes: [DiffHunk] { hunks.filter { $0.kind == .change } }
    var hasBothFiles: Bool { Set(urls.keys).union(labels.keys).count == 2 }

    func load(_ url: URL, side: Side) {
        if url.pathExtension.lowercased() == "pdf" {
            guard let text = PDFDocument(url: url)?.string else {
                errorMessage = "Could not read text from \(url.lastPathComponent)."
                return
            }
            setText(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), side: side, label: nil)
            urls[side] = url
            readOnly.insert(side)
            return
        }
        do {
            let doc = try TextDocument.load(url)
            docs[side] = doc
            texts[side] = doc.text
            urls[side] = url
            labels[side] = nil
            readOnly.remove(side)
            dirty.remove(side)
            current = nil
            loadToken += 1
            recompute(delay: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces one side with text that has no file behind it.
    func setText(_ text: String, side: Side, label: String?, dirty isDirty: Bool = false) {
        docs[side] = nil
        texts[side] = text
        urls[side] = nil
        labels[side] = label
        readOnly.remove(side)
        if isDirty { dirty.insert(side) } else { dirty.remove(side) }
        current = nil
        loadToken += 1
        recompute(delay: false)
    }

    /// Files dropped on a pane: one loads into that side, two load left and right.
    /// Folders, archives and snapshots open a Folder Compare tab instead, on the side they were dropped.
    func dropped(_ urls: [URL], on side: Side) {
        let pair = Array(urls.prefix(2))
        let folderLike = pair.contains { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || isArchive(url) || url.pathExtension == FolderSnapshot.fileExtension
        }
        if folderLike {
            guard let folder = WindowManager.shared.open(OpenRequest(kind: .folder), tabbedWith: window) as? FolderCompareModel else { return }
            if pair.count == 2 { (folder.leftURL, folder.rightURL) = (pair[0], pair[1]) }
            else if side == .left { folder.leftURL = pair[0] } else { folder.rightURL = pair[0] }
            folder.refresh()
            return
        }
        let targets: [(URL, Side)] = pair.count == 2 ? [(pair[0], .left), (pair[1], .right)] : [(pair[0], side)]
        guard confirmReplacing(targets.map(\.1)) else { return }
        for (url, target) in targets {
            load(url, side: target)
            PathHistory.add(url, folders: false)
        }
    }

    /// Asks before replacing sides that have unsaved edits.
    func confirmReplacing(_ sides: [Side]) -> Bool {
        guard sides.contains(where: dirty.contains) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace the edited text?"
        alert.informativeText = "Unsaved edits on that side will be lost."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openFile(_ side: Side) {
        guard let url = choosePath(directories: false), confirmReplacing([side]) else { return }
        load(url, side: side)
        PathHistory.add(url, folders: false)
    }

    func openClipboard(_ side: Side) {
        guard let text = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        guard confirmReplacing([side]) else { return }
        setText(text, side: side, label: "Clipboard")
    }

    func edited(_ text: String, side: Side) {
        texts[side] = text
        dirty.insert(side)
        recompute(delay: true)
    }

    /// Diffs off the main actor; typing is debounced so each keystroke does not re-diff.
    func recompute(delay: Bool) {
        diffTask?.cancel()
        let l = texts[.left] ?? "", r = texts[.right] ?? "", opts = options
        diffTask = Task {
            if delay { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> ([DiffHunk], [String], [String]) in
                let a = splitLines(l), b = splitLines(r)
                return (diffLines(a, b, options: opts), a, b)
            }.value
            guard !Task.isCancelled else { return }
            lines = [.left: result.1, .right: result.2]
            hunks = result.0
            lineCounts = (result.1.count, result.2.count)
            if let c = current, c >= changes.count { current = nil }
            if viewMode != .all { rebuildDisplay() }
        }
    }

    func go(_ step: Int) {
        let count = changes.count
        guard count > 0 else { return }
        jump(to: current.map { min(max($0 + step, 0), count - 1) } ?? (step > 0 ? 0 : count - 1))
    }

    func setCursor(side: Side, line: Int) { cursor = (side, line) }

    /// The left and right line at the caret (matched through the diff), for the line-details pane.
    var lineDetail: (left: String?, right: String?)? {
        guard let cursor else { return nil }
        let l = cursor.side == .left ? cursor.line : mapLine(cursor.line, hunks: hunks, fromLeft: false)
        let r = cursor.side == .right ? cursor.line : mapLine(cursor.line, hunks: hunks, fromLeft: true)
        let a = lines[.left] ?? [], b = lines[.right] ?? []
        return (a.indices.contains(l) ? a[l] : nil, b.indices.contains(r) ? b[r] : nil)
    }

    /// The difference under the caret, else the one last navigated to.
    private var targetHunk: Int? {
        if let cursor {
            let hit = hunks.firstIndex { h in
                let range = cursor.side == .left ? h.left : h.right
                return h.kind == .change && (range.contains(cursor.line) || (range.isEmpty && range.lowerBound == cursor.line))
            }
            if let hit { return hit }
        }
        guard let current, changes.indices.contains(current) else { return nil }
        return hunks.firstIndex(of: changes[current])
    }

    var canCopy: Bool { viewMode == .all && targetHunk != nil }

    private func rebuildDisplay() {
        display = viewMode == .all ? nil : makeDisplay()
        displayToken += 1
    }

    private func makeDisplay() -> Display {
        let a = lines[.left] ?? [], b = lines[.right] ?? []
        var segments: [(left: Range<Int>, right: Range<Int>)] = []
        switch viewMode {
        case .all: break
        case .diffs: segments = hunks.filter { $0.kind == .change }.map { ($0.left, $0.right) }
        case .same: segments = hunks.filter { $0.kind == .equal }.map { ($0.left, $0.right) }
        case .context:
            // Each difference plus up to 3 unchanged lines either side; overlapping windows merge.
            for h in hunks where h.kind == .change {
                let before = min(3, h.left.lowerBound, h.right.lowerBound)
                let after = min(3, a.count - h.left.upperBound, b.count - h.right.upperBound)
                let next = ((h.left.lowerBound - before)..<(h.left.upperBound + after), (h.right.lowerBound - before)..<(h.right.upperBound + after))
                if let last = segments.last, next.0.lowerBound <= last.left.upperBound {
                    segments[segments.count - 1] = (last.left.lowerBound..<max(last.left.upperBound, next.0.upperBound),
                                                    last.right.lowerBound..<max(last.right.upperBound, next.1.upperBound))
                } else {
                    segments.append(next)
                }
            }
        }
        var dl: [String] = [], dr: [String] = [], nl: [Int?] = [], nr: [Int?] = []
        for (i, seg) in segments.enumerated() {
            if i > 0 { dl.append("⋯"); dr.append("⋯"); nl.append(nil); nr.append(nil) }
            dl += a[seg.left]; nl += seg.left.map { $0 }
            dr += b[seg.right]; nr += seg.right.map { $0 }
        }
        func join(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
        return Display(left: join(dl), right: join(dr), leftNumbers: nl, rightNumbers: nr, hunks: diffLines(dl, dr, options: options))
    }

    // MARK: Encoding and line endings (applied on the next save)

    static let encodings: [(name: String, encoding: String.Encoding, bom: Bool)] = [
        ("Unicode (UTF-8)", .utf8, false),
        ("Unicode (UTF-8 with BOM)", .utf8, true),
        ("Unicode (UTF-16 LE)", .utf16LittleEndian, true),
        ("Unicode (UTF-16 BE)", .utf16BigEndian, true),
        ("Western (Latin-1)", .isoLatin1, false),
    ]
    static let lineEndings: [(name: String, value: String)] = [("LF (macOS, Unix)", "\n"), ("CRLF (Windows)", "\r\n"), ("CR (Classic Mac)", "\r")]

    func encodingName(_ side: Side) -> String {
        let doc = docs[side] ?? TextDocument()
        return Self.encodings.first { $0.encoding == doc.encoding && $0.bom == doc.hasBOM }?.name ?? "Other"
    }

    func lineEndingName(_ side: Side) -> String {
        let doc = docs[side] ?? TextDocument()
        return (Self.lineEndings.first { $0.value == doc.lineEnding }?.name ?? "LF").components(separatedBy: " ").first ?? "LF"
    }

    func isPDF(_ side: Side) -> Bool { readOnly.contains(side) }

    func setEncoding(_ encoding: String.Encoding, bom: Bool, side: Side) {
        var doc = docs[side] ?? TextDocument()
        doc.encoding = encoding
        doc.hasBOM = bom
        docs[side] = doc
        dirty.insert(side)
    }

    func setLineEnding(_ ending: String, side: Side) {
        var doc = docs[side] ?? TextDocument()
        doc.lineEnding = ending
        docs[side] = doc
        dirty.insert(side)
    }

    /// "Today 1:03 PM · 10 bytes · 17 lines" for the row under each path.
    func fileMeta(_ side: Side) -> String {
        var parts: [String] = []
        if let url = urls[side], let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            if let date = v.contentModificationDate {
                let day = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(date: .abbreviated, time: .omitted)
                parts.append("\(day), \(date.formatted(date: .omitted, time: .standard))")
            }
            if let size = v.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        } else if let label = labels[side] {
            parts.append(label)
        }
        if urls[side] != nil || labels[side] != nil {
            parts.append("\(side == .left ? lineCounts.left : lineCounts.right) lines")
        }
        if readOnly.contains(side) { parts.append("PDF text, read-only") }
        return parts.joined(separator: " · ")
    }

    func requestCopy(fromLeft: Bool) {
        guard let hunk = targetHunk else { NSSound.beep(); return }
        copyRequest = (hunk, fromLeft)
        copyToken += 1
    }

    /// "Today 1:03 PM · 10 bytes · UTF-8 · LF · 17 lines" for the row under each path.
    func fileInfo(_ side: Side) -> String {
        var parts: [String] = []
        if let url = urls[side], let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            if let date = v.contentModificationDate {
                let day = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(date: .abbreviated, time: .omitted)
                parts.append("\(day) \(date.formatted(date: .omitted, time: .shortened))")
            }
            if let size = v.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        }
        let rest = info(side)
        if !rest.isEmpty { parts.append(rest) }
        return parts.joined(separator: " · ")
    }

    func jump(to index: Int) {
        let c = changes
        guard c.indices.contains(index) else { return }
        current = index
        scrollTarget = (c[index].left.lowerBound, c[index].right.lowerBound)
        scrollToken += 1
    }

    /// Writes one side; `asNew` (or a PDF side) asks where.
    func save(_ side: Side, asNew: Bool = false) {
        var target = asNew || readOnly.contains(side) ? nil : urls[side]
        if target == nil {
            let panel = NSSavePanel()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let url = target else { return }
        do {
            try (docs[side] ?? TextDocument()).data(for: texts[side] ?? "").write(to: url, options: .atomic)
            urls[side] = url
            labels[side] = nil
            readOnly.remove(side)
            dirty.remove(side)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "UTF-8 · LF · 18 lines" for the status bar.
    func info(_ side: Side) -> String {
        guard urls[side] != nil || labels[side] != nil else { return "" }
        let lines = side == .left ? lineCounts.left : lineCounts.right
        let edited = dirty.contains(side) ? " · edited" : ""
        if readOnly.contains(side) { return "PDF text (read-only) · \(lines) lines\(edited)" }
        let doc = docs[side] ?? TextDocument()
        let encoding = switch doc.encoding {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .isoLatin1: "Latin-1"
        default: "Text"
        }
        let eol = doc.lineEnding == "\r\n" ? "CRLF" : doc.lineEnding == "\r" ? "CR" : "LF"
        return "\(encoding)\(doc.hasBOM ? " with BOM" : "") · \(eol) · \(lines) lines\(edited)"
    }

    /// Exchanges the two sides, including unsaved edits.
    func swap() {
        func flip<V>(_ d: [Side: V]) -> [Side: V] {
            var out: [Side: V] = [:]
            out[.left] = d[.right]
            out[.right] = d[.left]
            return out
        }
        urls = flip(urls)
        texts = flip(texts).merging([.left: "", .right: ""]) { kept, _ in kept }
        docs = flip(docs)
        labels = flip(labels)
        readOnly = Set(readOnly.map { $0 == .left ? .right : .left })
        dirty = Set(dirty.map { $0 == .left ? .right : .left })
        current = nil
        loadToken += 1
        recompute(delay: false)
    }

    /// Reads both files again from disk, after confirming if that would drop edits.
    func reload() {
        if !dirty.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reload and discard your edits?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for side in [Side.left, .right] { if let url = urls[side] { load(url, side: side) } }
    }

    private func name(_ side: Side) -> String { urls[side]?.path ?? labels[side] ?? (side == .left ? "left" : "right") }

    /// Unified diff from left to right, always line-exact (ignore options would make an invalid patch).
    func exportPatch() {
        let a = splitLines(texts[.left] ?? ""), b = splitLines(texts[.right] ?? "")
        let patch = unifiedDiff(left: a, right: b, hunks: diffLines(a, b), leftName: name(.left), rightName: name(.right))
        guard !patch.isEmpty else { errorMessage = "The two sides are identical; there is nothing to export."; return }
        save(patch, suggested: "changes.patch")
    }

    /// Applies a patch to the left text and shows the result, unsaved, on the right for review.
    func applyPatch() {
        guard let url = choosePath(directories: false) else { return }
        do {
            let patch = try String(contentsOf: url, encoding: .utf8)
            let result = try DiffCore.applyPatch(patch, to: splitLines(texts[.left] ?? ""))
            setText(result.isEmpty ? "" : result.joined(separator: "\n") + "\n", side: .right, label: "Patched with \(url.lastPathComponent) (unsaved)", dirty: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveReport() {
        save(htmlTextReport(left: splitLines(texts[.left] ?? ""), right: splitLines(texts[.right] ?? ""), hunks: hunks,
                            leftName: name(.left), rightName: name(.right)), suggested: "text-compare.html")
    }

    private func save(_ text: String, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { errorMessage = error.localizedDescription }
    }
}
