import DiffCore
import SwiftUI

struct FolderCompareView: View {
    @ObservedObject var model: FolderCompareModel
    @State private var showLog = true
    @State private var tableWidth: CGFloat = 0
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            HStack(spacing: 1) {
                PathBar(title: "Left", url: model.leftURL, directories: true, allowFiles: true) { model.leftURL = $0; model.refresh() }
                PathBar(title: "Right", url: model.rightURL, directories: true, allowFiles: true) { model.rightURL = $0; model.refresh() }
            }
            Divider()
            table
            if showLog {
                Divider()
                LogPane(lines: model.log).frame(height: 96)
            }
            StatusBar(left: [model.sideStats(left: true), sideNote(model.left, "Left")].filter { !$0.isEmpty }.joined(separator: " · "),
                      center: summary,
                      right: [model.sideStats(left: false), sideNote(model.right, "Right")].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        .frame(minWidth: 900, minHeight: 420)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSync) { SyncSheet(model: model) }
        .confirmationDialog(model.pending?.title ?? "", isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }), presenting: model.pending) { p in
            Button(p.destructive ? "Move to Trash" : "Copy", role: p.destructive ? .destructive : nil) {
                Task { await model.run(p.ops) }
            }
        } message: { p in
            Text(p.ops.map(describe).joined(separator: "\n") + (p.destructive ? "" : "\n\nExisting items at the destination move to the Trash."))
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: { _ in }))
    }

    // Home · Sessions | All · Diffs · Same | Structure · Minor · Rules | Copy · Expand · Collapse · Select · Files | Refresh · Swap · Stop | More
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        SessionToolbar()
        ToolbarItemGroup {
            Toggle(isOn: filterBinding(.all)) { Label("All", systemImage: "asterisk") }
                .help("Show everything")
            Menu {
                Button("Differences and Orphans") { model.filter = .differences }
                Button("Orphans Only") { model.filter = .orphans }
            } label: {
                Label("Diffs", systemImage: "notequal")
            } primaryAction: { model.filter = .differences }
                .help("Show only differences (menu: orphans only)")
                .background(RoundedRectangle(cornerRadius: 6).fill(model.filter == .differences || model.filter == .orphans ? Color.primary.opacity(0.12) : .clear))
            Toggle(isOn: filterBinding(.same)) { Label("Same", systemImage: "equal") }
                .help("Show only matching items")
        }
        ToolbarItemGroup {
            Menu {
                Picker("Structure", selection: $model.flatten) {
                    Text("Show Folder Structure").tag(false)
                    Text("Ignore Folder Structure (Flat File List)").tag(true)
                }
                .pickerStyle(.inline)
            } label: { Label("Structure", systemImage: "list.bullet.indent") }
                .help("Folder tree or a flat list of files")
            Toggle(isOn: $model.showMinor) { Label("Minor", systemImage: "plusminus") }
                .onChange(of: model.showMinor) { model.refresh() }
                .help("On: files that differ only in timestamp count as different. Off: they count as the same.")
            Menu {
                Toggle("Compare File Contents", isOn: $model.compareContents)
                Toggle("Timestamp-Only Differences Matter", isOn: $model.showMinor)
            } label: { Label("Rules", systemImage: "slider.horizontal.3") }
                .onChange(of: model.compareContents) { model.refresh() }
                .help("How files are compared")
        }
        ToolbarItemGroup {
            Menu {
                Button("Copy to Right →") { confirmCopy(model.copyOps(model.selection, toRight: true), toward: "the right") }
                    .disabled(model.copyOps(model.selection, toRight: true).isEmpty)
                Button("← Copy to Left") { confirmCopy(model.copyOps(model.selection, toRight: false), toward: "the left") }
                    .disabled(model.copyOps(model.selection, toRight: false).isEmpty)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            } primaryAction: { confirmCopy(model.smartCopyOps(model.selection), toward: "the older side") }
                .disabled(model.selection.isEmpty)
                .help("Copy each selected item from its newer or only side (menu: choose a direction)")
            Button { model.expandAll() } label: { Label("Expand", systemImage: "chevron.down.square") }
                .disabled(model.flatten || model.entries.isEmpty)
                .help("Open every folder")
            Button { model.collapseAll() } label: { Label("Collapse", systemImage: "chevron.right.square") }
                .disabled(model.flatten || model.entries.isEmpty)
                .help("Close every folder")
            Menu {
                Button("All") { model.select(.all) }
                Button("All Differences") { model.select(.differences) }
                Divider()
                Button("Left Orphans") { model.select(.leftOnly) }
                Button("Right Orphans") { model.select(.rightOnly) }
                Divider()
                Button("Newer on Left") { model.select(.newerLeft) }
                Button("Newer on Right") { model.select(.newerRight) }
            } label: { Label("Select", systemImage: "checkmark.circle") }
                .disabled(model.entries.isEmpty)
                .help("Select rows by status")
            Button { model.selection.first.map(model.open) } label: { Label("Files", systemImage: "doc.text.magnifyingglass") }
                .disabled(model.selection.count != 1)
                .help("Compare the selected pair of files (or double-click a row)")
        }
        ToolbarItemGroup {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Compare again (⌘R)")
            Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                .help("Swap left and right")
            Button { model.stop() } label: { Label("Stop", systemImage: "xmark.circle") }
                .disabled(!model.isBusy)
                .help("Stop the comparison in progress")
            Menu {
                Button("Sync Folders…") { model.syncProgress = nil; model.syncFailures = []; model.showSync = true }
                    .disabled(model.entries.isEmpty || !model.canSync)
                Divider()
                Toggle("Show Log", isOn: $showLog)
                Divider()
                Button("Save Left Snapshot…") { model.saveSnapshot(left: true) }.disabled(model.left?.writable != true)
                Button("Save Right Snapshot…") { model.saveSnapshot(left: false) }.disabled(model.right?.writable != true)
                Divider()
                Button("Save Report…") { model.saveReport() }.disabled(model.entries.isEmpty)
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private func filterBinding(_ filter: FolderCompareModel.Filter) -> Binding<Bool> {
        Binding(get: { model.filter == filter }, set: { if $0 { model.filter = filter } })
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Text("Filters:")
            TextField("*.swift;-build", text: $model.masksText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { model.refresh() }
                .help("File masks separated by ; — a leading - excludes (e.g. *.swift;-build;-.DS_Store). Press Return to apply.")
                .accessibilityLabel("Filters")
            Button { model.refresh() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .help("Apply filters")
                .accessibilityLabel("Apply filters")
            Button { model.masksText = "*;-.DS_Store"; model.refresh() } label: { Image(systemName: "xmark.circle") }
                .help("Clear filters")
                .accessibilityLabel("Clear filters")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    // Mirrored layout: left file | copy arrows and status | right file.
    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("Name") { (row: FolderCompareModel.Row) in nameCell(row, side: row.entry.left, disclosure: true) }
            TableColumn("Size") { (row: FolderCompareModel.Row) in Text(row.entry.left.map(sizeText) ?? "").foregroundStyle(color(row.entry.status)) }.width(70)
            TableColumn("Modified") { (row: FolderCompareModel.Row) in Text(row.entry.left.map(dateText) ?? "").foregroundStyle(color(row.entry.status)) }.width(130)
            TableColumn("") { (row: FolderCompareModel.Row) in
                CopyArrows(entry: row.entry, model: model, onCopy: { toRight in
                    confirmCopy(model.copyOps([row.id], toRight: toRight), toward: toRight ? "the right" : "the left")
                })
            }
            .width(72)
            TableColumn("Name ") { (row: FolderCompareModel.Row) in nameCell(row, side: row.entry.right, disclosure: false) }
            TableColumn("Size ") { (row: FolderCompareModel.Row) in Text(row.entry.right.map(sizeText) ?? "").foregroundStyle(color(row.entry.status)) }.width(70)
            TableColumn("Modified ") { (row: FolderCompareModel.Row) in Text(row.entry.right.map(dateText) ?? "").foregroundStyle(color(row.entry.status)) }.width(130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Compare") { ids.first.map(model.open) }.disabled(ids.count != 1)
            Divider()
            Button("Copy to Right") { confirmCopy(model.copyOps(ids, toRight: true), toward: "the right") }
            Button("Copy to Left") { confirmCopy(model.copyOps(ids, toRight: false), toward: "the left") }
            Divider()
            Button("Move Left Items to Trash") { confirmTrash(ids, onLeft: true) }
            Button("Move Right Items to Trash") { confirmTrash(ids, onLeft: false) }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            if model.index[id]?.children != nil && !model.flatten { model.toggle(id) } else { model.open(id) }
        }
        .overlay {
            if model.entries.isEmpty && !model.isBusy {
                ContentUnavailableView("No Folders Yet", systemImage: "folder",
                                       description: Text("Drop a folder on the left or right half (or two folders anywhere), or type, paste or browse a path above."))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
        // Drop on the left or right half to set that side; two items set both.
        .dropDestination(for: URL.self) { urls, location in
            model.dropped(urls, onLeft: location.x < tableWidth / 2)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) }
        }
    }

    /// Indented name with a disclosure arrow for folders (left column only, so each row has one).
    @ViewBuilder private func nameCell(_ row: FolderCompareModel.Row, side: FileInfo?, disclosure: Bool) -> some View {
        let e = row.entry
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * 16)
            if disclosure && e.children != nil && !model.flatten {
                Button { model.toggle(e.id) } label: {
                    Image(systemName: model.expanded.contains(e.id) ? "chevron.down" : "chevron.right").frame(width: 12)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.expanded.contains(e.id) ? "Collapse \(e.name)" : "Expand \(e.name)")
            } else {
                Spacer().frame(width: 12)
            }
            if side != nil {
                Label(e.name, systemImage: e.isDirectory ? "folder" : "doc").foregroundStyle(color(e.status)).lineLimit(1)
            }
        }
    }

    private var summary: String {
        guard !model.entries.isEmpty else { return "" }
        let c = model.counts
        if c.differ + c.leftOnly + c.rightOnly == 0 { return "Folders match · \(c.same) files" }
        return "\(c.differ) different · \(c.leftOnly) left only · \(c.rightOnly) right only · \(c.same) same"
    }

    private func sideNote(_ side: FolderCompareModel.Side?, _ name: String) -> String {
        guard let side else { return "" }
        switch side.source {
        case .snapshot: return "\(name): snapshot (read-only)"
        case .directory: return side.writable ? "" : "\(name): archive (read-only)"
        }
    }

    private func confirmCopy(_ ops: [SyncOp], toward: String) {
        guard !ops.isEmpty else { NSSound.beep(); return }
        model.pending = .init(title: "Copy \(ops.count) item\(ops.count == 1 ? "" : "s") to \(toward)?", ops: ops, destructive: false)
    }

    private func confirmTrash(_ ids: Set<String>, onLeft: Bool) {
        let ops = model.trashOps(ids, onLeft: onLeft)
        if !ops.isEmpty { model.pending = .init(title: "Move \(ops.count) item\(ops.count == 1 ? "" : "s") to the Trash?", ops: ops, destructive: true) }
    }

    private func describe(_ op: SyncOp) -> String {
        switch op {
        case let .copy(from, to): "\(model.describe(from)) → \(model.describe(to))"
        case let .trash(url): model.describe(url)
        }
    }

    private func sizeText(_ f: FileInfo) -> String { f.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file) }
    private func dateText(_ f: FileInfo) -> String { f.modified.formatted(date: .abbreviated, time: .shortened) }
}

