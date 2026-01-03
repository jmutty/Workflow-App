import SwiftUI

struct RebuildSMOnlyView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: RebuildSMOnlyViewModel
    @State private var showingCSVEditor = false
    @State private var showingImagePreview = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: RebuildSMOnlyViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Re-Build: SMs Only")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Constants.Colors.textPrimary)
                Spacer()
            }
            .padding(.bottom, 4)
            
            Text(jobFolder.path)
                .font(.system(size: 12))
                .foregroundColor(Constants.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Divider()
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Teams")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Constants.Colors.textPrimary)
                    List(selection: $viewModel.selectedTeams) {
                        ForEach(viewModel.availableTeams, id: \.self) { team in
                            Text(team)
                        }
                    }
                    .frame(minWidth: 240, maxHeight: 260)
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global SM FIX Template")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Constants.Colors.textPrimary)
                    HStack {
                        Image(systemName: "doc.richtext")
                        TextField("Template file name", text: $viewModel.globalSMFixTemplateName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }
                    
                    HStack(spacing: 10) {
                        Button {
                            Task { await viewModel.build() }
                        } label: {
                            HStack {
                                Image(systemName: "hammer")
                                Text(viewModel.isProcessing ? "Building…" : "Build")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isProcessing || viewModel.selectedTeams.isEmpty)
                    }
                    
                    if let err = viewModel.lastError, !err.isEmpty {
                        Text(err)
                            .foregroundColor(Constants.Colors.errorRed)
                            .font(.system(size: 12))
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .preferredColorScheme(jobManager.colorScheme)
        .task {
            await viewModel.analyze()
        }
        .sheet(isPresented: $viewModel.showSummary) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Constants.Colors.successGreen)
                    Text("SMs Only: Complete")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Constants.Colors.textPrimary)
                }
                Divider()
                Text("Teams processed: \(viewModel.selectedTeams.count)")
                    .foregroundColor(Constants.Colors.textSecondary)
                Text("Files moved: \(viewModel.lastFilesMoved)")
                    .foregroundColor(Constants.Colors.textSecondary)
                Text("Files copied: \(viewModel.lastFilesCopied)")
                    .foregroundColor(Constants.Colors.textSecondary)
                Text("CSV rows: \(viewModel.lastCsvRows)")
                    .foregroundColor(Constants.Colors.textSecondary)
                Text("Teams with new group photos: \(viewModel.lastTeamsWithNewPhotos)")
                    .foregroundColor(Constants.Colors.textSecondary)
                HStack {
                    if let csv = viewModel.resultCSVURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([csv])
                        } label: {
                            HStack { Image(systemName: "doc.text"); Text("Show CSV in Finder") }
                        }
                    }
                    if let root = viewModel.remakeRootURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        } label: {
                            HStack { Image(systemName: "folder"); Text("Show Remake Folder") }
                        }
                    }
                    Spacer()
                    Button("Done") { viewModel.showSummary = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 520)
        }
    }
    
    
}


