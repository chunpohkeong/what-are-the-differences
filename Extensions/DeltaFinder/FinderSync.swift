import Cocoa
import FinderSync

/// Finder context menu: pick a left side, then compare another item with it, or compare two selected items.
final class FinderSync: FIFinderSync {
    private let leftKey = "leftPath"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    private var selected: [URL] { FIFinderSyncController.default().selectedItemURLs() ?? [] }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "Delta")
        switch selected.count {
        case 1:
            menu.addItem(withTitle: "Select Left Side for Delta", action: #selector(selectLeft(_:)), keyEquivalent: "")
            if let left = UserDefaults.standard.string(forKey: leftKey), left != selected.first?.path {
                menu.addItem(withTitle: "Compare to “\((left as NSString).lastPathComponent)” with Delta", action: #selector(compareToLeft(_:)), keyEquivalent: "")
            }
        case 2:
            menu.addItem(withTitle: "Compare with Delta", action: #selector(comparePair(_:)), keyEquivalent: "")
        default:
            return nil
        }
        return menu
    }

    @objc func selectLeft(_ sender: AnyObject?) {
        if let url = selected.first { UserDefaults.standard.set(url.path, forKey: leftKey) }
    }

    @objc func compareToLeft(_ sender: AnyObject?) {
        guard let left = UserDefaults.standard.string(forKey: leftKey), let right = selected.first else { return }
        open([left, right.path])
    }

    @objc func comparePair(_ sender: AnyObject?) { open(selected.map(\.path)) }

    /// The sandbox may hide file contents from this extension, so the app re-checks the kind when it receives the request.
    private func open(_ paths: [String]) {
        NSWorkspace.shared.open(OpenRequest(kind: OpenRequest.Kind.detect(paths) ?? .text, paths: paths).url)
    }
}
