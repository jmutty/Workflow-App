import SwiftUI

struct AllRenamesListView: View {
    let operations: [RenameOperation]
    let onOpenPreview: (_ urls: [URL], _ startIndex: Int) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All Files (") + Text("\(operations.count)").bold() + Text(")")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
            }
            .font(.title3)
            .padding(.horizontal)
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(operations.enumerated()), id: \.offset) { index, op in
                        HStack(spacing: 10) {
                            ThumbnailTitleRow(url: op.sourceURL, title: op.originalName) {
                                let urls = operations.map { $0.sourceURL }
                                onOpenPreview(urls, index)
                            }
                            Image(systemName: "arrow.right")
                                .foregroundColor(.blue)
                            Text(op.newName)
                                .fontWeight(.medium)
                                .foregroundColor(op.hasConflict ? Constants.Colors.warningOrange : .primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if op.hasConflict {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Constants.Colors.warningOrange)
                                    .font(.caption)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(minWidth: 750, minHeight: 550)
    }
}


