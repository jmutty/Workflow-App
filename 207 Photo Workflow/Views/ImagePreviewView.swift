import SwiftUI
import AppKit

struct ImagePreviewView: View {
    // Single image (fallback) or carousel mode via allImageURLs/currentIndex
    let imageURL: URL
    let allImageURLs: [URL]?
    let initialIndex: Int?
    let imageService: ImageServiceProtocol = ImageService()
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var metadata: ImageMetadata?
    
    // Zoom and pan state (persistent across images)
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 750, minHeight: 550)
        .background(
            KeyCatcher { keyCode in
                switch keyCode {
                case 53: // escape
                    dismiss()
                case 123: // left
                    showPrevious()
                case 124: // right
                    showNext()
                default:
                    break
                }
            }
        )
        .onAppear { 
            // Set initial index if provided
            if let initialIndex = initialIndex {
                currentIndex = max(0, min(initialIndex, (allImageURLs?.count ?? 1) - 1))
            }
        }
    }
    
    private var header: some View {
        HStack {
            Text(activeURL.lastPathComponent)
                .font(.headline)
            Spacer()
            if let dims = metadata?.dimensions {
                Text("\(Int(dims.width))×\(Int(dims.height))")
                    .foregroundColor(.secondary)
            }
            if let all = allImageURLs, all.count > 1 {
                HStack(spacing: 8) {
                    Button { showPrevious() } label: { Image(systemName: "chevron.left") }
                        .disabled(currentIndex <= 0)
                    Text("\(currentIndex + 1)/\(all.count)")
                        .font(.caption).foregroundColor(.secondary)
                    Button { showNext() } label: { Image(systemName: "chevron.right") }
                        .disabled(currentIndex >= all.count - 1)
                }
            }
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .allowsHitTesting(true)
            .zIndex(1000) // Ensure it's above other content
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .zIndex(999) // Ensure header is above gesture area
    }
    
    private var content: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.85).ignoresSafeArea()

                AsyncImage(url: activeURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(offset)
                        .onTapGesture(count: 2) {
                            // Double tap to reset zoom
                            withAnimation(.easeInOut(duration: 0.3)) {
                                if zoom > 1.1 {
                                    resetZoom()
                                } else {
                                    zoom = 2.0
                                    lastZoom = zoom
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } placeholder: {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading image...")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Apply gestures to the entire content area, but with proper priority
            .simultaneousGesture(
                // Pinch to zoom
                MagnificationGesture()
                    .onChanged { value in
                        let newZoom = lastZoom * value
                        zoom = min(max(newZoom, 0.5), 5.0)
                    }
                    .onEnded { _ in
                        lastZoom = zoom
                        constrainOffset(in: geometry)
                    }
            )
            .simultaneousGesture(
                // Pan when zoomed - only active when zoomed in
                DragGesture(minimumDistance: zoom > 1.1 ? 10 : 1000)
                    .onChanged { value in
                        if zoom > 1.1 {
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                    }
                    .onEnded { _ in
                        if zoom > 1.1 {
                            lastOffset = offset
                            constrainOffset(in: geometry)
                        }
                    }
            )
        }
        .task(id: currentIndex) {
            // Load metadata when image changes (zoom persists)
            await loadMetadata()
        }
    }
    
    private var footer: some View {
        HStack(spacing: 16) {
            // Zoom info and controls
            HStack(spacing: 12) {
                Text("\(Int(zoom * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 40)
                
                if zoom > 1.1 {
                    Button("Reset Zoom") {
                        withAnimation(.easeOut(duration: 0.3)) {
                            resetZoom()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            Spacer()
            
            if let metadata { 
                metadataView(metadata) 
            }
            
            Spacer()
            
            // Navigation info
            if let all = allImageURLs, all.count > 1 {
                Text("Use ← → keys to navigate • Double tap to zoom")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Double tap to zoom • Pinch to zoom")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .zIndex(999) // Ensure footer is above gesture area
    }
    
    private func metadataView(_ md: ImageMetadata) -> some View {
        HStack(spacing: 12) {
            if let cs = md.colorSpace { 
                Text(cs).font(.caption).foregroundColor(.secondary) 
            }
            Text(formatBytes(md.fileSize)).font(.caption).foregroundColor(.secondary)
            if let mp = Optional(md.megapixels) { 
                Text(String(format: "%.2f MP", mp)).font(.caption).foregroundColor(.secondary) 
            }
            if let dpi = md.dpi { 
                Text("DPI: \(dpi)").font(.caption).foregroundColor(.secondary) 
            }
            if let model = md.cameraModel { 
                Text(model).font(.caption).foregroundColor(.secondary) 
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    private var activeURL: URL { allImageURLs?[safe: currentIndex] ?? imageURL }

    @MainActor private func loadMetadata() async {
        do {
            metadata = try await imageService.getImageMetadata(from: activeURL)
        } catch {
            metadata = nil
        }
    }

    private func showNext() {
        guard let all = allImageURLs else { return }
        let next = min(currentIndex + 1, all.count - 1)
        if next != currentIndex {
            currentIndex = next
        }
    }
    
    private func showPrevious() {
        guard let _ = allImageURLs else { return }
        let prev = max(currentIndex - 1, 0)
        if prev != currentIndex {
            currentIndex = prev
        }
    }
    
    private func resetZoom() {
        zoom = 1.0
        lastZoom = 1.0
        offset = .zero
        lastOffset = .zero
    }
    
    private func constrainOffset(in geometry: GeometryProxy) {
        let maxOffsetX = max(0, (geometry.size.width * (zoom - 1)) / 2)
        let maxOffsetY = max(0, (geometry.size.height * (zoom - 1)) / 2)
        
        withAnimation(.easeOut(duration: 0.2)) {
            offset.width = min(max(offset.width, -maxOffsetX), maxOffsetX)
            offset.height = min(max(offset.height, -maxOffsetY), maxOffsetY)
            lastOffset = offset
        }
    }
}

// Safe subscript
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - NSViewRepresentable key catcher
private struct KeyCatcher: NSViewRepresentable {
    var onKeyDown: (UInt16) -> Void
    
    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        return v
    }
    
    func updateNSView(_ nsView: KeyCatcherView, context: Context) {}

    final class KeyCatcherView: NSView {
        var onKeyDown: ((UInt16) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        
        override func keyDown(with event: NSEvent) {
            onKeyDown?(event.keyCode)
        }
    }
}