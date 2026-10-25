import AppKit

/// UTF-16 offset of each line start; matches DiffCore.splitLines line numbering.
func lineStartOffsets(_ text: String) -> [Int] {
    let utf16 = text.utf16
    guard !utf16.isEmpty else { return [] }
    var starts = [0]
    var i = 0
    for unit in utf16 {
        i += 1
        if unit == 10, i < utf16.count { starts.append(i) }
    }
    return starts
}

/// Plain monospaced NSTextView (TextKit 1) that draws full-width line highlights.
final class DiffTextView: NSTextView {
    /// Zero-length ranges draw a thin marker where the other side has lines this side lacks.
    var lineHighlights: [(range: NSRange, color: NSColor)] = [] { didSet { needsDisplay = true } }
    var lineStarts: [Int] = [] { didSet { enclosingScrollView?.verticalRulerView?.needsDisplay = true } }
    /// Copy arrows drawn in the line-number gutter: the line each sits on and the hunk index it copies.
    var copyMarkers: [(line: Int, hunk: Int)] = [] { didSet { enclosingScrollView?.verticalRulerView?.needsDisplay = true } }
    /// Arrow direction: true on the left pane (copies to the right).
    var copiesToRight = true
    var onCopyMarker: ((Int) -> Void)?
    /// Original line number (0-based) for each shown line when the pane shows a filtered view; nil entries are gaps.
    var lineNumbers: [Int?]? { didSet { enclosingScrollView?.verticalRulerView?.needsDisplay = true } }
    /// Files or folders dropped on the pane; without it a dropped file inserts its path as text.
    var onDropFiles: (([URL]) -> Void)?

    func fileDragOperation(_ info: NSDraggingInfo) -> NSDragOperation? {
        let accepts = onDropFiles != nil && droppedURLs(info) != nil
        showDropTarget(accepts)
        return accepts ? .copy : nil
    }

    func acceptFiles(_ info: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        guard let onDropFiles, let urls = droppedURLs(info) else { return false }
        onDropFiles(urls)
        return true
    }

