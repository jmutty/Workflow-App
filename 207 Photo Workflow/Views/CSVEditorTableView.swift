import SwiftUI
import AppKit

struct CSVEditorTableView: NSViewRepresentable {
    @Binding var headers: [String]
    @Binding var rows: [[String]]
    let originalColumnIndex: Int
    let baseURL: URL
    let onPreview: (URL) -> Void
    let onChange: ([[String]]) -> Void
    
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.headerView = NSTableHeaderView()
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.rowSizeStyle = .small
        table.intercellSpacing = NSSize(width: 4, height: 4)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        
        context.coordinator.tableView = table
        configureColumns(table)
        
        scroll.documentView = table
        return scroll
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let table = nsView.documentView as? NSTableView else { return }
        context.coordinator.baseURL = baseURL
        context.coordinator.onPreview = onPreview
        context.coordinator.onChange = onChange
        context.coordinator.headers = headers
        context.coordinator.rows = rows
        syncColumnsIfNeeded(table)
        table.reloadData()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(headers: headers, rows: rows, originalColumnIndex: originalColumnIndex, baseURL: baseURL, onPreview: onPreview, onChange: onChange)
    }
    
    private func configureColumns(_ table: NSTableView) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        for (i, title) in headers.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(i)"))
            column.title = title
            column.minWidth = 80
            column.width = 160
            column.isEditable = true
            table.addTableColumn(column)
        }
    }
    
    private func syncColumnsIfNeeded(_ table: NSTableView) {
        if table.tableColumns.count != headers.count {
            configureColumns(table)
        } else {
            for (i, col) in table.tableColumns.enumerated() {
                col.title = headers[i]
            }
        }
    }
    
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var headers: [String]
        var rows: [[String]]
        let originalColumnIndex: Int
        var baseURL: URL
        var onPreview: (URL) -> Void
        var onChange: ([[String]]) -> Void
        weak var tableView: NSTableView?
        
        init(headers: [String], rows: [[String]], originalColumnIndex: Int, baseURL: URL, onPreview: @escaping (URL) -> Void, onChange: @escaping ([[String]]) -> Void) {
            self.headers = headers
            self.rows = rows
            self.originalColumnIndex = originalColumnIndex
            self.baseURL = baseURL
            self.onPreview = onPreview
            self.onChange = onChange
        }
        
        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }
        
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn = tableColumn else { return nil }
            let colIndex = tableView.tableColumns.firstIndex(of: tableColumn) ?? 0
            let identifier = NSUserInterfaceItemIdentifier("cell_\(colIndex)")
            let field: NSTextField
            if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
                field = existing
            } else {
                field = NSTextField()
                field.isBordered = true
                field.bezelStyle = .roundedBezel
                field.drawsBackground = true
                field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                field.delegate = self
                field.identifier = identifier
                field.isEditable = true
                field.isSelectable = true
                field.usesSingleLineMode = true
                field.lineBreakMode = .byTruncatingMiddle
                field.cell?.isScrollable = true
            }
            let value = safeValue(row: row, col: colIndex)
            field.stringValue = value
            field.tag = (row << 16) | colIndex
            return field
        }
        
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let row = field.tag >> 16
            let col = field.tag & 0xFFFF
            setValue(field.stringValue, row: row, col: col)
            onChange(rows)
        }

        func controlTextDidChange(_ obj: Notification) {
            // Keep model reasonably in sync without heavy SwiftUI churn
            guard let field = obj.object as? NSTextField else { return }
            let row = field.tag >> 16
            let col = field.tag & 0xFFFF
            setValue(field.stringValue, row: row, col: col)
        }
        
        @objc func didDoubleClick(_ sender: Any?) {
            guard let tv = tableView else { return }
            let row = tv.clickedRow
            let col = tv.clickedColumn
            guard row >= 0, col >= 0, col == originalColumnIndex else { return }
            let raw = safeValue(row: row, col: col)
            let name = sanitize(raw)
            guard !name.isEmpty else { return }
            let url = resolveURL(for: name)
            onPreview(url)
        }
        
        private func safeValue(row: Int, col: Int) -> String {
            guard row < rows.count else { return "" }
            let r = rows[row]
            if col < r.count { return r[col] }
            return ""
        }
        
        private func setValue(_ value: String, row: Int, col: Int) {
            guard row >= 0 && col >= 0 else { return }
            if row >= rows.count { rows += Array(repeating: Array(repeating: "", count: headers.count), count: row - rows.count + 1) }
            if col >= rows[row].count { rows[row] += Array(repeating: "", count: col - rows[row].count + 1) }
            rows[row][col] = value
        }

        private func sanitize(_ s: String) -> String {
            var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.hasPrefix("\"") && out.hasSuffix("\"") {
                out = String(out.dropFirst().dropLast())
            }
            return out
        }

        private func resolveURL(for name: String) -> URL {
            let fm = FileManager.default
            var candidate = baseURL.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            // Try common extensions if missing
            if (name as NSString).pathExtension.isEmpty {
                for ext in ["jpg","JPG","jpeg","png","tif","tiff"] {
                    candidate = baseURL.appendingPathComponent(name + "." + ext)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
            // Case-insensitive search fallback
            if let items = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
                if let match = items.first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                    return match
                }
            }
            return baseURL.appendingPathComponent(name)
        }
    }
}


