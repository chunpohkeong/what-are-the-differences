import AppKit
import DiffCore

@MainActor final class TextMergeModel: ObservableObject {
    enum Role: String, CaseIterable, Identifiable {
        case left = "Left", base = "Base", right = "Right"
        var id: String { rawValue }
    }

    enum Choice { case left, right, both, base }

    @Published private(set) var urls: [Role: URL] = [:]
    @Published var outputURL: URL?
    @Published private(set) var texts: [Role: String] = [:]
    @Published private(set) var inputToken = 0
    @Published private(set) var chunks: [MergeChunk] = []
    @Published private(set) var outputText = ""
    /// Bumped when output is replaced by the model (not by typing), so the editor reloads it.
    @Published private(set) var outputToken = 0
    @Published private(set) var conflicts: [ConflictBlock] = []
    @Published private(set) var current = 0
    @Published private(set) var scrollToken = 0
    @Published private(set) var dirty = false
    @Published var errorMessage: String?
    weak var window: NSWindow?
    private var lines: [Role: [String]] = [:]
    private var outputDoc = TextDocument()

    var currentChunk: MergeChunk? {
        guard conflicts.indices.contains(current), let id = conflicts[current].id, chunks.indices.contains(id) else { return nil }
        return chunks[id]
    }

    func load(_ url: URL, role: Role) {
        do {
            let doc = try TextDocument.load(url)
            urls[role] = url
            texts[role] = doc.text
            lines[role] = splitLines(doc.text)
            if role == .left { outputDoc = doc }
            inputToken += 1
            remerge()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rebuilds output from the inputs; a missing base is treated as empty (everything conflicts).
    private func remerge() {
        guard let l = lines[.left], let r = lines[.right] else { return }
        let b = lines[.base] ?? []
        chunks = merge3(base: b, left: l, right: r)
        setOutput(join(renderMerge(chunks, base: b, left: l, right: r)))
        current = 0
        dirty = false
    }

    func edited(_ text: String) {
        dirty = true
        setOutput(text, fromEditor: true)
    }

    func resolve(_ choice: Choice) {
        guard conflicts.indices.contains(current) else { return }
        let block = conflicts[current]
        var out = splitLines(outputText)
        switch choice {
        case .left: out.replaceSubrange(block.lines, with: block.left)
        case .right: out.replaceSubrange(block.lines, with: block.right)
        case .both: out.replaceSubrange(block.lines, with: block.left + block.right)
        case .base: out.replaceSubrange(block.lines, with: block.base)
        }
        dirty = true
        setOutput(join(out))
        scrollToken += 1
    }

    func go(_ step: Int) {
        guard !conflicts.isEmpty else { return }
        current = (current + step + conflicts.count) % conflicts.count
        scrollToken += 1
    }

    func save() {
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(conflicts.count) unresolved conflict\(conflicts.count == 1 ? "" : "s") remain."
            alert.informativeText = "Save anyway with conflict markers in the file?"
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var target = outputURL
        if target == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = urls[.left]?.lastPathComponent ?? "merged.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let url = target else { return }
        do {
            try outputDoc.data(for: outputText).write(to: url, options: .atomic)
            outputURL = url
            dirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setOutput(_ text: String, fromEditor: Bool = false) {
        outputText = text
        conflicts = findConflicts(in: splitLines(text))
        current = min(current, max(conflicts.count - 1, 0))
        if !fromEditor { outputToken += 1 }
    }

    private func join(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
}
