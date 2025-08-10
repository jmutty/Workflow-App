import SwiftUI
import AppKit

struct ImagePreviewView: View {
    // Single image (fallback) or carousel mode via allImageURLs/currentIndex
    let imageURL: URL
    let allImageURLs: [URL]?
    let initialIndex: Int?
    let imageService: ImageServiceProtocol = ImageService()
    
    @Environment(\.dismiss) private var dismiss
    @State private var nsImage: NSImage?
    @State private var metadata: ImageMetadata?
    @State private var zoom: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @State private var lastDrag: CGSize = .zero
    @State private var currentIndex: Int = 0
    
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
        .task {
            if let idx = initialIndex { currentIndex = idx }
            await load()
        }
        .onAppear { registerKeyCommands() }
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var content: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.85).ignoresSafeArea()
                if let nsImage {
                    let image = Image(nsImage: nsImage)
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(dragOffset)
                        .gesture(magnifyGesture)
                        .gesture(dragGesture)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(.easeInOut(duration: 0.12), value: zoom)
                } else {
                    ProgressView().controlSize(.regular)
                }
            }
        }
    }
    
    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("Zoom")
                Slider(value: $zoom, in: 0.2...4, step: 0.01)
                    .frame(width: 200)
                Text("\(Int(zoom * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Reset") { withAnimation { zoom = 1.0; dragOffset = .zero } }
            }
            Spacer()
            if let metadata { metadataView(metadata) }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
    
    private func metadataView(_ md: ImageMetadata) -> some View {
        HStack(spacing: 12) {
            if let cs = md.colorSpace { Text(cs).font(.caption).foregroundColor(.secondary) }
            Text(formatBytes(md.fileSize)).font(.caption).foregroundColor(.secondary)
            if let mp = Optional(md.megapixels) { Text(String(format: "%.2f MP", mp)).font(.caption).foregroundColor(.secondary) }
            if let dpi = md.dpi { Text("DPI: \(dpi)").font(.caption).foregroundColor(.secondary) }
            if let model = md.cameraModel { Text(model).font(.caption).foregroundColor(.secondary) }
        }
    }
    
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                zoom = min(max(lastScale * scale, 0.2), 4.0)
            }
            .onEnded { _ in
                lastScale = zoom
            }
    }
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = CGSize(width: lastDrag.width + value.translation.width,
                                    height: lastDrag.height + value.translation.height)
            }
            .onEnded { _ in
                lastDrag = dragOffset
            }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
    
    private var activeURL: URL { allImageURLs?[safe: currentIndex] ?? imageURL }

    private func load() async {
        async let imageTask = imageService.loadImage(from: activeURL)
        async let metaTask = imageService.getImageMetadata(from: activeURL)
        do {
            let (img, meta) = try await (imageTask, metaTask)
            nsImage = img
            metadata = meta
        } catch {
            // Show nothing; parent view handles errors via existing mechanisms
        }
    }

    private func showNext() {
        guard let all = allImageURLs else { return }
        let next = min(currentIndex + 1, all.count - 1)
        if next != currentIndex { currentIndex = next; Task { await load() } }
    }
    private func showPrevious() {
        guard let _ = allImageURLs else { return }
        let prev = max(currentIndex - 1, 0)
        if prev != currentIndex { currentIndex = prev; Task { await load() } }
    }
}

// Safe subscript
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Keyboard shortcuts (arrow keys, escape)
import AppKit
private extension ImagePreviewView {
    func registerKeyCommands() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Escape
                dismiss(); return nil
            case 123: // Left arrow
                showPrevious(); return nil
            case 124: // Right arrow
                showNext(); return nil
            default:
                return event
            }
        }
    }
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