/// Middle column of a row: → copies this item to the right, ← to the left; the symbol between shows the status.
struct CopyArrows: View {
    let entry: FolderEntry
    @ObservedObject var model: FolderCompareModel
    let onCopy: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            arrow(toRight: true)
            Image(systemName: statusSymbol)
                .foregroundStyle(color(entry.status))
                .frame(width: 14)
                .help(statusText(entry.status))
                .accessibilityLabel(statusText(entry.status))
            arrow(toRight: false)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func arrow(toRight: Bool) -> some View {
        let usable = entry.status != .same && !model.copyOps([entry.id], toRight: toRight).isEmpty
        Button { onCopy(toRight) } label: {
            Image(systemName: toRight ? "arrowshape.right.fill" : "arrowshape.left.fill")
                .foregroundStyle(usable ? Color.orange : Color.clear)
        }
        .buttonStyle(.borderless)
        .disabled(!usable)
        .help(toRight ? "Copy \(entry.name) to the right" : "Copy \(entry.name) to the left")
        .accessibilityLabel(toRight ? "Copy \(entry.name) to the right" : "Copy \(entry.name) to the left")
        .accessibilityHidden(!usable)
    }

    private var statusSymbol: String {
        switch entry.status {
        case .same: "equal"
        case .leftNewer, .rightNewer, .differs: "notequal"
        case .leftOnly: "chevron.left"
        case .rightOnly: "chevron.right"
        }
    }
}

