import DiffCore
import SwiftUI

struct TextCompareView: View {
    @ObservedObject var model: TextCompareModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    PathBar(title: "Left", url: model.urls[.left], label: model.labels[.left], edited: model.dirty.contains(.left),
                            onChoose: { model.load($0, side: .left) }, onSave: { model.save(.left) })
                    FileInfoRow(model: model, side: .left)
                }
                VStack(spacing: 0) {
                    PathBar(title: "Right", url: model.urls[.right], label: model.labels[.right], edited: model.dirty.contains(.right),
                            onChoose: { model.load($0, side: .right) }, onSave: { model.save(.right) })
                    FileInfoRow(model: model, side: .right)
                }
            }
            Divider()
            HStack(spacing: 0) {
                DualTextView(model: model)
                DiffMapView(hunks: model.hunks, lineCounts: model.lineCounts, onSelect: model.jump(to:))
                    .frame(width: 16)
            }
            Divider()
            LineDetailView(detail: model.lineDetail)
            StatusBar(left: caret(.left), center: summary, right: caret(.right))
        }
        .frame(minWidth: 700, minHeight: 400)
        .toolbar {
            // Home · Sessions | All · Diffs · Same · Context · Minor · Rules · Format | Copy · Next Section · Prev Section · Swap · Reload | More
            SessionToolbar()
            ToolbarItemGroup {
                Toggle(isOn: modeBinding(.all)) { Label("All", systemImage: "asterisk") }
                    .help("Show every line (editable)")
                Toggle(isOn: modeBinding(.diffs)) { Label("Diffs", systemImage: "notequal") }
                    .help("Show only the differences (read-only)")
                Toggle(isOn: modeBinding(.same)) { Label("Same", systemImage: "equal") }
                    .help("Show only matching lines (read-only)")
                Toggle(isOn: modeBinding(.context)) { Label("Context", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .help("Show differences with 3 lines around each (read-only)")
                Toggle(isOn: minorBinding) { Label("Minor", systemImage: "plusminus") }
                    .help("On: whitespace and letter-case changes count as differences. Off: they are ignored.")
                Menu {
                    Toggle("Ignore Whitespace", isOn: $model.options.ignoreWhitespace)
                    Toggle("Ignore Case", isOn: $model.options.ignoreCase)
                } label: { Label("Rules", systemImage: "slider.horizontal.3") }
                    .help("What counts as a difference")
                Menu {
                    Picker("Text Size", selection: $model.fontSize) {
                        ForEach([10, 11, 12, 13, 14, 16, 18], id: \.self) { Text("\($0) pt").tag(CGFloat($0)) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Format", systemImage: "textformat.size") }
                    .help("Text size (encoding and line endings are under each path)")
            }
            ToolbarItemGroup {
                Menu {
                    Button("Copy to Right →") { model.requestCopy(fromLeft: true) }
                    Button("← Copy to Left") { model.requestCopy(fromLeft: false) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                } primaryAction: { model.requestCopy(fromLeft: model.cursor?.side != .right) }
                    .disabled(!model.canCopy)
                    .help("Copy the difference at the caret to the other side (menu: choose a direction). ⌘Z undoes it. Available in All view.")
                Button { model.go(1) } label: { Label("Next Section", systemImage: "arrow.down") }
                    .disabled(model.changes.isEmpty)
                    .help("Next difference (⌘↓)")
                Button { model.go(-1) } label: { Label("Prev Section", systemImage: "arrow.up") }
                    .disabled(model.changes.isEmpty)
                    .help("Previous difference (⌘↑)")
                Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                    .help("Swap left and right")
                Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read both files again from disk")
                    .disabled(model.urls.isEmpty)
            }
            ToolbarItemGroup {
                Menu {
                    Button("Export Patch…") { model.exportPatch() }
                    Button("Apply Patch to Left…") { model.applyPatch() }
                    Divider()
                    Button("Save Report…") { model.saveReport() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: model.go))
    }

    private func modeBinding(_ mode: TextCompareModel.ViewMode) -> Binding<Bool> {
        Binding(get: { model.viewMode == mode }, set: { if $0 { model.viewMode = mode } })
    }

    /// Minor on = whitespace and case changes are shown as differences.
    private var minorBinding: Binding<Bool> {
        Binding(get: { !model.options.ignoreWhitespace && !model.options.ignoreCase },
                set: { show in model.options = DiffOptions(ignoreWhitespace: !show, ignoreCase: !show) })
    }

    private func caret(_ side: TextCompareModel.Side) -> String {
        guard let c = model.cursor, c.side == side else { return "" }
        return "Line \(c.line + 1)"
    }

    private var summary: String {
        let n = model.changes.count
        if n == 0 { return model.hasBothFiles ? "Identical" : "Choose two files to compare" }
        let position = model.current.map { "\($0 + 1) of " } ?? ""
        return "\(position)\(n) difference\(n == 1 ? "" : "s")"
    }
}

/// Overview strip: left half marks changed lines on the left, right half on the right. Click to jump.
struct DiffMapView: View {
    let hunks: [DiffHunk]
    let lineCounts: (left: Int, right: Int)
    let onSelect: (Int) -> Void

    var body: some View {
        let changes = hunks.filter { $0.kind == .change }
        GeometryReader { geo in
            Canvas { ctx, size in
                let lt = CGFloat(max(lineCounts.left, 1)), rt = CGFloat(max(lineCounts.right, 1))
                for h in changes {
                    let color: Color = h.left.isEmpty ? .green : h.right.isEmpty ? .red : .orange
                    for (range, total, x) in [(h.left, lt, CGFloat(0)), (h.right, rt, size.width / 2)] {
                        let rect = CGRect(x: x, y: size.height * CGFloat(range.lowerBound) / total,
                                          width: size.width / 2 - 1, height: max(2, size.height * CGFloat(range.count) / total))
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                let target = p.y / max(geo.size.height, 1) * CGFloat(max(lineCounts.left, 1))
                if let best = changes.indices.min(by: { abs(CGFloat(changes[$0].left.lowerBound) - target) < abs(CGFloat(changes[$1].left.lowerBound) - target) }) {
                    onSelect(best)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Difference map, \(changes.count) differences")
    }
}

/// Small caption under a path: date, size, encoding, line endings.
struct InfoRow: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 5)
            .background(.bar)
    }
}

/// The line at the caret on both sides, one above the other, with the changed characters marked.
struct LineDetailView: View {
    let detail: (left: String?, right: String?)?

    var body: some View {
        let left = detail?.left, right = detail?.right
        let (lr, rr) = (left != nil && right != nil) ? inlineDiff(left!, right!) : ([], [])
        VStack(spacing: 0) {
            row("arrow.right", left, lr, differs: left != right)
            Divider()
            row("arrow.left", right, rr, differs: left != right)
        }
        .frame(height: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current line. Left: \(left ?? "none"). Right: \(right ?? "none").")
    }

    private func row(_ icon: String, _ text: String?, _ ranges: [NSRange], differs: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            Text(styled(text ?? "", ranges, differs: differs && text != nil))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private func styled(_ text: String, _ ranges: [NSRange], differs: Bool) -> AttributedString {
        var out = AttributedString(text)
        guard differs else { return out }
        for r in ranges {
            guard let range = Range(r, in: out) else { continue }
            out[range].backgroundColor = Color(nsColor: DiffColors.changedInline)
            out[range].foregroundColor = .red
        }
        return out
    }
}

/// Under each path: date, size and line count, then encoding and line-ending menus (applied when the file is saved).
struct FileInfoRow: View {
    @ObservedObject var model: TextCompareModel
    let side: TextCompareModel.Side

    var body: some View {
        HStack(spacing: 14) {
            Text(model.fileMeta(side).isEmpty ? " " : model.fileMeta(side)).lineLimit(1)
            if model.urls[side] != nil || model.labels[side] != nil, !model.isPDF(side) {
                Menu(model.encodingName(side)) {
                    ForEach(TextCompareModel.encodings, id: \.name) { e in
                        Button(e.name) { model.setEncoding(e.encoding, bom: e.bom, side: side) }
                    }
                }
                .fixedSize()
                .help("Encoding used when this side is saved")
                Menu(model.lineEndingName(side)) {
                    ForEach(TextCompareModel.lineEndings, id: \.name) { e in
                        Button(e.name) { model.setLineEnding(e.value, side: side) }
                    }
                }
                .fixedSize()
                .help("Line endings used when this side is saved")
            }
            Spacer(minLength: 0)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.bottom, 5)
        .background(.bar)
    }
}
