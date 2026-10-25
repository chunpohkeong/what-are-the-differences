import AppKit
import UniformTypeIdentifiers

/// Test hook: replays AppKit's drop sequence on the view a real drag would reach, since a Finder drag cannot be scripted here.
@MainActor func simulateDrop(_ urls: [URL], at windowPoint: NSPoint, in window: NSWindow) -> String {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("delta-test-drop"))
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
    let offered = Set(pasteboard.types ?? [])
    guard let frameView = window.contentView?.superview else { return "no frame view" }
    // AppKit matches dragged types to registered ones by UTI conformance (SwiftUI registers public.item).
    func accepts(_ view: NSView) -> Bool {
        view.registeredDraggedTypes.contains { registered in
            offered.contains(registered) || offered.contains { type in
                guard let a = UTType(type.rawValue), let b = UTType(registered.rawValue) else { return false }
                return a.conforms(to: b)
            }
        }
    }
    // Like AppKit: the front-most view under the point that accepts the type, whether or not it takes clicks.
    func target(in view: NSView) -> NSView? {
        guard !view.isHidden, view.bounds.contains(view.convert(windowPoint, from: nil)) else { return nil }
        for sub in view.subviews.reversed() { if let found = target(in: sub) { return found } }
        return accepts(view) ? view : nil
    }
    guard let target = target(in: frameView) else {
        var accepting: [String] = []
        func list(_ v: NSView) {
            if accepts(v) { accepting.append("\(type(of: v)) \(v.convert(v.bounds, to: nil))") }
            v.subviews.forEach(list)
        }
        list(frameView)
        return "no view accepts the drop at \(windowPoint); views accepting files: \(accepting)"
    }
    let info = FakeDrag(pasteboard: pasteboard, point: windowPoint, window: window)
    let entered = target.draggingEntered(info)
    let updated = target.draggingUpdated(info)
    let prepared = target.prepareForDragOperation(info)
    let performed = prepared && target.performDragOperation(info)
    if performed { target.concludeDragOperation(info) }
    return "target=\(type(of: target)) entered=\(entered.rawValue) updated=\(updated.rawValue) prepared=\(prepared) performed=\(performed)"
}

private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, point: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = point
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let items = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop = ObjCBool(false)
        for (i, item) in items.enumerated() where !stop.boolValue {
            block(NSDraggingItem(pasteboardWriter: item as! NSPasteboardWriting), i, &stop)
        }
    }
}
