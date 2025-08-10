import SwiftUI

struct CSVPreviewView: View {
    let csvContent: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CSV Preview")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(csvContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 800, height: 600)
    }
}


