import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main App Entry
@main
struct PhotoProcessorApp: App {
    @StateObject private var jobManager = JobManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.mainWindowWidth, height: Constants.UI.mainWindowHeight)
        // Additional titled windows for each operation
        WindowGroup("Rename Files", id: "rename") {
            RenameWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.renameWindowWidth, height: Constants.UI.renameWindowHeight)
        WindowGroup("Sort Into Teams", id: "sortIntoTeams") {
            SortIntoTeamsWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        WindowGroup("Create SPA-Ready CSV", id: "createSPACSV") {
            CreateSPACSVWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        WindowGroup("Create Senior Banner CSV", id: "createSeniorBannersCSV") {
            CreateSeniorBannersCSVWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        WindowGroup("Sort Team & Alt Background PNGs", id: "sortTeamPhotos") {
            SortTeamPhotosWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        WindowGroup("Admin Mode", id: "adminMode") {
            AdminModeWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        WindowGroup("Re-Build: Full Teams (Ind & SM)", id: "rebuildFullTeams") {
            RebuildFullTeamsWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        WindowGroup("Re-Build: SMs Only", id: "rebuildSmOnly") {
            RebuildSMOnlyWindowView()
                .environmentObject(jobManager)
        }
        .defaultSize(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject private var jobManager: JobManager
    @State private var showingFolderPicker = false
    @State private var hoveredOperation: Operation?
    @State private var showingError = false
    @State private var errorContext: ErrorContext?
    @Environment(\.openWindow) private var openWindow
    
    private enum AppMode: String, CaseIterable, Identifiable {
        case sports = "Sports"
        case school = "School"
        case seniorBanners = "Senior Banners"
        case rebuild = "Re-Build"
        var id: String { rawValue }
    }
    @State private var selectedMode: AppMode = .sports
    
    var body: some View {
        ZStack {
            backgroundGradient
            
            VStack(spacing: 25) {
                UpdateBannerView()
                    .padding(.horizontal)
                    
                headerSection
                folderSelectionSection
                
                if jobManager.jobFolderURL != nil {
                    ScrollView {
                        operationsSection
                            .padding(.bottom, 8)
                    }
                    .frame(maxHeight: .infinity)
                }
                statusBar
            }
            .padding(.bottom)
            .onAppear {
                UpdateService.shared.checkForUpdates()
            }

            // Tiny Admin Mode button in bottom-right
            if jobManager.jobFolderURL != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: { openWindow(id: "adminMode") }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Constants.Colors.brandTint)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Constants.Colors.focusRing, lineWidth: 1)
                                )
                                .help("Admin Mode")
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .tint(Constants.Colors.brandTint)
        .frame(minWidth: Constants.UI.minWindowWidth, minHeight: Constants.UI.minWindowHeight)
        .preferredColorScheme(jobManager.colorScheme)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        // Operation views open in native titled windows via openWindow
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
                Color(NSColor.windowBackgroundColor),
                Color(NSColor.windowBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ).ignoresSafeArea()
    }
    
    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "camera.aperture")
                    .font(.system(size: Constants.UI.largeIconSize))
                    .foregroundStyle(Constants.Colors.brandTint)
                
                Text("207 Photo Workflow")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
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
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Job Folder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: jobManager.appearanceIsDark ? "moon.fill" : "sun.max.fill")
                        .foregroundColor(.secondary)
                    Toggle(jobManager.appearanceIsDark ? "Dark Mode" : "Light Mode", isOn: $jobManager.appearanceIsDark)
                        .toggleStyle(.switch)
                }
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
            .background(Constants.Colors.brandTint)
            .cornerRadius(Constants.UI.buttonCornerRadius)
        }
        .buttonStyle(.plain)
    }
    
    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: Constants.UI.smallIconSize))
                            .foregroundColor(Constants.Colors.brandTint)
                        Text("Operations")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(AppMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: Constants.UI.smallIconSize))
                            .foregroundColor(Constants.Colors.brandTint)
                        Text("Operations")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(AppMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }
            }
            
            Group {
                if selectedMode == .sports {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 2),
                        spacing: 15
                    ) {
                        ForEach(Operation.allCases.filter { $0 != .adminMode && $0 != .createSeniorBannersCSV }) { operation in
                            ModernOperationButton(
                                operation: operation,
                                status: jobManager.operationStatus[operation] ?? .ready,
                                isHovered: hoveredOperation == operation,
                                action: {
                                    if jobManager.canStartOperation(operation) {
                                        switch operation {
                                        case .renameFiles: openWindow(id: "rename")
                                        case .sortIntoTeams: openWindow(id: "sortIntoTeams")
                                        case .createSPACSV: openWindow(id: "createSPACSV")
                                        case .createSeniorBannersCSV: openWindow(id: "createSeniorBannersCSV")
                                        case .sortTeamPhotos: openWindow(id: "sortTeamPhotos")
                                        case .adminMode: break
                                        }
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
                } else if selectedMode == .school {
                    SchoolModeView(jobFolder: jobManager.jobFolderURL!, jobManager: jobManager)
                } else if selectedMode == .seniorBanners {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 2),
                        spacing: 15
                    ) {
                        ForEach([Operation.createSeniorBannersCSV]) { operation in
                            ModernOperationButton(
                                operation: operation,
                                status: jobManager.operationStatus[operation] ?? .ready,
                                isHovered: hoveredOperation == operation,
                                action: {
                                    if jobManager.canStartOperation(operation) {
                                        openWindow(id: "createSeniorBannersCSV")
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
                } else {
                    RebuildModeView()
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
                print("📁 Selected folder: \(url.path)")
                print("📁 Security scoped: \(url.hasDirectoryPath)")
                
                do {
                    try jobManager.setJobFolder(url)
                    print("✅ Successfully set job folder")
                } catch let error as PhotoWorkflowError {
                    print("❌ PhotoWorkflowError: \(error)")
                    showError(error, operation: "Select Folder")
                } catch {
                    print("❌ Generic error: \(error)")
                    showError(.accessDenied(path: error.localizedDescription), operation: "Select Folder")
                }
            }
        case .failure(let error):
            print("❌ Folder selection failed: \(error)")
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
    
    // Operation windows are defined at the App scene level
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

// MARK: - Operation Window Wrapper Views
struct RenameWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            RenameWizardView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(minWidth: Constants.UI.renameWindowWidth, minHeight: Constants.UI.renameWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(minWidth: Constants.UI.renameWindowWidth, minHeight: Constants.UI.renameWindowHeight)
        }
    }
}

struct SortIntoTeamsWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            SortIntoTeamsView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        }
    }
}

struct CreateSPACSVWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            CreateSPACSVView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        }
    }
}

struct CreateSeniorBannersCSVWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            CreateSeniorBannersCSVView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        }
    }
}

struct SortTeamPhotosWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            SortTeamPhotosView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        }
    }
}

struct AdminModeWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            AdminModeView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        }
    }
}

struct RebuildFullTeamsWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            RebuildFullTeamsView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        }
    }
}

struct RebuildSMOnlyWindowView: View {
    @EnvironmentObject var jobManager: JobManager
    var body: some View {
        if let jobFolder = jobManager.jobFolderURL {
            RebuildSMOnlyView(jobFolder: jobFolder, jobManager: jobManager)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        } else {
            Text("No job folder selected").foregroundColor(.secondary)
                .frame(width: Constants.UI.sortWindowWidth, height: Constants.UI.sortWindowHeight)
        }
    }
}
