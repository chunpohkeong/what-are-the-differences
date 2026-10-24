import AppKit
import DiffCore
import SwiftUI

extension Notification.Name {
    static let deltaNextDifference = Notification.Name("DeltaNextDifference")
    static let deltaPreviousDifference = Notification.Name("DeltaPreviousDifference")
}

/// Semantic system colors with alpha, so they adapt to light and dark mode.
enum DiffColors {
    static let changed = NSColor.systemOrange.withAlphaComponent(0.18)
    static let changedInline = NSColor.systemOrange.withAlphaComponent(0.45)
    static let inserted = NSColor.systemGreen.withAlphaComponent(0.2)
    static let deleted = NSColor.systemRed.withAlphaComponent(0.18)
    static let insertMarker = NSColor.systemGreen.withAlphaComponent(0.9)
    static let deleteMarker = NSColor.systemRed.withAlphaComponent(0.9)
    static let conflict = NSColor.systemRed.withAlphaComponent(0.22)
    static let merged = NSColor.systemGreen.withAlphaComponent(0.16)
}

@MainActor func choosePath(directories: Bool, files: Bool? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = files ?? !directories
    panel.canChooseDirectories = directories
    panel.canCreateDirectories = directories
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

/// Recently used paths, offered from each path field's history menu.
enum PathHistory {
    private static func key(_ folders: Bool) -> String { folders ? "history.folders" : "history.files" }

    static func list(folders: Bool) -> [String] { UserDefaults.standard.stringArray(forKey: key(folders)) ?? [] }

    static func add(_ url: URL, folders: Bool) {
        let items = [url.path] + list(folders: folders).filter { $0 != url.path }
        UserDefaults.standard.set(Array(items.prefix(15)), forKey: key(folders))
    }
}

/// Path field for one side: type or paste a path and press Return, pick a recent one, go up a level, browse, or drop.
struct PathBar: View {
    let title: String
    let url: URL?
    var directories = false
    /// Folder pickers that also accept archives and snapshots.
    var allowFiles = false
    /// Shown instead of a path when the side has content but no file (clipboard, patch result).
    var label: String?
    var edited = false
    var onChoose: (URL) -> Void
    var onSave: (() -> Void)?

    @State private var text = ""
    @State private var invalid = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(label ?? "\(title): type a \(directories ? "folder" : "file") path, or drop one here", text: $text)
                .textFieldStyle(.roundedBorder)
                .truncationMode(.head) // keep the file or folder name visible in long paths
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(invalid ? Color.red : targeted ? Color.accentColor : .clear, lineWidth: 2))
                .onSubmit(commit)
                .help(invalid ? "No such \(directories ? "folder" : "file")" : "Press Return to load")
                .accessibilityLabel("\(title) path")
            if edited {
                Circle().fill(.orange).frame(width: 7, height: 7).help("Unsaved edits").accessibilityLabel("Unsaved edits")
            }
            Menu {
                let recent = PathHistory.list(folders: directories)
                if recent.isEmpty { Text("No recent \(directories ? "folders" : "files")") }
                ForEach(recent, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) { choose(URL(fileURLWithPath: path)) }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent \(directories ? "folders" : "files")")
                .accessibilityLabel("Recent \(directories ? "folders" : "files") for \(title.lowercased())")
            if directories {
                Button { url.map { choose($0.deletingLastPathComponent()) } } label: { Image(systemName: "arrow.turn.left.up") }
                    .disabled(url == nil)
                    .help("Up one level")
                    .accessibilityLabel("Up one level")
            }
            Button { if let u = choosePath(directories: directories, files: allowFiles ? true : nil) { choose(u) } } label: {
                Image(systemName: directories ? "folder" : "doc")
            }
            .help("Browse…")
            .accessibilityLabel("Browse for \(title.lowercased()) \(directories ? "folder" : "file")")
            if let onSave {
                Button(action: onSave) { Image(systemName: "square.and.arrow.down") }
                    .disabled(!edited)
                    .help("Save \(title.lowercased()) (keeps its encoding and line endings)")
                    .accessibilityLabel("Save \(title.lowercased())")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear { text = url?.path(percentEncoded: false) ?? "" }
        .onChange(of: url) { _, new in
            text = new?.path(percentEncoded: false) ?? ""
            invalid = false
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            choose(u)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose(_ u: URL) {
        PathHistory.add(u, folders: directories)
        onChoose(u)
    }

    private func commit() {
        let path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            invalid = true
            NSSound.beep()
            return
        }
        invalid = false
        choose(URL(fileURLWithPath: path))
    }
}

/// One-line footer: left pane info, overall summary, right pane info.
struct StatusBar: View {
    var left = ""
    var center = ""
    var right = ""

    var body: some View {
        HStack {
            Text(left).frame(maxWidth: .infinity, alignment: .leading)
            Text(center).frame(maxWidth: .infinity)
            Text(right).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }
}

/// Leading toolbar items shared by every session window.
struct SessionToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { WindowManager.shared.showHome() } label: { Label("Home", systemImage: "house") }
                .help("Show the Home window")
            SessionsMenu()
        }
    }
}

struct SessionsMenu: View {
    @ObservedObject private var store = SessionStore.shared

    var body: some View {
        Menu {
            Section("New") {
                ForEach(OpenRequest.Kind.allCases, id: \.self) { kind in
                    Button(kindTitle(kind)) { WindowManager.shared.open(OpenRequest(kind: kind)) }
                }
                Button("Clipboard Compare") { WindowManager.shared.openClipboard() }
            }
            Section("Tabs") {
                Button("New Tab  ⌘T") { WindowManager.shared.newTab(duplicate: false) }
                Button("Duplicate Tab  ⌘D") { WindowManager.shared.newTab(duplicate: true) }
            }
            Section("Recent") {
                ForEach(store.recent.prefix(12), id: \.self) { r in
                    Button("\(r.title) — \(kindTitle(r.kind))") { WindowManager.shared.open(r) }
                }
            }
        } label: { Label("Sessions", systemImage: "rectangle.stack") }
            .help("Start a new session or reopen a recent one")
    }
}

extension OpenRequest {
    /// "a.txt ↔ b.txt" for lists and menus.
    var title: String { paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " ↔ ") }
}

func kindIcon(_ kind: OpenRequest.Kind) -> String {
    switch kind {
    case .text: "doc.text"
    case .folder: "folder"
    case .merge: "arrow.triangle.merge"
    case .hex: "number"
    case .table: "tablecells"
    case .picture: "photo.on.rectangle"
    case .folderMerge: "folder.badge.gearshape"
    }
}
