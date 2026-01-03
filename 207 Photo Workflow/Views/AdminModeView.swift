import SwiftUI
import AppKit

struct AdminModeView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: AdminRatingViewModel
    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var contentOffset: CGSize = .zero
    @State private var baseContentOffset: CGSize = .zero
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: AdminRatingViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(.bottom, 0)
        .preferredColorScheme(jobManager.colorScheme)
    }
    
    private var header: some View {
        HStack {
            Image(systemName: "gearshape")
                .foregroundColor(Constants.Colors.brandTint)
            Text("Admin Mode")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Picker("Mode", selection: $viewModel.selectedMode) {
                Text("Sports").tag(AdminModeType.sports)
                Text("School").tag(AdminModeType.school)
            }
            .pickerStyle(.segmented)
            Button(action: { Task { await viewModel.start() } }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSampling)
        }
        .padding()
        .background(Constants.Colors.cardBackground)
    }
    
    private var content: some View {
        HStack(spacing: 16) {
            preview
            Divider()
            ratingForm
        }
        .padding()
    }
    
    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentFileName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text("Zoom")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Slider(value: $zoomScale, in: 0.5...4.0)
                        .frame(width: 160)
                    Button("Fit") { zoomScale = 1.0; baseZoomScale = 1.0; contentOffset = .zero; baseContentOffset = .zero }
                        .font(.system(size: 11))
                }
                ZStack {
                    Rectangle().fill(Constants.Colors.cardBackground).cornerRadius(8)
                    if let img = viewModel.currentImage {
                        GeometryReader { geo in
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(zoomScale)
                                .offset(contentOffset)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .contentShape(Rectangle())
                                .gesture(
                                    SimultaneousGesture(
                                        MagnificationGesture()
                                            .onChanged { value in
                                                zoomScale = max(0.5, min(4.0, baseZoomScale * value))
                                            }
                                            .onEnded { _ in
                                                baseZoomScale = zoomScale
                                            },
                                        DragGesture()
                                            .onChanged { value in
                                                contentOffset = CGSize(
                                                    width: baseContentOffset.width + value.translation.width,
                                                    height: baseContentOffset.height + value.translation.height
                                                )
                                            }
                                            .onEnded { value in
                                                baseContentOffset = CGSize(
                                                    width: baseContentOffset.width + value.translation.width,
                                                    height: baseContentOffset.height + value.translation.height
                                                )
                                            }
                                    )
                                )
                                .animation(.easeInOut(duration: 0.1), value: zoomScale)
                        }
                        .padding(8)
                    } else {
                        Text(viewModel.isStarted ? "Loading..." : "Awaiting Start")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.currentImage) { _, _ in
            // Reset to fully zoomed out (fit) when a new image loads
            zoomScale = 1.0
            baseZoomScale = 1.0
            contentOffset = .zero
            baseContentOffset = .zero
        }
    }
    
    private var ratingForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.categoryName)
                            .font(.system(size: 14, weight: .semibold))
                        Text("Evaluation Criteria: " + criteriaText(for: entry.categoryName))
                            .italic()
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            Text("Score")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Picker("Score", selection: bindingForScore(index)) {
                                ForEach(1...5, id: \.self) { val in Text("\(val)").tag(Optional(val)) }
                            }
                            .pickerStyle(.segmented)
                        }
                        TextEditor(text: bindingForNotes(index))
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Constants.Colors.cardBorder, lineWidth: 1)
                            )
                    }
                    .padding(12)
                    .background(Constants.Colors.cardBackground)
                    .cornerRadius(8)
                }
                overallSummary
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 360, maxWidth: 420)
    }

    private var overallSummary: some View {
        let total = viewModel.entries.reduce(0) { $0 + ( $1.score ?? 0 ) }
        let possible = max(viewModel.entries.count * 5, 1)
        let percent = Int((Double(total) / Double(possible) * 100.0).rounded())
        return HStack(spacing: 8) {
            Text("Overall Image Score")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("\(total)/\(possible)  (\(percent)%)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Constants.Colors.brandTint)
        }
    }
    
    private var footer: some View {
        HStack {
            Text(viewModel.statusMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { Task { await viewModel.back() } }) {
                HStack { Image(systemName: "chevron.left"); Text("Back") }
            }
            .disabled(!(viewModel.isStarted && viewModel.currentIndex > 0))
            Button(action: { Task { await viewModel.saveRatedJPG() } }) {
                HStack { Image(systemName: "square.and.arrow.down"); Text("Save Rated JPG") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isStarted)
            Button(action: { Task { await viewModel.next() } }) {
                HStack { Text("Next"); Image(systemName: "chevron.right") }
            }
            .disabled(!(viewModel.isStarted && viewModel.currentIndex + 1 < viewModel.copiedSampleURLs.count))
        }
        .padding()
        .background(Constants.Colors.cardBackground.opacity(0.5))
    }
    
    private var currentFileName: String {
        viewModel.currentURL?.lastPathComponent ?? ""
    }
    
    private func bindingForScore(_ index: Int) -> Binding<Int?> {
        Binding<Int?>(
            get: { viewModel.entries[index].score },
            set: { viewModel.entries[index].score = $0 }
        )
    }
    
    private func bindingForNotes(_ index: Int) -> Binding<String> {
        Binding<String>(
            get: { viewModel.entries[index].notes },
            set: { viewModel.entries[index].notes = $0 }
        )
    }

    private func criteriaText(for categoryName: String) -> String {
        let categories: [RatingCategory] = (viewModel.selectedMode == .sports) ? RatingPresets.sportsCategories : RatingPresets.schoolCategories
        return categories.first(where: { $0.name == categoryName })?.criteria ?? ""
    }
}


