import SwiftUI

struct CSVEditorView: View {
    let url: URL
    let sourceFolderURL: URL
    let allImageURLs: [URL]
    let onPreview: (URL) -> Void
    let onClose: () -> Void
    
    @State private var headers: [String] = []
    @State private var rows: [[String]] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasClosed = false
    
    private let csvService: CSVServiceProtocol = CSVService()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit CSV")
                    .font(.title2).bold()
                Text(url.lastPathComponent)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Add Row") { addRow() }
                Button(isSaving ? "Saving..." : "Close") {
                    Task {
                        let ok = await save()
                        if ok && !hasClosed {
                            hasClosed = true
                            onClose()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            Divider()
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            CSVEditorTableView(
                headers: $headers,
                rows: $rows,
                originalColumnIndex: originalColumnIndex,
                baseURL: sourceFolderURL,
                onPreview: onPreview,
                onChange: { updated in
                    rows = updated
                }
            )
        }
        .padding()
        .frame(width: 1000, height: 560)
        .task { await load() }
        .onDisappear {
            Task {
                if !hasClosed {
                    _ = await save()
                    hasClosed = true
                    onClose()
                }
            }
        }
        // Large image preview is managed by parent via onPreview
    }
    
    private var originalColumnIndex: Int {
        if let idx = headers.firstIndex(where: { $0.lowercased().contains("original") }) { return idx }
        return 0
    }
    
    private func load() async {
        do {
            let result = try await csvService.parseCSV(from: url)
            let hdrs = result.headers
            var data = result.rows
            // Ensure each row matches header count
            data = data.map { row in
                if row.count < hdrs.count { return row + Array(repeating: "", count: hdrs.count - row.count) }
                if row.count > hdrs.count { return Array(row.prefix(hdrs.count)) }
                return row
            }
            await MainActor.run {
                headers = hdrs
                rows = data
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load CSV: \(error.localizedDescription)"
            }
        }
    }
    
    @discardableResult
    private func save() async -> Bool {
        await MainActor.run { isSaving = true }
        defer { Task { await MainActor.run { isSaving = false } } }
        do {
            let content = [headers] + rows
            try await csvService.writeCSV(content, to: url, encoding: .utf8)
            await MainActor.run { errorMessage = nil }
            return true
        } catch {
            await MainActor.run { errorMessage = "Failed to save: \(error.localizedDescription)" }
            return false
        }
    }
    
    private func addRow() {
        if headers.isEmpty { headers = ["original", "first", "last", "col4", "col5", "col6", "team", "group"] }
        rows.append(Array(repeating: "", count: headers.count))
    }
    
    private func cellValue(_ r: Int, _ c: Int) -> String {
        guard r < rows.count, c < rows[r].count else { return "" }
        return rows[r][c]
    }
    
    private func setCellValue(_ r: Int, _ c: Int, _ new: String) {
        guard r < rows.count else { return }
        if c >= rows[r].count {
            rows[r] += Array(repeating: "", count: c - rows[r].count + 1)
        }
        rows[r][c] = new
    }
}

// Removed inline thumbnails to improve responsiveness
