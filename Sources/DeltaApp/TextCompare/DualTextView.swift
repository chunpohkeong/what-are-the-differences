import AppKit
import DiffCore
import SwiftUI

/// Two text panes with diff highlights and scroll positions kept aligned through the diff.
struct DualTextView: NSViewRepresentable {
    @ObservedObject var model: TextCompareModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSStackView {
        let c = context.coordinator
        let (ls, lt) = makeTextPane(editable: true, label: "Left text")
        let (rs, rt) = makeTextPane(editable: true, label: "Right text")
        lt.delegate = c
        rt.delegate = c
        rt.copiesToRight = false
        lt.onCopyMarker = { [weak c] hunk in c?.copy(hunk: hunk, fromLeft: true) }
        rt.onCopyMarker = { [weak c] hunk in c?.copy(hunk: hunk, fromLeft: false) }
        lt.contextMenuProvider = { [weak c] event in c?.contextMenu(side: .left, event: event) }
        rt.contextMenuProvider = { [weak c] event in c?.contextMenu(side: .right, event: event) }
        lt.onDropFiles = { [weak c] urls in c?.model.dropped(urls, on: .left) }
        rt.onDropFiles = { [weak c] urls in c?.model.dropped(urls, on: .right) }
        c.left = lt
        c.right = rt
        for (scroll, side) in [(ls, TextCompareModel.Side.left), (rs, .right)] {
            // queue nil: run synchronously so the `syncing` guard sees our own programmatic scrolls.
            c.observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak c] _ in
                MainActor.assumeIsolated { c?.scrolled(side) }
            })
        }
        let stack = NSStackView(views: [ls, rs])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) { context.coordinator.update() }

    static func dismantleNSView(_ nsView: NSStackView, coordinator: Coordinator) {
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TextCompareModel
        weak var left: DiffTextView?
        weak var right: DiffTextView?
        var observers: [NSObjectProtocol] = []
        private var loadToken = -1
        private var scrollToken = 0
        private var copyToken = 0
        private var displayToken = -1
        private var fontSize: CGFloat = 12
        private var applied: [DiffHunk]?
        private var syncing = false

        init(model: TextCompareModel) { self.model = model }

        func update() {
            guard let left, let right else { return }
            if fontSize != model.fontSize {
                fontSize = model.fontSize
                for tv in [left, right] { tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
            }
            if loadToken != model.loadToken {
                loadToken = model.loadToken
                if model.display == nil { showTexts() }
                applied = nil
            }
            if displayToken != model.displayToken {
                displayToken = model.displayToken
                if let d = model.display {
                    for (tv, text, numbers) in [(left, d.left, d.leftNumbers), (right, d.right, d.rightNumbers)] {
                        tv.isEditable = false
                        tv.string = text
                        tv.lineStarts = lineStartOffsets(text)
                        tv.lineNumbers = numbers
                    }
                    applied = d.hunks
                    applyHighlights(markers: false)
                } else {
                    showTexts()
                    applied = nil
                }
            }
            if model.display == nil, applied != model.hunks {
                applied = model.hunks
                applyHighlights(markers: true)
            }
            if copyToken != model.copyToken {
                copyToken = model.copyToken
                if let request = model.copyRequest { copy(hunk: request.hunk, fromLeft: request.fromLeft) }
            }
            if scrollToken != model.scrollToken {
                scrollToken = model.scrollToken
                syncing = true
                left.scrollToLine(max(0, shown(model.scrollTarget.left, in: left) - 3))
                right.scrollToLine(max(0, shown(model.scrollTarget.right, in: right) - 3))
                syncing = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? DiffTextView else { return }
            tv.lineStarts = lineStartOffsets(tv.string)
            model.edited(tv.string, side: tv === left ? .left : .right)
        }

        /// Puts the full, editable texts back (leaving a filtered view, or after a load).
        private func showTexts() {
            guard let left, let right else { return }
            for (tv, side) in [(left, TextCompareModel.Side.left), (right, .right)] {
                tv.lineNumbers = nil
                tv.isEditable = true
                tv.string = model.texts[side] ?? ""
                tv.lineStarts = lineStartOffsets(tv.string)
                // Undo steps refer to text that was just replaced, so they cannot be replayed safely.
                tv.undoManager?.removeAllActions(withTarget: tv)
                tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
            }
        }

        /// Shown line for an original line number (identity unless a filtered view is on).
        private func shown(_ original: Int, in tv: DiffTextView) -> Int {
            tv.lineNumbers.flatMap { $0.firstIndex(of: original) } ?? (tv.lineNumbers == nil ? original : 0)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? DiffTextView else { return }
            let side: TextCompareModel.Side = tv === left ? .left : .right
            let shownLine = tv.lineIndex(containing: tv.selectedRange().location)
            guard let line = tv.lineNumbers.map({ shownLine < $0.count ? $0[shownLine] : nil }) ?? shownLine else { return }
            // Deferred: selection also changes while SwiftUI is updating the view.
            DispatchQueue.main.async { [model] in model.setCursor(side: side, line: line) }
        }

        // MARK: Right-click menu

        func contextMenu(side: TextCompareModel.Side, event: NSEvent) -> NSMenu? {
            guard let tv = side == .left ? left : right else { return nil }
            let clicked = tv.line(atWindowPoint: event.locationInWindow)
            // Right-click inside a selection acts on it; elsewhere on the clicked line (a right-click does not move the caret).
            let clickedChar = tv.characterIndexForInsertion(at: tv.convert(event.locationInWindow, from: nil))
            let selected = tv.selectedRange()
            let indentRange = selected.length > 0 && NSLocationInRange(clickedChar, selected) ? selected : tv.charRange(lines: clicked..<(clicked + 1))
            // In a filtered view, map the shown line back to its original number ("⋯" gaps have none).
            let original: Int? = tv.lineNumbers.map { clicked < $0.count ? $0[clicked] : nil } ?? clicked
            if let original { model.setCursor(side: side, line: original) }
            let editable = model.viewMode == .all
            let toRight = side == .left, arrow = toRight ? "Right" : "Left"
            let hunk = (applied ?? []).firstIndex { h in
                let r = toRight ? h.left : h.right
                return h.kind == .change && (r.contains(clicked) || (r.isEmpty && r.lowerBound == clicked))
            }
            let menu = NSMenu()
            menu.addItem(ActionMenuItem("Copy to \(arrow)", enabled: editable && hunk != nil) { [weak self] in
                hunk.map { self?.copy(hunk: $0, fromLeft: toRight) }
            })
            menu.addItem(ActionMenuItem("Copy Line to \(arrow)", enabled: editable) { [weak self] in self?.copyLine(clicked, fromLeft: toRight) })
            menu.addItem(ActionMenuItem("Increase Indent", enabled: editable) { [weak self] in self?.indent(tv, range: indentRange, increase: true) })
            menu.addItem(ActionMenuItem("Decrease Indent", enabled: editable) { [weak self] in self?.indent(tv, range: indentRange, increase: false) })
            menu.addItem(.separator())
            for (title, action) in [("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))),
                                    ("Paste", #selector(NSText.paste(_:))), ("Delete", #selector(NSText.delete(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = tv // the text view enables each one for its selection and editability
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Select Section", enabled: hunk != nil) { [weak self] in hunk.map { self?.selectSection($0, in: tv, side: side) } })
            let selection = (tv.string as NSString).substring(with: tv.selectedRange())
            menu.addItem(ActionMenuItem("Compare Selection to Clipboard", enabled: !selection.isEmpty && NSPasteboard.general.string(forType: .string) != nil) { [weak self] in
                WindowManager.shared.openTexts(left: selection, leftLabel: "Selection", right: NSPasteboard.general.string(forType: .string) ?? "",
                                               rightLabel: "Clipboard", tabbedWith: self?.model.window)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Open File…") { [weak self] in self?.model.openFile(side) })
            menu.addItem(ActionMenuItem("Open Clipboard", enabled: NSPasteboard.general.string(forType: .string) != nil) { [weak self] in self?.model.openClipboard(side) })
            menu.addItem(openWithItem(model.urls[side]))
            menu.addItem(ActionMenuItem("Save File", enabled: model.dirty.contains(side)) { [weak self] in self?.model.save(side) })
            menu.addItem(ActionMenuItem("Save File As…") { [weak self] in self?.model.save(side, asNew: true) })
            return menu
        }

        /// Submenu of apps that can open the file, default app first.
        private func openWithItem(_ url: URL?) -> NSMenuItem {
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            guard let url else { item.isEnabled = false; return item }
            let submenu = NSMenu()
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            let apps = [defaultApp].compactMap { $0 } + NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != defaultApp }
            for app in apps {
                let name = FileManager.default.displayName(atPath: app.path) + (app == defaultApp ? " (default)" : "")
                let entry = ActionMenuItem(name) { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
                entry.image = NSWorkspace.shared.icon(forFile: app.path)
                entry.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(entry)
            }
            item.submenu = submenu
            return item
        }

        /// Replaces the matching line on the other side with this line, as an undoable edit.
        func copyLine(_ line: Int, fromLeft: Bool) {
            guard let left, let right else { return }
            let (src, dst) = fromLeft ? (left, right) : (right, left)
            guard line < src.lineStarts.count else { return }
            let text = (src.string as NSString).substring(with: src.contentRange(line: line))
            let target = mapLine(line, hunks: applied ?? [], fromLeft: fromLeft)
            var range = dst.contentRange(line: target)
            var replacement = text
            if target >= dst.lineStarts.count { // past the end: add a new line
                range = NSRange(location: dst.length, length: 0)
                let needsBreak = dst.length > 0 && (dst.string as NSString).character(at: dst.length - 1) != 10
                replacement = (needsBreak ? "\n" : "") + text + "\n"
            }
            replace(range, in: dst, with: replacement, action: fromLeft ? "Copy Line to Right" : "Copy Line to Left")
        }

        /// Adds or removes four spaces (or one tab) at the start of every line in `target`.
        func indent(_ tv: DiffTextView, range target: NSRange, increase: Bool) {
            let ns = tv.string as NSString
            guard NSMaxRange(target) <= ns.length else { return }
            let range = ns.lineRange(for: target)
            let lines = ns.substring(with: range).components(separatedBy: "\n")
            let changed = lines.enumerated().map { i, line -> String in
                if i == lines.count - 1 && line.isEmpty { return line } // text after the final newline
                if increase { return "    " + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
            }.joined(separator: "\n")
            guard changed != ns.substring(with: range) else { return }
            replace(range, in: tv, with: changed, action: increase ? "Increase Indent" : "Decrease Indent")
            tv.setSelectedRange(NSRange(location: range.location, length: (changed as NSString).length))
        }

        func selectSection(_ index: Int, in tv: DiffTextView, side: TextCompareModel.Side) {
            guard let h = applied?[index] else { return }
            let range = tv.charRange(lines: side == .left ? h.left : h.right)
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        }

        private func replace(_ range: NSRange, in tv: DiffTextView, with text: String, action: String) {
            guard tv.isEditable, tv.shouldChangeText(in: range, replacementString: text) else { return }
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.undoManager?.setActionName(action)
        }

        /// Replaces one difference on the other side with this side's lines, as an undoable edit.
        func copy(hunk index: Int, fromLeft: Bool) {
            guard let left, let right, let hunks = applied, hunks.indices.contains(index), hunks[index].kind == .change else { return }
            let h = hunks[index]
            let (src, dst) = fromLeft ? (left, right) : (right, left)
            var text = (src.string as NSString).substring(with: src.charRange(lines: fromLeft ? h.left : h.right))
            let range = dst.charRange(lines: fromLeft ? h.right : h.left)
            let dstText = dst.string as NSString
            // Keep line breaks intact where the copied block lacks the source file's final newline.
            if !text.isEmpty, !text.hasSuffix("\n"), NSMaxRange(range) < dstText.length { text += "\n" }
            if !text.isEmpty, range.location == dstText.length, dstText.length > 0, dstText.character(at: dstText.length - 1) != 10 { text = "\n" + text }
            guard dst.shouldChangeText(in: range, replacementString: text) else { return }
            dst.textStorage?.replaceCharacters(in: range, with: text)
            dst.didChangeText()
            dst.undoManager?.setActionName(fromLeft ? "Copy to Right" : "Copy to Left")
        }

        func scrolled(_ side: TextCompareModel.Side) {
            guard let left, let right else { return }
            let src = side == .left ? left : right, dst = side == .left ? right : left
            src.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            guard !syncing else { return }
            let top = src.visibleRect.minY
            let line = src.line(atY: top)
            let target = mapLine(line, hunks: applied ?? [], fromLeft: side == .left)
            syncing = true
            dst.scrollToLine(target, extraY: top - src.lineTop(line: line), x: src.visibleRect.minX)
            dst.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            syncing = false
        }

        private func applyHighlights(markers: Bool) {
            guard let left, let right else { return }
            let ls = left.string as NSString, rs = right.string as NSString
            for tv in [left, right] {
                tv.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: tv.length))
            }
            var lh: [(range: NSRange, color: NSColor)] = [], rh: [(range: NSRange, color: NSColor)] = []
            for h in applied ?? [] where h.kind == .change {
                let lr = left.charRange(lines: h.left), rr = right.charRange(lines: h.right)
                if h.left.isEmpty {
                    lh.append((lr, DiffColors.insertMarker)); rh.append((rr, DiffColors.inserted))
                } else if h.right.isEmpty {
                    lh.append((lr, DiffColors.deleted)); rh.append((rr, DiffColors.deleteMarker))
                } else {
                    lh.append((lr, DiffColors.changed)); rh.append((rr, DiffColors.changed))
                    guard h.left.count <= 500 else { continue } // inline detail is not worth the cost on huge blocks
                    for k in 0..<min(h.left.count, h.right.count) {
                        let a = left.contentRange(line: h.left.lowerBound + k), b = right.contentRange(line: h.right.lowerBound + k)
                        let (ia, ib) = inlineDiff(ls.substring(with: a), rs.substring(with: b))
                        for r in ia { left.layoutManager?.addTemporaryAttribute(.backgroundColor, value: DiffColors.changedInline, forCharacterRange: NSRange(location: a.location + r.location, length: r.length)) }
                        for r in ib { right.layoutManager?.addTemporaryAttribute(.backgroundColor, value: DiffColors.changedInline, forCharacterRange: NSRange(location: b.location + r.location, length: r.length)) }
                    }
                }
            }
            left.lineHighlights = lh
            right.lineHighlights = rh
            let changes = (applied ?? []).enumerated().filter { $0.element.kind == .change }
            left.copyMarkers = markers ? changes.map { (line: $0.element.left.lowerBound, hunk: $0.offset) } : []
            right.copyMarkers = markers ? changes.map { (line: $0.element.right.lowerBound, hunk: $0.offset) } : []
        }
    }
}
