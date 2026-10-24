import AppKit
import DiffCore
import SwiftUI

@MainActor final class TableCompareModel: ObservableObject {
    typealias Side = TextCompareModel.Side

    @Published private(set) var urls: [Side: URL] = [:]
    @Published var hasHeader = true { didSet { recompute() } }
    /// 1-based column numbers, e.g. "1" or "1,3". Empty matches rows by position.
    @Published var keyText = "" { didSet { recompute() } }
    @Published var differencesOnly = false
    @Published private(set) var rows: [TableRowDiff] = []
    @Published private(set) var header: [String] = []
    @Published private(set) var columnCount = 0
    @Published var errorMessage: String?
    weak var window: NSWindow?
    private var tables: [Side: [[String]]] = [:]

    var visibleRows: [TableRowDiff] { differencesOnly ? rows.filter { $0.kind != .same } : rows }
    var changeCount: Int { rows.filter { $0.kind != .same }.count }

    func load(_ url: URL, side: Side) {
        do {
            let text = try TextDocument.load(url).text
            let first = text.prefix { $0 != "\n" }
            let separator: Character = url.pathExtension.lowercased() == "tsv" || (first.contains("\t") && !first.contains(",")) ? "\t"
                : (first.contains(";") && !first.contains(",")) ? ";" : ","
            tables[side] = parseDelimited(text, separator: separator)
            urls[side] = url
            recompute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swap() {
        (urls[.left], urls[.right]) = (urls[.right], urls[.left])
        (tables[.left], tables[.right]) = (tables[.right], tables[.left])
        recompute()
    }

    private func recompute() {
        let l = tables[.left] ?? [], r = tables[.right] ?? []
        let skip = hasHeader ? 1 : 0
        header = hasHeader ? (l.first ?? r.first ?? []) : []
        let keys = keyText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.map { $0 - 1 }
        rows = diffTables(Array(l.dropFirst(skip)), Array(r.dropFirst(skip)), keyColumns: keys)
        columnCount = (l + r).map(\.count).max() ?? 0
    }
}

struct TableCompareView: View {
    @ObservedObject var model: TableCompareModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                PathBar(title: "Left", url: model.urls[.left]) { model.load($0, side: .left) }
                PathBar(title: "Right", url: model.urls[.right]) { model.load($0, side: .right) }
            }
            HStack(spacing: 10) {
                Toggle("First row is header", isOn: $model.hasHeader)
                Text("Match rows by columns").foregroundStyle(.secondary)
                TextField("e.g. 1 or 1,3", text: $model.keyText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("Rows with the same values in these 1-based columns are compared; leave empty to match by position")
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Table(model.visibleRows) {
                TableColumn("") { (row: TableRowDiff) in
                    Text(mark(row.kind)).foregroundStyle(color(row.kind)).accessibilityLabel(label(row.kind))
                }
                .width(24)
                TableColumnForEach(Array(0..<model.columnCount), id: \.self) { col in
                    TableColumn(col < model.header.count ? model.header[col] : "Column \(col + 1)") { (row: TableRowDiff) in
                        cell(row, col)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(left: "≠ changed · − left only · + right only",
                      center: model.urls.count == 2 ? "\(model.changeCount) differing row\(model.changeCount == 1 ? "" : "s") of \(model.rows.count)" : "Choose two CSV or TSV files",
                      right: "")
        }
        .frame(minWidth: 700, minHeight: 400)
        .toolbar {
            SessionToolbar()
            ToolbarItemGroup {
                Toggle(isOn: $model.differencesOnly) { Label("Diffs Only", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Hide rows that are the same")
                Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }.help("Swap left and right")
            }
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: { _ in }))
    }

    @ViewBuilder private func cell(_ row: TableRowDiff, _ col: Int) -> some View {
        let l = row.left.map { col < $0.count ? $0[col] : "" }, r = row.right.map { col < $0.count ? $0[col] : "" }
        switch row.kind {
        case .changed where row.changedColumns.contains(col):
            Text("\(l ?? "") → \(r ?? "")").foregroundStyle(.red)
        case .leftOnly: Text(l ?? "").foregroundStyle(.purple)
        case .rightOnly: Text(r ?? "").foregroundStyle(.purple)
        default: Text(l ?? r ?? "")
        }
    }

    private func mark(_ kind: TableRowDiff.Kind) -> String {
        switch kind { case .same: ""; case .changed: "≠"; case .leftOnly: "−"; case .rightOnly: "+" }
    }

    private func label(_ kind: TableRowDiff.Kind) -> String {
        switch kind { case .same: "Same"; case .changed: "Changed"; case .leftOnly: "Left only"; case .rightOnly: "Right only" }
    }

    private func color(_ kind: TableRowDiff.Kind) -> Color {
        switch kind { case .same: .primary; case .changed: .red; case .leftOnly, .rightOnly: .purple }
    }
}
