import SwiftUI
import AppKit

// MARK: - Large Thumbnail Component for Better Visibility
struct LargeThumbnailView: View {
    let url: URL
    let size: CGSize
    let cornerRadius: CGFloat
    let showBorder: Bool
    let onTap: (() -> Void)?
    
    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    
    init(
        url: URL,
        size: CGSize = CGSize(width: 200, height: 200),
        cornerRadius: CGFloat = 8,
        showBorder: Bool = true,
        onTap: (() -> Void)? = nil
    ) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.showBorder = showBorder
        self.onTap = onTap
    }
    
    var body: some View {
        Button(action: {
            onTap?()
        }) {
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Constants.Colors.cardBackground)
                    .frame(width: size.width, height: size.height)
                
                if isLoading {
                    // Loading state
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if let thumbnail = thumbnail {
                    // Thumbnail image
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .cornerRadius(cornerRadius)
                } else {
                    // Error state
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Failed to load")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Hover overlay
                if onTap != nil {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.black.opacity(0.1))
                        .frame(width: size.width, height: size.height)
                        .opacity(0)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                // Hover effect handled by button style
                            }
                        }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(showBorder ? Constants.Colors.cardBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(ThumbnailButtonStyle())
        .disabled(onTap == nil)
        .task {
            await loadThumbnail()
        }
    }
    
    // MARK: - Thumbnail Loading
    @MainActor
    private func loadThumbnail() async {
        isLoading = true
        
        do {
            let thumbnail = try await generateThumbnail(for: url, size: size)
            self.thumbnail = thumbnail
        } catch {
            print("Failed to generate thumbnail for \(url.lastPathComponent): \(error)")
        }
        
        isLoading = false
    }
    
    private func generateThumbnail(for url: URL, size: CGSize) async throws -> NSImage {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    continuation.resume(throwing: ThumbnailError.failedToCreateImage)
                    return
                }
                
                // Calculate thumbnail size maintaining aspect ratio
                let originalWidth = CGFloat(cgImage.width)
                let originalHeight = CGFloat(cgImage.height)
                let aspectRatio = originalWidth / originalHeight
                
                var thumbnailSize = size
                if aspectRatio > 1 {
                    // Landscape
                    thumbnailSize.height = size.width / aspectRatio
                } else {
                    // Portrait
                    thumbnailSize.width = size.height * aspectRatio
                }
                
                // Create thumbnail
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize.width, thumbnailSize.height)
                ]
                
                guard let thumbnailCGImage = CGImageSourceCreateThumbnailAtIndex(
                    imageSource, 0, thumbnailOptions as CFDictionary
                ) else {
                    continuation.resume(throwing: ThumbnailError.failedToCreateThumbnail)
                    return
                }
                
                let nsImage = NSImage(cgImage: thumbnailCGImage, size: thumbnailSize)
                continuation.resume(returning: nsImage)
            }
        }
    }
}

// MARK: - Thumbnail Button Style
private struct ThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Thumbnail Error
private enum ThumbnailError: Error {
    case failedToCreateImage
    case failedToCreateThumbnail
}

// MARK: - Before/After Comparison View
struct BeforeAfterThumbnailView: View {
    let operation: RenameOperation
    let onPreview: (() -> Void)?
    
    private let thumbnailSize = CGSize(width: 100, height: 100)
    
    var body: some View {
        HStack(spacing: 12) {
            // Before (Original)
            VStack(spacing: 6) {
                LargeThumbnailView(
                    url: operation.sourceURL,
                    size: thumbnailSize,
                    onTap: nil // Let the outer button handle the tap
                )
                
                VStack(spacing: 2) {
                    Text("Original")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(operation.originalName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(width: thumbnailSize.width)
                }
            }
            
            // Arrow
            Image(systemName: "arrow.right")
                .font(.title3)
                .foregroundColor(Constants.Colors.brandTint)
            
            // After (New Name)
            VStack(spacing: 6) {
                LargeThumbnailView(
                    url: operation.sourceURL,
                    size: thumbnailSize,
                    onTap: nil // Let the outer button handle the tap
                )
                .overlay(
                    // Conflict indicator
                    operation.hasConflict ? 
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Constants.Colors.warningOrange)
                                .background(Circle().fill(Color.white).frame(width: 16, height: 16))
                                .font(.caption)
                                .padding(2)
                        }
                    } : nil
                )
                
                VStack(spacing: 2) {
                    Text("New Name")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(operation.newName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(operation.hasConflict ? Constants.Colors.warningOrange : .primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(width: thumbnailSize.width)
                }
            }
        }
        .padding(12)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(operation.hasConflict ? Constants.Colors.warningOrange : Constants.Colors.cardBorder, lineWidth: 1)
        )
        .onTapGesture {
            onPreview?()
        }
        .help("Click to preview image")
    }
}

// MARK: - Preview
#if DEBUG
struct LargeThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            LargeThumbnailView(
                url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Monterey.heic"),
                size: CGSize(width: 200, height: 200)
            )
            
            if let sampleURL = URL(string: "file:///tmp/sample.jpg") {
                BeforeAfterThumbnailView(
                    operation: RenameOperation(
                        originalName: "IMG_1234.jpg",
                        newName: "Tigers_John_Smith_1.jpg",
                        hasConflict: false,
                        sourceURL: sampleURL
                    ),
                    onPreview: {}
                )
            }
        }
        .padding()
    }
}
#endif
