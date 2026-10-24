import AppKit
import DiffCore
import SwiftUI

@MainActor final class FolderMergeModel: ObservableObject {
    typealias Role = TextMergeModel.Role

    @Published var urls: [Role: URL] = [:]
    @Published var outputURL: URL?
    @Published private(set) var items: [FolderMergeItem] = []
    @Published var selection = Set<String>()
    @Published private(set) var isBusy = false
    @Published var confirmWrite = false
    @Published var errorMessage: String?
    weak var window: NSWindow?
    private let fileOps = FileOperations()

    /// Conflicts handed to a text merge window, which writes the output file itself.
    @Published private(set) var textMerged = Set<String>()

    var conflicts: Int { items.filter { $0.action == .conflict && !textMerged.contains($0.id) }.count }

    func set(_ url: URL, _ role: Role) {
        urls[role] = url
        refresh()
    }

    func refresh() {
        guard let b = urls[.base], let l = urls[.left], let r = urls[.right] else { return }
        isBusy = true
        Task {
            do {
                items = try await Task.detached(priority: .userInitiated) { try planFolderMerge(base: b, left: l, right: r) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    func setAction(_ ids: Set<String>, _ action: FolderMergeItem.Action) {
        for i in items.indices where ids.contains(items[i].id) {
            // Taking a side that has no file means removing it from the output.
            let path = items[i].relativePath
            let exists = FileManager.default.fileExists(atPath: (action == .takeLeft ? urls[.left] : urls[.right])?.appending(path: path).path ?? "")
            items[i].action = exists ? action : .delete
            textMerged.remove(items[i].id)
        }
    }

    /// Opens a 3-way text merge for one conflicting file, saving into the output folder.
    func mergeText(_ id: String) {
        guard let l = urls[.left], let r = urls[.right], let b = urls[.base] else { return }
        guard let out = outputURL ?? choosePath(directories: true) else { return }
        outputURL = out
        let fm = FileManager.default
        let left = l.appending(path: id), right = r.appending(path: id), base = b.appending(path: id), target = out.appending(path: id)
        guard fm.fileExists(atPath: left.path), fm.fileExists(atPath: right.path) else {
            errorMessage = "Text merge needs the file on both sides; use Take Left or Take Right."
            return
        }
        do { try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            errorMessage = error.localizedDescription
            return
        }
        WindowManager.shared.open(OpenRequest(kind: .merge, paths: [left.path, right.path] + (fm.fileExists(atPath: base.path) ? [base.path] : []),
                                              output: target.path))
        // The text merge writes the file itself, so the folder write must not overwrite it.
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].action = .conflict }
        textMerged.insert(id)
    }

    var writeOps: [SyncOp] {
        guard let l = urls[.left], let r = urls[.right], let out = outputURL else { return [] }
        return folderMergeOps(items, left: l, right: r, output: out)
    }

    func write() {
        let ops = writeOps
        Task {
            let failures = await fileOps.run(ops)
            if !failures.isEmpty { errorMessage = failures.map(\.message).joined(separator: "\n") }
        }
    }
}

struct FolderMergeView: View {
    @ObservedObject var model: FolderMergeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(TextMergeModel.Role.allCases) { role in
                    PathBar(title: role.rawValue, url: model.urls[role], directories: true) { model.set($0, role) }
                }
            }
            PathBar(title: "Output", url: model.outputURL, directories: true) { model.outputURL = $0 }
            Divider()
            Table(model.items, selection: $model.selection) {
                TableColumn("File") { (i: FolderMergeItem) in
                    Text(i.relativePath).foregroundStyle(i.action == .conflict && !model.textMerged.contains(i.id) ? .red : .primary)
                }
                TableColumn("Left") { (i: FolderMergeItem) in Text(i.left.rawValue) }.width(90)
                TableColumn("Right") { (i: FolderMergeItem) in Text(i.right.rawValue) }.width(90)
                TableColumn("Result") { (i: FolderMergeItem) in
                    let merged = model.textMerged.contains(i.id)
                    Text(merged ? "Text merge" : actionText(i.action)).foregroundStyle(i.action == .conflict && !merged ? .red : .primary)
                }.width(110)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Take Left") { model.setAction(ids, .takeLeft) }
                Button("Take Right") { model.setAction(ids, .takeRight) }
                Button("Merge Text…") { ids.first.map(model.mergeText) }.disabled(ids.count != 1)
            } primaryAction: { ids in
                if ids.count == 1 { ids.first.map(model.mergeText) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(left: model.isBusy ? "Comparing…" : "",
                      center: model.items.isEmpty ? "Choose left, base, right and an output folder"
                          : "\(model.items.count) files · \(model.conflicts) unresolved conflict\(model.conflicts == 1 ? "" : "s")",
                      right: model.outputURL == nil ? "No output folder yet" : "")
        }
        .frame(minWidth: 800, minHeight: 400)
        .toolbar {
            SessionToolbar()
            ToolbarItemGroup {
                Button { model.setAction(model.selection, .takeLeft) } label: { Label("Take Left", systemImage: "arrow.left.square") }
                    .disabled(model.selection.isEmpty).help("Use the left version of the selected files")
                Button { model.setAction(model.selection, .takeRight) } label: { Label("Take Right", systemImage: "arrow.right.square") }
                    .disabled(model.selection.isEmpty).help("Use the right version of the selected files")
                Button { model.selection.first.map(model.mergeText) } label: { Label("Merge Text", systemImage: "arrow.triangle.merge") }
                    .disabled(model.selection.count != 1).help("Open a 3-way text merge for the selected file")
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").help("Compare again (⌘R)")
                Button { model.confirmWrite = true } label: { Label("Write Output", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(model.items.isEmpty || model.outputURL == nil).help("Copy every resolved file into the output folder")
            }
        }
        .confirmationDialog("Write \(model.writeOps.count) file\(model.writeOps.count == 1 ? "" : "s") to the output folder?", isPresented: $model.confirmWrite) {
            Button("Write") { model.write() }
        } message: {
            Text((model.conflicts > 0 ? "\(model.conflicts) unresolved conflict(s) will not be written. " : "")
                + "Existing files in the output folder move to the Trash before being replaced.")
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: { _ in }))
    }

    private func actionText(_ a: FolderMergeItem.Action) -> String {
        switch a { case .takeLeft: "Left"; case .takeRight: "Right"; case .delete: "Removed"; case .conflict: "Conflict" }
    }
}
