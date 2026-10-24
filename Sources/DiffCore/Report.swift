import Foundation

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func page(_ title: String, _ body: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
    <style>
    :root { color-scheme: light dark; --add: #2e7d3233; --del: #c6282833; --chg: #ef6c0033; --muted: #888; }
    body { font: 13px -apple-system, sans-serif; margin: 24px; }
    table { border-collapse: collapse; width: 100%; }
    td, th { padding: 2px 8px; vertical-align: top; text-align: left; }
    th { border-bottom: 1px solid var(--muted); }
    .code td { font: 12px ui-monospace, Menlo, monospace; white-space: pre; }
    .num { color: var(--muted); text-align: right; width: 1%; }
    .add { background: var(--add); } .del { background: var(--del); } .chg { background: var(--chg); }
    .muted { color: var(--muted); }
    </style></head><body><h1>\(esc(title))</h1>\(body)</body></html>
    """
}

/// Side-by-side HTML report of a text compare.
public func htmlTextReport(left: [String], right: [String], hunks: [DiffHunk], leftName: String, rightName: String) -> String {
    var rows = ""
    func row(_ l: Int?, _ r: Int?, _ cls: String) {
        rows += "<tr class=\"\(cls)\"><td class=num>\(l.map { "\($0 + 1)" } ?? "")</td><td>\(l.map { esc(left[$0]) } ?? "")</td>"
            + "<td class=num>\(r.map { "\($0 + 1)" } ?? "")</td><td>\(r.map { esc(right[$0]) } ?? "")</td></tr>\n"
    }
    for h in hunks {
        if h.kind == .equal {
            for (l, r) in zip(h.left, h.right) { row(l, r, "") }
        } else {
            let n = max(h.left.count, h.right.count)
            for k in 0..<n {
                let l = k < h.left.count ? h.left.lowerBound + k : nil, r = k < h.right.count ? h.right.lowerBound + k : nil
                row(l, r, l == nil ? "add" : r == nil ? "del" : "chg")
            }
        }
    }
    let changes = hunks.filter { $0.kind == .change }.count
    return page("Text Compare", "<p>\(esc(leftName)) ↔ \(esc(rightName)): \(changes) difference\(changes == 1 ? "" : "s")</p>"
        + "<table class=code><tr><th></th><th>\(esc(leftName))</th><th></th><th>\(esc(rightName))</th></tr>\n\(rows)</table>")
}

/// HTML report listing every entry of a folder compare with its status.
public func htmlFolderReport(entries: [FolderEntry], leftName: String, rightName: String) -> String {
    let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
    var rows = ""
    func walk(_ list: [FolderEntry], depth: Int) {
        for e in list {
            let cls = switch e.status {
            case .same: ""
            case .leftOnly: "del"
            case .rightOnly: "add"
            default: "chg"
            }
            rows += "<tr class=\"\(cls)\"><td style=\"padding-left:\(8 + depth * 16)px\">\(esc(e.name))\(e.isDirectory ? "/" : "")</td>"
                + "<td>\(e.left.map { $0.isDirectory ? "" : "\($0.size)" } ?? "")</td><td>\(e.left.map { $0.modified.formatted(date) } ?? "")</td>"
                + "<td>\(e.status.rawValue)</td>"
                + "<td>\(e.right.map { $0.isDirectory ? "" : "\($0.size)" } ?? "")</td><td>\(e.right.map { $0.modified.formatted(date) } ?? "")</td></tr>\n"
            walk(e.children ?? [], depth: depth + 1)
        }
    }
    walk(entries, depth: 0)
    return page("Folder Compare", "<p>\(esc(leftName)) ↔ \(esc(rightName))</p><table><tr><th>Name</th><th>Left size</th><th>Left modified</th>"
        + "<th>Status</th><th>Right size</th><th>Right modified</th></tr>\n\(rows)</table>")
}