/// Scrolling activity log that follows the newest line.
struct LogPane: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i]).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Activity log")
    }
}

func statusText(_ s: EntryStatus) -> String {
    switch s {
    case .same: "Same"
    case .leftNewer: "Left newer"
    case .rightNewer: "Right newer"
    case .differs: "Different"
    case .leftOnly: "Left only"
    case .rightOnly: "Right only"
    }
}

func color(_ s: EntryStatus) -> Color {
    switch s {
    case .same: .primary
    case .leftNewer, .rightNewer, .differs: .red
    case .leftOnly, .rightOnly: .purple
    }
}

/// Preview of every planned operation; nothing touches the disk until Run.
struct SyncSheet: View {
    @ObservedObject var model: FolderCompareModel
    @Environment(\.dismiss) private var dismiss
    private var progress: Double? { model.syncProgress }

    private var ops: [SyncOp] { model.syncPlan() }

    var body: some View {
        let planned = ops
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Folders").font(.headline)
            Picker("Mode", selection: $model.syncMode) {
                Text("Update right: copy new and newer files from left to right").tag(SyncMode.updateRight)
                Text("Update both: copy new and newer files in both directions").tag(SyncMode.updateBoth)
                Text("Mirror to right: make right match left (right-only items move to the Trash)").tag(SyncMode.mirror)
            }
            .pickerStyle(.radioGroup)
            .disabled(progress != nil)
            Text(planned.isEmpty ? "Nothing to do." : "\(planned.count) operation\(planned.count == 1 ? "" : "s"):")
                .foregroundStyle(.secondary)
            List(planned.indices, id: \.self) { i in
                switch planned[i] {
                case let .copy(from, to):
                    Label("Copy \(model.describe(from)) → \(model.describe(to))", systemImage: "doc.on.doc")
                case let .trash(url):
                    Label("Move to Trash: \(model.describe(url))", systemImage: "trash").foregroundStyle(.red)
                }
            }
            if let progress { ProgressView(value: progress) }
            if !model.syncFailures.isEmpty {
                Text(model.syncFailures.map { "Failed: \($0.message)" }.joined(separator: "\n")).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run \(planned.count) Operation\(planned.count == 1 ? "" : "s")") { run(planned) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(planned.isEmpty || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 500)
    }

    private func run(_ planned: [SyncOp]) {
        model.syncProgress = 0
        Task {
            let result = await model.run(planned) { [model] done, total in
                Task { @MainActor in model.syncProgress = Double(done) / Double(max(total, 1)) }
            }
            model.syncFailures = result
            model.syncProgress = nil
            if result.isEmpty { dismiss() }
        }
    }
}
