import SwiftUI

struct DetailedProgressView: View {
    let progress: Double
    let currentFile: String?
    let filesCompleted: Int
    let totalFiles: Int
    let status: String
    let etaText: String?
    let onCancel: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status)
                    .font(.headline)
                Spacer()
                if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.bordered) }
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack(spacing: 12) {
                Text("\(filesCompleted)/\(totalFiles)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                if let etaText {
                    Text("ETA: \(etaText)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let name = currentFile { Text(name).lineLimit(1).truncationMode(.middle).font(.caption) }
            }
        }
        .padding(12)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
}


