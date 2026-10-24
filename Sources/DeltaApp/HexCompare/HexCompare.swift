import AppKit
import DiffCore
import SwiftUI

@MainActor final class HexCompareModel: ObservableObject {
    typealias Side = TextCompareModel.Side

    @Published private(set) var urls: [Side: URL] = [:]
    @Published private(set) var data: [Side: Data] = [:]
    @Published private(set) var diffRows: [Int] = []
    @Published private(set) var rowCount = 0
    @Published private(set) var dataToken = 0
    @Published private(set) var current: Int?
    @Published private(set) var scrollToken = 0
    @Published var errorMessage: String?
    weak var window: NSWindow?

    var scrollRow: Int? { current.flatMap { diffRows.indices.contains($0) ? diffRows[$0] : nil } }

    func load(_ url: URL, side: Side) {
        do {
            // Memory-mapped, so multi-gigabyte files are paged in only as rows are shown.
            data[side] = try Data(contentsOf: url, options: .alwaysMapped)
            urls[side] = url
            recompute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swap() {
        (urls[.left], urls[.right]) = (urls[.right], urls[.left])
        (data[.left], data[.right]) = (data[.right], data[.left])
        recompute()
    }

    private func recompute() {
        current = nil
        dataToken += 1
        let a = data[.left] ?? Data(), b = data[.right] ?? Data(), token = dataToken
        rowCount = hexRowCount(a, b)
        diffRows = []
        Task {
            let rows = await Task.detached(priority: .userInitiated) { differingHexRows(a, b) }.value
            if token == dataToken { diffRows = rows }
        }
    }

    func go(_ step: Int) {
        guard !diffRows.isEmpty else { return }
        current = current.map { min(max($0 + step, 0), diffRows.count - 1) } ?? (step > 0 ? 0 : diffRows.count - 1)
        scrollToken += 1
    }
}

struct HexCompareView: View {
    @ObservedObject var model: HexCompareModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                PathBar(title: "Left", url: model.urls[.left]) { model.load($0, side: .left) }
                PathBar(title: "Right", url: model.urls[.right]) { model.load($0, side: .right) }
            }
            Divider()
            HexTableView(model: model)
            StatusBar(left: model.data[.left].map { "\($0.count) bytes" } ?? "", center: summary, right: model.data[.right].map { "\($0.count) bytes" } ?? "")
        }
        .frame(minWidth: 900, minHeight: 400)
        .toolbar {
            SessionToolbar()
            ToolbarItemGroup {
                Button { model.go(-1) } label: { Label("Previous", systemImage: "arrow.up") }
                    .disabled(model.diffRows.isEmpty).help("Previous difference (⌘↑)")
                Button { model.go(1) } label: { Label("Next", systemImage: "arrow.down") }
                    .disabled(model.diffRows.isEmpty).help("Next difference (⌘↓)")
                Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }.help("Swap left and right")
            }
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: model.go))
    }

    private var summary: String {
        guard model.urls.count == 2 else { return "Choose two files to compare" }
        if model.diffRows.isEmpty { return "Identical" }
        let position = model.current.map { "\($0 + 1) of " } ?? ""
        return "\(position)\(model.diffRows.count) differing row\(model.diffRows.count == 1 ? "" : "s")"
    }
}

/// Cell-based NSTableView: draws only visible rows, so millions of rows stay cheap.
struct HexTableView: NSViewRepresentable {
    @ObservedObject var model: HexCompareModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 17
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("offset", "Offset", 90.0), ("left", "Left", 560.0), ("right", "Right", 560.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.isEditable = false
            let cell = NSTextFieldCell()
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.lineBreakMode = .byClipping
            column.dataCell = cell
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.setAccessibilityLabel("Hex comparison")
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update() }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource {
        let model: HexCompareModel
        weak var table: NSTableView?
        private var dataToken = -1
        private var scrollToken = 0
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        init(model: HexCompareModel) { self.model = model }

        func update() {
            guard let table else { return }
            if dataToken != model.dataToken { dataToken = model.dataToken; table.reloadData() }
            if scrollToken != model.scrollToken, let row = model.scrollRow {
                scrollToken = model.scrollToken
                table.scrollRowToVisible(row)
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

        func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
            switch column?.identifier.rawValue {
            case "offset": String(format: "%08X", row * hexBytesPerRow)
            case "left": line(row, mine: .left)
            default: line(row, mine: .right)
            }
        }

        /// "XX XX … XX  ascii", with bytes that differ from the other side highlighted.
        private func line(_ row: Int, mine side: HexCompareModel.Side) -> NSAttributedString {
            let mine = hexRow(model.data[side] ?? Data(), row)
            let other = hexRow(model.data[side == .left ? .right : .left] ?? Data(), row)
            let out = NSMutableAttributedString()
            func add(_ text: String, _ differs: Bool) {
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                if differs { attrs[.backgroundColor] = DiffColors.changedInline }
                out.append(NSAttributedString(string: text, attributes: attrs))
            }
            func differs(_ k: Int) -> Bool { k >= other.count || mine[k] != other[k] }
            for k in 0..<hexBytesPerRow {
                if k < mine.count { add(String(format: "%02X", mine[k]), differs(k)) } else { add("  ", false) }
                add(k == 7 ? "  " : " ", false)
            }
            add(" ", false)
            for k in mine.indices {
                let b = mine[k]
                add((0x20...0x7E).contains(b) ? String(UnicodeScalar(b)) : ".", differs(k))
            }
            return out
        }
    }
}

/// Error alert plus ⌘↓ / ⌘↑ routing for the window that owns this view.
struct SessionChrome: ViewModifier {
    weak var window: NSWindow?
    @Binding var error: String?
    var onStep: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: { Text(error ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .deltaNextDifference)) { n in
                if let window, (n.object as? NSWindow) === window { onStep(1) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deltaPreviousDifference)) { n in
                if let window, (n.object as? NSWindow) === window { onStep(-1) }
            }
    }
}
