import SwiftUI

struct ThumbnailTitleRow: View {
    let url: URL
    let title: String
    var onTap: () -> Void
    
    private let imageService: ImageServiceProtocol = ImageService()
    @State private var thumbnail: NSImage?
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                thumbnailView
                    .frame(width: 34, height: 34)
                    .cornerRadius(4)
                Text(title)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .underline()
            }
        }
        .task { await loadThumb() }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                ProgressView().scaleEffect(0.6)
            }
        }
    }
    
    private func loadThumb() async {
        do {
            let img = try await imageService.getThumbnail(for: url, size: CGSize(width: 64, height: 64))
            thumbnail = img
        } catch {
            thumbnail = nil
        }
    }
}


