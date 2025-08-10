import SwiftUI

struct SortIntoTeamsView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: SortIntoTeamsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingError = false
    @State private var errorContext: ErrorContext?
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: SortIntoTeamsViewModel(jobFolder: jobFolder))
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
        .onAppear { Task { await viewModel.initialize() } }
        .alert("Error", isPresented: $showingError) {}
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Sort Into Teams").font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline).foregroundColor(.secondary)
        }.padding(.top, 8)
    }
    
    private var configuration: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Team pose number:").font(.headline)
                    TextField("Pose", text: $viewModel.selectedPose)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("(e.g., 1, 2, 3)").font(.caption).foregroundColor(.secondary)
                }
                Toggle("Copy team pose files (off = move)", isOn: $viewModel.copyTeamPhotos)
                Toggle("Move coach files and add 'TOP ' prefix", isOn: $viewModel.processCoachFiles)
                Toggle("Create team folders if needed", isOn: $viewModel.createTeamFolders)
                Toggle("Include subfolders", isOn: $viewModel.includeSubfolders)
                Toggle("Overwrite existing files", isOn: $viewModel.overwriteExisting)
                HStack {
                    Spacer()
                    Button("Re-Analyze") { Task { await viewModel.analyze() } }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }
    
    private var analysisSection: some View {
        GroupBox("Analysis") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isSorting {
                    DetailedProgressView(
                        progress: viewModel.operationProgress,
                        currentFile: viewModel.currentOperation,
                        filesCompleted: Int(viewModel.operationProgress * Double(max(viewModel.teamPoseFiles.count + viewModel.coachFiles.count, 1))),
                        totalFiles: max(viewModel.teamPoseFiles.count + viewModel.coachFiles.count, 1),
                        status: "Sorting files...",
                        etaText: nil,
                        onCancel: { viewModel.cancelSort() }
                    )
                } else {
                    if !viewModel.summaryMessage.isEmpty {
                        Text(viewModel.summaryMessage).foregroundColor(.secondary)
                    }
                    if !viewModel.detectedTeams.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Teams: \(viewModel.detectedTeams.count)")
                                .font(.headline)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                                ForEach(viewModel.detectedTeams, id: \.self) { team in
                                    let count = viewModel.teamPoseCounts[team] ?? 0
                                    HStack(spacing: 6) {
                                        Text(team).font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(4)
                                        if count > 0 { Text("(\(count))").font(.caption2).foregroundColor(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                    if !viewModel.coachFiles.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Coach files: \(viewModel.coachFiles.count)")
                                .font(.subheadline).fontWeight(.medium)
                            ForEach(Array(viewModel.coachFiles.prefix(3)), id: \.originalName) { coach in
                                HStack {
                                    Text(coach.originalName).font(.caption).foregroundColor(.secondary)
                                    Image(systemName: "arrow.right").font(.caption).foregroundColor(.blue)
                                    Text("\(coach.teamName)/\(coach.newName ?? coach.originalName)").font(.caption).fontWeight(.medium)
                                }
                            }
                            if viewModel.coachFiles.count > 3 {
                                Text("... and \(viewModel.coachFiles.count - 3) more").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Execute Sort") {
                            Task { await viewModel.executeSort(overwrite: viewModel.overwriteExisting) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.teamPoseFiles.isEmpty && viewModel.coachFiles.isEmpty)
                    }
                }
            }
            .padding()
        }
    }
    
    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
