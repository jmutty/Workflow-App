import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main App Entry
@main
struct PhotoProcessorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var jobManager = JobManager()
    @State private var selectedOperation: Operation?
    @State private var showingFolderPicker = false
    @State private var hoveredOperation: Operation?
    @State private var showingError = false
    @State private var errorContext: ErrorContext?
    
    var body: some View {
        ZStack {
            backgroundGradient
            
            VStack(spacing: 25) {
                headerSection
                folderSelectionSection
                
                if jobManager.jobFolderURL != nil {
                    operationsSection
                }
                
                Spacer()
                statusBar
            }
            .padding(.bottom)
        }
        .frame(minWidth: Constants.UI.minWindowWidth, minHeight: Constants.UI.minWindowHeight)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        .sheet(item: $selectedOperation) { operation in
            operationView(for: operation)
        }
        .alert("Error", isPresented: $showingError, presenting: errorContext) { context in
            ForEach(context.recoveryOptions, id: \.self) { option in
                Button(option.title) {
                    handleErrorRecovery(option, for: context)
                }
            }
        } message: { context in
            VStack {
                Text(context.error.localizedDescription)
                if let suggestion = context.error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                }
            }
        }
    }
    
    // MARK: - View Components
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Constants.Colors.primaryGradientStart.opacity(0.1),
                Constants.Colors.primaryGradientEnd.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "camera.aperture")
                    .font(.system(size: Constants.UI.largeIconSize))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Constants.Colors.primaryGradientStart, Constants.Colors.primaryGradientEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("207 Photo Workflow")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            
            Text("Professional Sports Photography Management")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.top, 20)
    }
    
    private var folderSelectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: Constants.UI.smallIconSize))
                    .foregroundColor(Constants.Colors.primaryGradientStart)
                Text("Job Folder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 12)
            
            HStack {
                folderInfoView
                Spacer()
                selectFolderButton
            }
            .padding(20)
            .background(Constants.Colors.cardBackground)
            .cornerRadius(Constants.UI.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                    .stroke(Constants.Colors.cardBorder, lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }
    
    private var folderInfoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let jobFolder = jobManager.jobFolderURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Constants.Colors.successGreen)
                        .font(.system(size: 20))
                    
                    Text(jobFolder.lastPathComponent)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Text(jobFolder.path)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .foregroundColor(Constants.Colors.warningOrange)
                        .font(.system(size: 20))
                    
                    Text("No folder selected")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Text("Select a job folder to begin")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }
    
    private var selectFolderButton: some View {
        Button(action: { showingFolderPicker = true }) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                Text("Select Folder")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Constants.Colors.primaryGradientStart, Constants.Colors.primaryGradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(Constants.UI.buttonCornerRadius)
        }
        .buttonStyle(.plain)
    }
    
    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: Constants.UI.smallIconSize))
                    .foregroundColor(Constants.Colors.primaryGradientStart)
                Text("Operations")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 2),
                spacing: 15
            ) {
                ForEach(Operation.allCases) { operation in
                    ModernOperationButton(
                        operation: operation,
                        status: jobManager.operationStatus[operation] ?? .ready,
                        isHovered: hoveredOperation == operation,
                        action: {
                            if jobManager.canStartOperation(operation) {
                                selectedOperation = operation
                            }
                        }
                    )
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: Constants.UI.animationDuration)) {
                            hoveredOperation = hovering ? operation : nil
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(jobManager.statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(jobManager.statusColor)
                            .frame(width: 8, height: 8)
                            .blur(radius: 4)
                    )
                
                Text(jobManager.statusMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("v2.0")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Constants.Colors.cardBackground.opacity(0.5))
    }
    
    // MARK: - Helper Methods
    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                do {
                    try jobManager.setJobFolder(url)
                } catch let error as PhotoWorkflowError {
                    showError(error, operation: "Select Folder")
                } catch {
                    showError(.accessDenied(path: error.localizedDescription), operation: "Select Folder")
                }
            }
        case .failure(let error):
            showError(.accessDenied(path: error.localizedDescription), operation: "Select Folder")
        }
    }
    
    private func showError(_ error: PhotoWorkflowError, operation: String, affectedFiles: [URL] = []) {
        errorContext = ErrorContext(
            error: error,
            operation: operation,
            affectedFiles: affectedFiles,
            recoveryOptions: [.retry, .cancel]
        )
        showingError = true
    }
    
    private func handleErrorRecovery(_ action: ErrorRecoveryAction, for context: ErrorContext) {
        switch action {
        case .retry:
            // Retry the operation
            if context.operation == "Select Folder" {
                showingFolderPicker = true
            }
        case .cancel:
            // Just dismiss
            break
        default:
            break
        }
    }
    
    @ViewBuilder
    private func operationView(for operation: Operation) -> some View {
        if let jobFolder = jobManager.jobFolderURL {
            switch operation {
            case .renameFiles:
                RenameFilesView(jobFolder: jobFolder, jobManager: jobManager)
            case .sortIntoTeams:
                SortIntoTeamsView(jobFolder: jobFolder, jobManager: jobManager)
            case .createSPACSV:
                CreateSPACSVView(jobFolder: jobFolder, jobManager: jobManager)
            case .sortTeamPhotos:
                SortTeamPhotosView(jobFolder: jobFolder, jobManager: jobManager)
            }
        } else {
            Text("No job folder selected")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Error Recovery Action Extension
extension ErrorRecoveryAction {
    var title: String {
        switch self {
        case .retry: return "Retry"
        case .skip: return "Skip"
        case .cancel: return "Cancel"
        case .useDefault: return "Use Default"
        case .createMissing: return "Create Missing"
        case .overwrite: return "Overwrite"
        case .rename: return "Rename"
        }
    }
}
