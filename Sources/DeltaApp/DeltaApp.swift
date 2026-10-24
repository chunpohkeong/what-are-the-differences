import AppKit
import DiffCore
import SwiftUI

@main
struct DeltaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Windows are AppKit-managed (WindowManager); this scene supplies Settings and the menu commands.
        Settings { SettingsView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Text Compare") { WindowManager.shared.open(OpenRequest(kind: .text)) }
                        .keyboardShortcut("n")
                    Button("New Folder Compare") { WindowManager.shared.open(OpenRequest(kind: .folder)) }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("New Text Merge") { WindowManager.shared.open(OpenRequest(kind: .merge)) }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Divider()
                    ForEach([OpenRequest.Kind.hex, .table, .picture, .folderMerge], id: \.self) { kind in
                        Button("New \(kindTitle(kind))") { WindowManager.shared.open(OpenRequest(kind: kind)) }
                    }
                    Button("Compare Clipboard") { WindowManager.shared.openClipboard() }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                    Divider()
                    Button("New Tab") { WindowManager.shared.newTab(duplicate: false) }
                        .keyboardShortcut("t")
                    Button("Duplicate Tab") { WindowManager.shared.newTab(duplicate: true) }
                        .keyboardShortcut("d")
                    Divider()
                    Button("Home") { WindowManager.shared.showHome() }
                        .keyboardShortcut("0", modifiers: [.command, .shift])
                }
                CommandMenu("Compare") {
                    Button("Next Difference") { post(.deltaNextDifference) }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Button("Previous Difference") { post(.deltaPreviousDifference) }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                }
            }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: NSApp.keyWindow)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowManager.shared.installTabMenu()
        WindowManager.shared.showHome()
    }

    /// Clicking the Dock icon with no windows open brings Home back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showHome() }
        return true
    }

    /// `delta://open?...` URLs from the CLI and the Finder extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard var request = OpenRequest(url: url) else { continue }
            // Requests from the sandboxed Finder extension may guess .text without reading the files.
            if request.kind == .text, let kind = OpenRequest.Kind.detect(request.paths) { request.kind = kind }
            WindowManager.shared.open(request)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.finishAll()
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Command line") {
                Text("Install the `delta` command once:")
                Text("ln -s \"\(Bundle.main.bundlePath)/Contents/MacOS/delta\" /usr/local/bin/delta")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Finder") {
                Text("Turn on the Delta extension in System Settings › General › Login Items & Extensions to compare from Finder's right-click menu.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

/// Session picker: recent sessions on the left (searchable), session tiles on the right that accept dropped items.
struct HomeView: View {
    @ObservedObject private var store = SessionStore.shared
    @State private var search = ""
    @State private var selection: OpenRequest?

    private var filtered: [OpenRequest] {
        search.isEmpty ? store.recent : store.recent.filter {
            $0.paths.joined(separator: " ").localizedCaseInsensitiveContains(search) || kindTitle($0.kind).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Recent Sessions") {
                    ForEach(filtered, id: \.self) { r in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).lineLimit(1)
                                Text(kindTitle(r.kind)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: kindIcon(r.kind)) }
                            .tag(r)
                            .help(r.paths.joined(separator: "\n"))
                    }
                }
            }
            .contextMenu(forSelectionType: OpenRequest.self) { items in
                Button("Open") { items.forEach { WindowManager.shared.open($0) } }
                Button("Remove from List") { items.forEach(store.remove) }
            } primaryAction: { items in
                items.forEach { WindowManager.shared.open($0) }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search sessions")
            .overlay {
                if store.recent.isEmpty {
                    ContentUnavailableView("No Sessions Yet", systemImage: "clock", description: Text("Sessions you open appear here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("Drop files or folders onto a session, or click one to begin.").font(.title3)
                    Text("Drop two items to compare them straight away. Double-click a recent session to reopen it.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 16)], spacing: 16) {
                    ForEach([OpenRequest.Kind.folder, .folderMerge, .text, .merge, .hex, .table, .picture], id: \.self) { kind in
                        SessionTile(title: kindTitle(kind), icon: kindIcon(kind), kind: kind)
                    }
                    SessionTile(title: "Clipboard", icon: "doc.on.clipboard", kind: nil)
                }
                .frame(maxWidth: 720)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// Click to start an empty session; drop 1–3 items to start it with them. `kind == nil` is the clipboard compare.
struct SessionTile: View {
    let title: String
    let icon: String
    let kind: OpenRequest.Kind?
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Button {
            if let kind { WindowManager.shared.open(OpenRequest(kind: kind)) } else { WindowManager.shared.openClipboard() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tint).frame(height: 42)
                Text(title)
            }
            .frame(width: 140, height: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: targeted ? 2 : 1))
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard let kind else { return false }
            WindowManager.shared.open(OpenRequest(kind: kind, paths: urls.prefix(3).map(\.path)))
            return true
        } isTargeted: { targeted = $0 }
        .help(kind == nil ? "Compare text on the clipboard" : "Click to start, or drop files here")
        .accessibilityLabel(title)
    }
}

func kindTitle(_ kind: OpenRequest.Kind) -> String {
    switch kind {
    case .text: "Text Compare"
    case .folder: "Folder Compare"
    case .merge: "Text Merge"
    case .hex: "Hex Compare"
    case .table: "Table Compare"
    case .picture: "Picture Compare"
    case .folderMerge: "Folder Merge"
    }
}
