import AppKit
import DiffCore
import SwiftUI

/// Opens one AppKit window per session and signals `delta --wait` when it closes.
@MainActor final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private struct Session {
        let window: NSWindow
        let request: OpenRequest
        let hasUnsavedChanges: () -> Bool
        /// The session's kind and the paths it shows right now (for Duplicate Tab).
        let current: () -> OpenRequest
    }

    private var sessions: [ObjectIdentifier: Session] = [:]

    /// Opens a session window and returns its model.
    @discardableResult
    func open(_ request: OpenRequest, tabbedWith tabHost: NSWindow? = nil) -> AnyObject {
        let window = SessionWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 400)
        let urls = request.paths.map { URL(fileURLWithPath: $0) }
        let names = urls.map(\.lastPathComponent)
        let pair = names.count >= 2 ? "\(names[0]) ↔ \(names[1])" : nil
        let model: AnyObject
        var unsaved: () -> Bool = { false }
        var current: () -> OpenRequest = { OpenRequest(kind: request.kind, paths: request.paths, output: request.output) }
        func paths(_ urls: [URL?]) -> [String] { urls.compactMap { $0?.path } }

        switch request.kind {
        case .text:
            let m = TextCompareModel()
            m.window = window
            for (url, side) in zip(urls, [TextCompareModel.Side.left, .right]) { m.load(url, side: side) }
            host(window, TextCompareView(model: m))
            window.title = pair ?? "Text Compare"
            unsaved = { !m.dirty.isEmpty }
            current = { OpenRequest(kind: .text, paths: paths([m.urls[.left], m.urls[.right]])) }
            model = m
        case .folder:
            let m = FolderCompareModel()
            m.window = window
            m.leftURL = urls.first
            m.rightURL = urls.dropFirst().first
            m.refresh()
            host(window, FolderCompareView(model: m))
            window.title = pair ?? "Folder Compare"
            current = { OpenRequest(kind: .folder, paths: paths([m.leftURL, m.rightURL])) }
            model = m
        case .merge:
            let m = TextMergeModel()
            m.window = window
            for (url, role) in zip(urls, [TextMergeModel.Role.left, .right, .base]) { m.load(url, role: role) }
            m.outputURL = request.output.map { URL(fileURLWithPath: $0) }
            host(window, TextMergeView(model: m))
            window.title = request.output.map { "Merge → \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Text Merge"
            unsaved = { m.dirty }
            current = { OpenRequest(kind: .merge, paths: paths([m.urls[.left], m.urls[.right], m.urls[.base]]), output: m.outputURL?.path) }
            model = m
        case .hex:
            let m = HexCompareModel()
            m.window = window
            for (url, side) in zip(urls, [TextCompareModel.Side.left, .right]) { m.load(url, side: side) }
            host(window, HexCompareView(model: m))
            window.title = pair ?? "Hex Compare"
            current = { OpenRequest(kind: .hex, paths: paths([m.urls[.left], m.urls[.right]])) }
            model = m
        case .table:
            let m = TableCompareModel()
            m.window = window
            for (url, side) in zip(urls, [TextCompareModel.Side.left, .right]) { m.load(url, side: side) }
            host(window, TableCompareView(model: m))
            window.title = pair ?? "Table Compare"
            current = { OpenRequest(kind: .table, paths: paths([m.urls[.left], m.urls[.right]])) }
            model = m
        case .picture:
            let m = PictureCompareModel()
            m.window = window
            for (url, side) in zip(urls, [TextCompareModel.Side.left, .right]) { m.load(url, side: side) }
            host(window, PictureCompareView(model: m))
            window.title = pair ?? "Picture Compare"
            current = { OpenRequest(kind: .picture, paths: paths([m.urls[.left], m.urls[.right]])) }
            model = m
        case .folderMerge:
            let m = FolderMergeModel()
            m.window = window
            for (url, role) in zip(urls, [TextMergeModel.Role.left, .right, .base]) { m.urls[role] = url }
            m.refresh()
            m.outputURL = request.output.map { URL(fileURLWithPath: $0) }
            host(window, FolderMergeView(model: m))
            window.title = request.output.map { "Folder Merge → \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Folder Merge"
            current = { OpenRequest(kind: .folderMerge, paths: paths([m.urls[.left], m.urls[.right], m.urls[.base]]), output: m.outputURL?.path) }
            model = m
        }

        // Sessions open as tabs of one window (Window › Merge All Windows / drag a tab out to separate).
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "DeltaSession"
        window.delegate = self
        sessions[ObjectIdentifier(window)] = Session(window: window, request: request, hasUnsavedChanges: unsaved, current: current)
        tabHost?.addTabbedWindow(window, ordered: .above)
        show(window)
        // Keep the tab bar visible even with one tab, so tabs can be right-clicked and the + button is there.
        DispatchQueue.main.async {
            if let group = window.tabGroup, !group.isTabBarVisible { window.toggleTabBar(nil) }
        }
        if request.paths.count >= 2 { SessionStore.shared.add(request) }
        if let dir = ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_DIR"] { snapshot(window, name: request.kind.rawValue, to: dir, model: model) }
        return model
    }

    /// Text Compare with the clipboard's text on the left.
    /// A new Text Compare tab with given text on each side (e.g. a selection against the clipboard).
    func openTexts(left: String, leftLabel: String, right: String, rightLabel: String, tabbedWith host: NSWindow?) {
        guard let model = open(OpenRequest(kind: .text), tabbedWith: host) as? TextCompareModel else { return }
        model.setText(left, side: .left, label: leftLabel)
        model.setText(right, side: .right, label: rightLabel)
    }

    func openClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        (open(OpenRequest(kind: .text)) as? TextCompareModel)?.setText(text, side: .left, label: "Clipboard")
    }

    /// Test hook: renders the window's own view to `<dir>/<kind>-<n>.png` once it has loaded,
    /// and closes it when DELTA_SNAPSHOT_CLOSE is set (exercises `delta --wait`). Needs no screen-recording permission.
    /// DELTA_SNAPSHOT_ACTION=context switches Text Compare to the Context view; =copy-right copies the first text difference left → right and saves a second "-after" image.
    private func snapshot(_ window: NSWindow, name: String, to dir: String, model: AnyObject? = nil) {
        let delay = Double(ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The frame view includes the toolbar; fall back to the content view.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appending(path: "\(name)-\(self.sessions.count).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            // DELTA_SNAPSHOT_ACTION=droptest drops DELTA_DROP_PATHS (colon-separated) at DELTA_DROP_POINT ("x,y" in window points).
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_ACTION"] == "droptest", name != "home", !name.hasSuffix("-dropped"), !self.didTestDrop {
                self.didTestDrop = true
                let env = ProcessInfo.processInfo.environment
                let urls = (env["DELTA_DROP_PATHS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                let xy = (env["DELTA_DROP_POINT"] ?? "300,300").split(separator: ",").compactMap { Double($0) }
                // DELTA_DROP_EMPTY=1 drops on a fresh, empty tab of the same kind instead.
                if env["DELTA_DROP_EMPTY"] != nil { self.open(OpenRequest(kind: OpenRequest.Kind(rawValue: name) ?? .text), tabbedWith: window) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let target = NSApp.keyWindow ?? window
                    let result = simulateDrop(urls, at: NSPoint(x: xy[0], y: xy[1]), in: target) + " window=\(target.title)"
                    try? result.write(toFile: dir + "/drop.txt", atomically: true, encoding: .utf8)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.snapshot(target, name: name + "-dropped", to: dir) }
                }
                return
            }
            // DELTA_SNAPSHOT_ACTION=menu right-clicks line 15 of the left text pane, lists the menu, then runs two of its items.
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_ACTION"] == "menu", name == "text" {
                var panes: [DiffTextView] = []
                func find(_ v: NSView) { if let t = v as? DiffTextView { panes.append(t) }; v.subviews.forEach(find) }
                window.contentView.map(find)
                guard let left = panes.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else { return }
                let point = left.convert(NSPoint(x: 20, y: left.lineTop(line: 14) + 4), to: nil)
                guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let menu = left.menu(for: event) else { return }
                let listing = menu.items.map { $0.isSeparatorItem ? "—" : "\($0.title)\($0.isEnabled ? "" : " (disabled)")\($0.submenu.map { " ▸ \($0.items.count) apps" } ?? "")" }
                try? listing.joined(separator: "\n").write(toFile: dir + "/menu.txt", atomically: true, encoding: .utf8)
                for title in ["Copy Line to Right", "Increase Indent"] {
                    if let item = menu.items.first(where: { $0.title == title }), let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.snapshot(window, name: name + "-menu", to: dir) }
                return
            }
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_ACTION"] == "duplicate", name == "folder", !self.didTestDuplicate {
                self.didTestDuplicate = true
                self.newTab(from: window, duplicate: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let tab = NSApp.keyWindow else { return }
                    var info = "frame=\(tab.frame) contentTop=\(tab.contentLayoutRect.maxY) tabs=\(tab.tabbedWindows?.count ?? 1) barVisible=\(tab.tabGroup?.isTabBarVisible ?? false)\n"
                    func dump(_ v: NSView) {
                        let name = String(describing: type(of: v))
                        if name.hasPrefix("NSTab") { info += "\(name) \(v.convert(v.bounds, to: nil))\n" }
                        v.subviews.forEach(dump)
                    }
                    tab.contentView?.superview.map(dump)
                    try? info.write(toFile: dir + "/tabs.txt", atomically: true, encoding: .utf8)
                    self.snapshot(tab, name: name + "-dup", to: dir)
                }
                return
            }
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_ACTION"] == "context", let text = model as? TextCompareModel {
                text.viewMode = .context
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.snapshot(window, name: name + "-context", to: dir) }
                return
            }
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_ACTION"] == "copy-right", let text = model as? TextCompareModel {
                text.jump(to: 0)
                text.requestCopy(fromLeft: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.snapshot(window, name: name + "-after", to: dir) }
                return
            }
            if ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_CLOSE"] != nil { window.performClose(nil) }
        }
    }

    private var home: NSWindow?
    private var tabMenuMonitor: Any?
    private var didTestDuplicate = false
    private var didTestDrop = false

    /// ⌘T / the tab bar's +: an empty session of the same kind. Duplicate: same kind and the same files or folders.
    func newTab(from window: NSWindow? = NSApp.keyWindow, duplicate: Bool) {
        let source = window.flatMap { sessions[ObjectIdentifier($0)] }
        guard let source else {
            open(OpenRequest(kind: .folder))
            return
        }
        open(duplicate ? source.current() : OpenRequest(kind: source.request.kind), tabbedWith: source.window)
    }

    /// macOS has no API to add items to a tab's context menu, so right-clicks on the tab bar get Delta's own menu.
    func installTabMenu() {
        guard tabMenuMonitor == nil else { return }
        tabMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated {
                guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      let window = event.window, self.sessions[ObjectIdentifier(window)] != nil,
                      window.tabGroup?.isTabBarVisible == true else { return event }
                // The tab bar sits just above the content area.
                let top = window.contentLayoutRect.maxY, p = event.locationInWindow
                guard p.y >= top, p.y <= top + 32 else { return event }
                let tabs = window.tabbedWindows ?? [window]
                guard let index = self.tabIndex(at: p, in: window, count: tabs.count) else { return event }
                self.showTabMenu(for: tabs[index], among: tabs, event: event)
                return nil
            }
        }
    }

    /// Which tab is under a point in the tab bar; nil over the + button.
    private func tabIndex(at point: NSPoint, in window: NSWindow, count: Int) -> Int? {
        let frameView = window.contentView?.superview
        var hit = frameView?.hitTest(frameView?.convert(point, from: nil) ?? point)
        while let view = hit {
            let name = String(describing: type(of: view))
            if name == "NSTabBarNewTabButton" { return nil }
            if name == "NSTabButton", let siblings = view.superview?.subviews.filter({ String(describing: type(of: $0)) == "NSTabButton" }) {
                let ordered = siblings.sorted { $0.frame.minX < $1.frame.minX }
                if let i = ordered.firstIndex(where: { $0 === view }), i < count { return i }
            }
            hit = view.superview
        }
        // Fallback if AppKit's private tab views change: tabs share the width left of the + button.
        return min(count - 1, max(0, Int(point.x / ((window.frame.width - 28) / CGFloat(count)))))
    }

    private func showTabMenu(for tab: NSWindow, among tabs: [NSWindow], event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("New Tab") { self.newTab(from: tab, duplicate: false) })
        menu.addItem(ActionMenuItem("Duplicate Tab") { self.newTab(from: tab, duplicate: true) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move Tab to New Window", enabled: tabs.count > 1) { tab.moveTabToNewWindow(nil) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Close Tab") { tab.performClose(nil) })
        menu.addItem(ActionMenuItem("Close Other Tabs", enabled: tabs.count > 1) { tabs.filter { $0 !== tab }.forEach { $0.performClose(nil) } })
        if let view = event.window?.contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    /// The Home window (session picker); created on first use, reused after closing.
    func showHome() {
        if home == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Delta"
            window.tabbingMode = .disallowed
            host(window, HomeView())
            home = window
        }
        home.map { show($0, labels: false) }
        if let dir = ProcessInfo.processInfo.environment["DELTA_SNAPSHOT_DIR"], let home { snapshot(home, name: "home", to: dir) }
    }

    /// Hosts SwiftUI in a controller so each view's `.toolbar` becomes the window's native toolbar.
    private func host<V: View>(_ window: NSWindow, _ view: V) {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.toolbars]
        controller.sizingOptions = []
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: false)
    }

    private func show(_ window: NSWindow, labels: Bool = true) {
        window.toolbarStyle = .expanded
        if window.frameAutosaveName.isEmpty { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The bridged toolbar exists once the window is on screen; labels under icons are easier to scan.
        DispatchQueue.main.async { window.toolbar?.displayMode = labels ? .iconAndLabel : .iconOnly }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = sessions[ObjectIdentifier(sender)], session.hasUnsavedChanges() else { return true }
        return confirmDiscard(message: "Close without saving?")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let session = sessions.removeValue(forKey: ObjectIdentifier(window)) else { return }
        signalDone(session.request)
    }

    func confirmQuit() -> Bool {
        sessions.values.contains { $0.hasUnsavedChanges() } ? confirmDiscard(message: "Quit without saving?") : true
    }

    func finishAll() { sessions.values.forEach { signalDone($0.request) } }

    private func signalDone(_ request: OpenRequest) {
        if let marker = request.waitMarker { FileManager.default.createFile(atPath: marker, contents: nil) }
    }

    private func confirmDiscard(message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = "Unsaved edits will be lost."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Recently opened sessions, kept in Application Support.
@MainActor final class SessionStore: ObservableObject {
    static let shared = SessionStore()
    @Published private(set) var recent: [OpenRequest] = []
    private let file = URL.applicationSupportDirectory.appending(path: "Delta/recent.json")

    init() {
        recent = (try? JSONDecoder().decode([OpenRequest].self, from: Data(contentsOf: file))) ?? []
    }

    func add(_ request: OpenRequest) {
        var r = request
        r.waitMarker = nil
        r.output = nil
        recent.removeAll { $0 == r }
        recent.insert(r, at: 0)
        recent = Array(recent.prefix(30))
        save()
    }

    func remove(_ request: OpenRequest) {
        recent.removeAll { $0 == request }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(recent).write(to: file, options: .atomic)
    }
}

/// Session windows answer the tab bar's + button.
final class SessionWindow: NSWindow {
    override func newWindowForTab(_ sender: Any?) {
        WindowManager.shared.newTab(from: self, duplicate: false)
    }
}

/// Menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
