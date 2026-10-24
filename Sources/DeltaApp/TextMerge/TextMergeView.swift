import AppKit
import DiffCore
import SwiftUI

struct TextMergeView: View {
    @ObservedObject var model: TextMergeModel

    var body: some View {
        let n = model.conflicts.count
        VStack(spacing: 0) {
            VSplitView {
                HStack(spacing: 1) {
                    ForEach(TextMergeModel.Role.allCases) { role in
                        VStack(spacing: 0) {
                            PathBar(title: role.rawValue, url: model.urls[role]) { model.load($0, role: role) }
                            CodePane(text: model.texts[role] ?? "", textToken: model.inputToken, highlights: highlights(role),
                                     editable: false, scrollLine: scrollLine(role), scrollToken: model.scrollToken, label: "\(role.rawValue) input")
                        }
                    }
                }
                .frame(minHeight: 160)
                VStack(spacing: 0) {
                    outputBar
                    CodePane(text: model.outputText, textToken: model.outputToken,
                             highlights: model.conflicts.map { ($0.lines, DiffColors.conflict) },
                             editable: true, onEdit: model.edited,
                             scrollLine: model.conflicts.indices.contains(model.current) ? model.conflicts[model.current].lines.lowerBound : nil,
                             scrollToken: model.scrollToken, label: "Merged output")
                }
                .frame(minHeight: 160)
            }
            StatusBar(left: "Red: conflicts · Green: merged automatically",
                      center: model.chunks.isEmpty ? "Choose left, base and right files" : n == 0 ? "No conflicts left" : "Conflict \(model.current + 1) of \(n)",
                      right: model.dirty ? "Output edited, not saved" : "")
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            SessionToolbar()
            ToolbarItemGroup {
                Button { model.go(-1) } label: { Label("Previous", systemImage: "arrow.up") }
                    .disabled(n == 0).help("Previous conflict (⌘↑)")
                Button { model.go(1) } label: { Label("Next", systemImage: "arrow.down") }
                    .disabled(n == 0).help("Next conflict (⌘↓)")
                Button { model.resolve(.left) } label: { Label("Take Left", systemImage: "arrow.left.square") }
                    .disabled(n == 0).help("Use the left side for this conflict")
                Button { model.resolve(.right) } label: { Label("Take Right", systemImage: "arrow.right.square") }
                    .disabled(n == 0).help("Use the right side for this conflict")
                Button { model.resolve(.both) } label: { Label("Take Both", systemImage: "square.split.2x1") }
                    .disabled(n == 0).help("Keep left then right")
                Button { model.resolve(.base) } label: { Label("Take Base", systemImage: "arrow.uturn.backward.square") }
                    .disabled(n == 0).help("Keep the original text")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s")
                    .disabled(model.chunks.isEmpty)
                    .help("Save the merged output (⌘S)")
            }
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: model.go))
    }

    private var outputBar: some View {
        HStack(spacing: 8) {
            Text("Output").font(.headline)
            Text(model.outputURL?.path(percentEncoded: false) ?? "Not saved yet — Save asks where")
                .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    /// Changed regions in each input: red for conflicts, green for changes that merged on their own.
    private func highlights(_ role: TextMergeModel.Role) -> [(Range<Int>, NSColor)] {
        model.chunks.compactMap { c in
            let color = c.kind == .conflict ? DiffColors.conflict : DiffColors.merged
            switch (role, c.kind) {
            case (_, .stable): return nil
            case (.base, _): return (c.base, color)
            case (.left, .left), (.left, .both), (.left, .conflict): return (c.left, color)
            case (.right, .right), (.right, .both), (.right, .conflict): return (c.right, color)
            default: return nil
            }
        }
    }

    private func scrollLine(_ role: TextMergeModel.Role) -> Int? {
        guard let c = model.currentChunk else { return nil }
        switch role {
        case .left: return c.left.lowerBound
        case .base: return c.base.lowerBound
        case .right: return c.right.lowerBound
        }
    }
}

/// Single text pane for SwiftUI: reloads text only when `textToken` changes, so typing is never clobbered.
struct CodePane: NSViewRepresentable {
    var text: String
    var textToken: Int
    var highlights: [(Range<Int>, NSColor)]
    var editable: Bool
    var onEdit: ((String) -> Void)?
    var scrollLine: Int?
    var scrollToken: Int
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = makeTextPane(editable: editable, label: label)
        tv.delegate = context.coordinator
        context.coordinator.tv = tv
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak scroll] _ in
            MainActor.assumeIsolated { scroll?.verticalRulerView?.needsDisplay = true }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onEdit = onEdit
        guard let tv = c.tv else { return }
        if c.textToken != textToken {
            c.textToken = textToken
            if tv.string != text {
                tv.string = text
                tv.lineStarts = lineStartOffsets(text)
            }
        }
        tv.lineHighlights = highlights.map { (tv.charRange(lines: $0.0), $0.1) }
        if c.scrollToken != scrollToken {
            c.scrollToken = scrollToken
            if let scrollLine { tv.scrollToLine(max(0, scrollLine - 3)) }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.observer.map(NotificationCenter.default.removeObserver)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        weak var tv: DiffTextView?
        var textToken = -1
        var scrollToken = 0
        var onEdit: ((String) -> Void)?
        var observer: NSObjectProtocol?

        func textDidChange(_ notification: Notification) {
            guard let tv else { return }
            tv.lineStarts = lineStartOffsets(tv.string)
            onEdit?(tv.string)
        }
    }
}
