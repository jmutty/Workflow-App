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
                    swingSection
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        .onAppear { Task { await viewModel.initialize() } }
        .alert("Error", isPresented: $showingError) {}
        .preferredColorScheme(jobManager.colorScheme)
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Sort Into Teams").font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 8)
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
                                            .background(Constants.Colors.brandSoftFill)
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
                                    Image(systemName: "arrow.right").font(.caption).foregroundColor(Constants.Colors.brandTint)
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
                            Task {
                                jobManager.updateOperationStatus(.sortIntoTeams, status: .running(progress: nil))
                                await viewModel.executeSort(overwrite: viewModel.overwriteExisting)
                                jobManager.updateOperationStatus(.sortIntoTeams, status: .completed(Date()))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.teamPoseFiles.isEmpty && viewModel.coachFiles.isEmpty)
                        
                        if viewModel.lastSortOperationId != nil {
                            Button("Undo Last Sort") {
                                Task { await viewModel.undoLastSort() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var swingSection: some View {
        GroupBox("Swing Players") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.showSwingPrompt {
                    Text("It looks like there are swing players").font(.headline)
                    ForEach(viewModel.swingTeams, id: \.self) { swingTeam in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(swingTeam).font(.subheadline).fontWeight(.medium)
                            if let files = viewModel.swingFilesByTeam[swingTeam] {
                                let previews = files.prefix(5).map { $0.originalName }
                                ForEach(previews, id: \.self) { name in
                                    Text(name).font(.caption).foregroundColor(.secondary)
                                }
                                if files.count > 5 {
                                    Text("...and \(files.count - 5) more").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("Choose two teams:").font(.caption)
                                let suggested = viewModel.suggestedTeams(for: swingTeam)
                                Menu(viewModel.swingSelections[swingTeam]?.0 ?? (suggested.0 ?? "Select Team A")) {
                                    ForEach(viewModel.detectedTeams, id: \.self) { t in
                                        Button(t) { viewModel.updateSelection(for: swingTeam, firstTeam: t, secondTeam: viewModel.swingSelections[swingTeam]?.1) }
                                    }
                                }
                                Menu(viewModel.swingSelections[swingTeam]?.1 ?? (suggested.1 ?? "Select Team B")) {
                                    ForEach(viewModel.detectedTeams, id: \.self) { t in
                                        Button(t) { viewModel.updateSelection(for: swingTeam, firstTeam: viewModel.swingSelections[swingTeam]?.0, secondTeam: t) }
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Constants.Colors.surfaceElevated)
                        .cornerRadius(6)
                    }
                    HStack {
                        Spacer()
                        Button("Resolve Swing Players") {
                            Task { await viewModel.resolveSwingPlayers(applyToAll: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.hasCompleteSelections())
                    }
                } else {
                    Text("No swing players detected").foregroundColor(.secondary)
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
