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
