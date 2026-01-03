import SwiftUI

struct SortTeamPhotosView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: SortTeamPhotosViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingError = false
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: SortTeamPhotosViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configuration
                    analysisSection
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        .onAppear { Task { await runAnalyze() } }
        .sheet(isPresented: $showingError) {
            ErrorDetailView(
                title: "Sort Team & Alt Background PNGs Error",
                message: viewModel.lastError ?? "Unknown error",
                suggestion: "Check folder structure and permissions, then try again.",
                details: nil,
                onRetry: { showingError = false }
            )
            .frame(width: 600, height: 360)
        }
        .preferredColorScheme(jobManager.colorScheme)
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Sort Team & Alt Background PNGs").font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
    
    private var configuration: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Source:").font(.headline)
                    Text("\(Constants.Folders.finishedTeams)")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Destination:").font(.headline)
                    Text("\(Constants.Folders.forUpload)/<Team>/\(Constants.Folders.group)/<file>")
                        .font(.subheadline).monospaced()
                }
                Toggle("Overwrite existing files", isOn: $viewModel.overwriteExisting)
                Toggle("Create team folders if needed", isOn: $viewModel.createMissingFolders)
            }
            .padding()
        }
    }
    
    private var analysisSection: some View {
        GroupBox("Analysis Results") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isAnalyzing {
                    ProgressView("Scanning \(Constants.Folders.finishedTeams)...")
                        .frame(height: 120)
                } else if viewModel.analysisReady {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Teams detected: \(viewModel.detectedTeams.count)").font(.headline)
                            Text("Team photos found: \(viewModel.foundFiles.count)").font(.subheadline)
                        }
                        Spacer()
                    }
                    if !viewModel.detectedTeams.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Teams:").font(.subheadline).fontWeight(.medium)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                                ForEach(viewModel.detectedTeams.sorted(), id: \.self) { team in
                                    let count = viewModel.foundFiles.filter { $0.teamName == team }.count
                                    HStack(spacing: 6) {
                                        Text(team).font(.caption)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(Constants.Colors.brandSoftFill).cornerRadius(4)
                                        Text("(\(count))").font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !viewModel.foundFiles.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sample:").font(.subheadline).fontWeight(.medium)
                            ForEach(Array(viewModel.foundFiles.prefix(5)), id: \.sourceURL) { item in
                                Text("\(item.teamName)/\(item.sourceURL.lastPathComponent)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if viewModel.foundFiles.count > 5 {
                                Text("... and \(viewModel.foundFiles.count - 5) more")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    VStack {
                        Text("No finished team photos found yet")
                            .foregroundColor(.secondary)
                        Text("Click 'Analyze' to scan the '\(Constants.Folders.finishedTeams)' folder")
                            .font(.caption).foregroundColor(.secondary)
                    }.frame(height: 120)
                }
            }
            .padding()
        }
    }
    
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
            Button("Analyze") { Task { await runAnalyze() } }
                .buttonStyle(.bordered)
                .disabled(viewModel.isAnalyzing)
            if viewModel.analysisReady && !viewModel.foundFiles.isEmpty {
                Button("Sort Team & Alt Background PNGs") {
                    Task { await runExecute() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(viewModel.isMoving)
            }
        }
        .padding()
    }

    // MARK: - Ops with JobManager status + error handling
    private func runAnalyze() async {
        jobManager.updateOperationStatus(.sortTeamPhotos, status: .running(progress: nil))
        let ok = await viewModel.analyze()
        if ok {
            jobManager.updateOperationStatus(.sortTeamPhotos, status: .completed(Date()))
        } else {
            let err = viewModel.lastError ?? "Analyze failed"
            jobManager.updateOperationStatus(.sortTeamPhotos, status: .error(err))
            showingError = true
        }
    }
    
    private func runExecute() async {
        jobManager.updateOperationStatus(.sortTeamPhotos, status: .running(progress: nil))
        let ok = await viewModel.executeMove()
        if ok {
            jobManager.updateOperationStatus(.sortTeamPhotos, status: .completed(Date()))
            dismiss()
        } else {
            let err = viewModel.lastError ?? "Move failed"
            jobManager.updateOperationStatus(.sortTeamPhotos, status: .error(err))
            showingError = true
        }
    }
}