    /// Accent outline around the pane while files are dragged over it.
    func showDropTarget(_ on: Bool) {
        guard let scroll = enclosingScrollView else { return }
        scroll.wantsLayer = true
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        scroll.layer?.borderWidth = on ? 3 : 0
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL]? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragOperation(sender) ?? super.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragOperation(sender) ?? super.draggingUpdated(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptFiles(sender) || super.performDragOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropTarget(false)
        super.draggingExited(sender)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, !lineHighlights.isEmpty else { return }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let visible = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let textLength = length
        for (stale, color) in lineHighlights {
            // Highlights lag edits until the debounced re-diff, so clamp them to the text as it is now.
            guard stale.location <= textLength else { continue }
            let range = NSRange(location: stale.location, length: min(stale.length, textLength - stale.location))
            guard range.location <= NSMaxRange(visible), NSMaxRange(range) >= visible.location else { continue }
            color.setFill()
            if range.length == 0 {
                NSRect(x: 0, y: lineTop(at: range.location) - 1, width: bounds.width, height: 2).fill()
            } else {
                // Leave out the final newline: at the end of the text its glyph spills into the empty extra line.
                var chars = range
                if chars.length > 1, (string as NSString).character(at: NSMaxRange(chars) - 1) == 10 { chars.length -= 1 }
                var r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil), in: tc)
                r.origin.x = 0
                r.size.width = bounds.width
                r.origin.y += origin.y
                r.fill()
            }
        }
    }

    var length: Int { (string as NSString).length }

    func charIndex(ofLine line: Int) -> Int { line < lineStarts.count ? lineStarts[line] : length }

    /// Characters of `lines`, including their newlines; empty ranges sit at the insertion point.
    func charRange(lines: Range<Int>) -> NSRange {
        let start = min(charIndex(ofLine: lines.lowerBound), length)
        let end = lines.isEmpty ? start : min(charIndex(ofLine: lines.upperBound), length)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// One line without its trailing newline.
    func contentRange(line: Int) -> NSRange {
        let r = charRange(lines: line..<(line + 1))
        if r.length > 0, (string as NSString).character(at: NSMaxRange(r) - 1) == 10 {
            return NSRange(location: r.location, length: r.length - 1)
        }
        return r
    }

    func lineIndex(containing char: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        guard hi >= 0 else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= char { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Y of the top of the line holding `charIndex`, in view coordinates.
    func lineTop(at charIndex: Int) -> CGFloat {
        guard let lm = layoutManager else { return 0 }
        var y: CGFloat = 0
        if charIndex < length {
            y = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: charIndex), effectiveRange: nil).minY
        } else if lm.extraLineFragmentRect.height > 0 {
            y = lm.extraLineFragmentRect.minY
        } else if lm.numberOfGlyphs > 0 {
            y = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil).maxY
        }
        return y + textContainerOrigin.y
    }

    func lineTop(line: Int) -> CGFloat { lineTop(at: charIndex(ofLine: line)) }

    func line(atY y: CGFloat) -> Int {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return 0 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y - textContainerOrigin.y), in: tc)
        return lineIndex(containing: lm.characterIndexForGlyph(at: glyph))
    }

    func scrollToLine(_ line: Int, extraY: CGFloat = 0, x: CGFloat? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let target = NSRect(origin: NSPoint(x: x ?? clip.bounds.minX, y: max(0, lineTop(line: line) + extraY)), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

final class LineNumberRuler: NSRulerView {
    init(textView: DiffTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 62
    }

    /// Where the copy arrow for a line is drawn, in ruler coordinates.
    private func arrowRect(_ tv: DiffTextView, line: Int) -> NSRect {
        NSRect(x: 4, y: convert(NSPoint(x: 0, y: tv.lineTop(line: line)), from: tv).y + 1, width: 16, height: 13)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = clientView as? DiffTextView else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if let marker = tv.copyMarkers.first(where: { arrowRect(tv, line: $0.line).insetBy(dx: -3, dy: -3).contains(p) }) {
            tv.onCopyMarker?(marker.hunk)
        } else {
            super.mouseDown(with: event)
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? DiffTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -tv.textContainerOrigin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var line = tv.lineIndex(containing: chars.location)
        while line < tv.lineStarts.count, tv.lineStarts[line] <= NSMaxRange(chars) {
            let y = convert(NSPoint(x: 0, y: tv.lineTop(line: line)), from: tv).y
            let number: Int? = tv.lineNumbers.map { line < $0.count ? $0[line] : nil } ?? line
            if let number {
                let label = "\(number + 1)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + 1), withAttributes: attrs)
            }
            line += 1
        }
        let symbol = tv.copiesToRight ? "arrowshape.right.fill" : "arrowshape.left.fill"
        guard !tv.copyMarkers.isEmpty,
              let arrow = NSImage(systemSymbolName: symbol, accessibilityDescription: tv.copiesToRight ? "Copy to right" : "Copy to left")?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange])) else { return }
        for marker in tv.copyMarkers {
            let r = arrowRect(tv, line: marker.line)
            if r.intersects(rect) {
                arrow.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

/// Scroll view + non-wrapping monospaced text view + line-number ruler.
@MainActor func makeTextPane(editable: Bool, label: String) -> (NSScrollView, DiffTextView) {
    let tv = DiffTextView(usingTextLayoutManager: false)
    tv.isRichText = false
    tv.isEditable = editable
    tv.allowsUndo = true
    tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.isContinuousSpellCheckingEnabled = false
    tv.layoutManager?.allowsNonContiguousLayout = true
    tv.textContainerInset = NSSize(width: 4, height: 4)
    tv.isHorizontallyResizable = true
    tv.isVerticallyResizable = true
    tv.autoresizingMask = [.width, .height]
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = false
    tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.setAccessibilityLabel(label)

    let scroll = PaneScrollView()
    tv.registerForDraggedTypes([.fileURL])
    scroll.registerForDraggedTypes([.fileURL])
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = tv
    let ruler = LineNumberRuler(textView: tv)
    // Views built with the macOS 14+ SDK do not clip by default; without this the gutter's border line
    // and line highlights draw up over the path bar above the pane.
    ruler.clipsToBounds = true
    tv.clipsToBounds = true
    scroll.clipsToBounds = true
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    scroll.contentView.postsBoundsChangedNotifications = true
    return (scroll, tv)
}

/// Takes drops on the empty area below short text, which belongs to the scroll view, not the text view.
final class PaneScrollView: NSScrollView {
    private var text: DiffTextView? { documentView as? DiffTextView }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { text?.fileDragOperation(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { text?.fileDragOperation(sender) ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { text?.acceptFiles(sender) ?? false }
    override func draggingExited(_ sender: NSDraggingInfo?) { text?.showDropTarget(false) }
}
