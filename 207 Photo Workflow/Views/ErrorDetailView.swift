import SwiftUI

struct ErrorDetailView: View {
    let title: String
    let message: String
    let suggestion: String?
    let details: String?
    let onRetry: (() -> Void)?
    
    @State private var showDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let onRetry { Button("Retry", action: onRetry).buttonStyle(.borderedProminent) }
            }
            Text(message)
            if let suggestion {
                Text(suggestion).font(.caption).foregroundColor(.secondary)
            }
            if let details {
                Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }
                    .buttonStyle(.bordered)
                if showDetails {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(6)
                    }.frame(height: 150)
                }
            }
        }
        .padding()
        .background(Constants.Colors.cardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
}


