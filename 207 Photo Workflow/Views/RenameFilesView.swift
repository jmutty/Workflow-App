import SwiftUI

// MARK: - Rename Files View (Sample Implementation)
struct RenameFilesView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: FileRenamerViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingPreview = false
    @State private var showingError = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []
    @State private var previewStartIndex: Int = 0
    @State private var showingConflictDialog = false
    @State private var showingValidationReport = false
    @State private var errorContext: ErrorContext?
    @State private var showingPreflight = false
    @State private var showingConflictDetails = false
    @State private var showAllSamples = false
    
    // Inline preflight edit state
    @State private var showingInlinePreflightFixes = false
    @State private var manualFixNames: [URL: String] = [:]
    @State private var csvToEditURL: URL?
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        self._viewModel = StateObject(wrappedValue: FileRenamerViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    configurationSection
                    validationSummarySection  // only shows if issues exist
                    if showingInlinePreflightFixes { preflightInlineFixes }
                    analysisSection
                }
                .padding()
            }

            Divider()

            // Persistent footer action bar
            HStack { actionButtons }
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .frame(minWidth: Constants.UI.renameWindowWidth,
               minHeight: Constants.UI.renameWindowHeight)
        .onAppear {
            Task { await viewModel.initialize() }
        }
        // Auto-collapse fixes panel when no issues or post-rename
        .onChange(of: (viewModel.validationReport?.errorCount ?? 0) + (viewModel.validationReport?.warningCount ?? 0)) { totalIssues in
            if totalIssues == 0 { showingInlinePreflightFixes = false }
        }
        .onChange(of: viewModel.lastRenameOperationId) { _ in
            // After successful rename, hide fixes if any were open
            showingInlinePreflightFixes = false
        }
        .sheet(isPresented: $showingPreview) {
            if let url = previewURL {
                ImagePreviewView(imageURL: url, allImageURLs: previewURLs.isEmpty ? nil : previewURLs, initialIndex: previewStartIndex)
            } else {
                Text("No file selected").frame(width: 400, height: 200)
            }
        }
        .sheet(isPresented: $showingPreflight) {
            if let report = viewModel.validationReport {
                PreflightValidationView(report: report) { showingPreflight = false }
            } else {
                Text("No report available").padding().frame(width: 400, height: 200)
            }
        }
        .sheet(isPresented: $showingValidationReport) {
            if let validation = viewModel.poseCountValidation {
                PoseCountValidationView(validation: validation) {
                    showingValidationReport = false
                }
            }
        }
        .sheet(isPresented: $showingError) {
            if let ctx = errorContext {
                ErrorDetailView(
                    title: "\(ctx.operation) Error",
                    message: ctx.error.localizedDescription,
                    suggestion: ctx.error.recoverySuggestion,
                    details: ctx.affectedFiles.map { $0.path }.joined(separator: "\n"),
                    onRetry: {
                        showingError = false
                        handleErrorRecovery(.retry, for: ctx)
                    }
                )
                .frame(width: 600, height: 360)
            } else {
                Text("No error context").frame(width: 400, height: 200)
            }
        }
        .sheet(isPresented: Binding(get: { csvToEditURL != nil }, set: { if !$0 { csvToEditURL = nil } })) {
            if let csvURL = csvToEditURL {
                CSVEditorView(
                    url: csvURL,
                    sourceFolderURL: viewModel.config.sourceFolder.url(in: jobFolder),
                    allImageURLs: viewModel.allImageURLsInSource(),
                    onPreview: { fileURL in
                        previewURLs = viewModel.allImageURLsInSource()
                        previewURL = fileURL
                        previewStartIndex = previewURLs.firstIndex(of: fileURL) ?? 0
                        showingPreview = true
                    },
                    onClose: {
                        csvToEditURL = nil
                        Task { await viewModel.reloadCSVAndReanalyze() }
                    }
                )
            } else {
                Text("No CSV").frame(width: 400, height: 200)
            }
        }
        .alert("Name Conflicts Detected", isPresented: $showingConflictDialog) {
            Button("Cancel") { }
            Button("View Details") { showingConflictDetails = true }
            Button("Skip Conflicts") {
                Task { await executeRename(handling: .skip) }
            }
            Button("Add Number Suffixes") {
                Task { await executeRename(handling: .addSuffix) }
            }
        } message: {
            Text("Found \(viewModel.conflictCount) naming conflicts. Click View Details to see which files conflict, preview them, and manually fix names if needed.")
        }
        .sheet(isPresented: $showingConflictDetails) {
            ConflictDetailsViewEnhanced(operations: viewModel.filesToRename.filter { $0.hasConflict }, viewModel: viewModel) {
                showingConflictDetails = false
            }
        }
    }
    
    // MARK: - View Sections
    private var headerSection: some View {
        VStack {
            Text("Rename Files")
                .font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var configurationSection: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 15) {
                sourceFolderPicker
                dataSourcePicker
                csvStatusIndicator
            }
            .padding()
        }
    }
    
    private var sourceFolderPicker: some View {
        VStack(alignment: .leading) {
            Text("Source Folder:")
                .font(.headline)
            Picker("Source", selection: $viewModel.config.sourceFolder) {
                ForEach(SourceFolder.allCases, id: \.self) { folder in
                    Text(folder.rawValue).tag(folder)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.config.sourceFolder) { _, _ in
                Task { await viewModel.analyzeFiles() }
            }
        }
    }
    
    private var dataSourcePicker: some View {
        VStack(alignment: .leading) {
            Text("Naming Source:")
                .font(.headline)
            Picker("Data Source", selection: $viewModel.config.dataSource) {
                ForEach(DataSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.hasCSV && viewModel.config.dataSource == .csv)
            .onChange(of: viewModel.config.dataSource) { _, _ in
                Task { await viewModel.analyzeFiles() }
            }
        }
    }
    
    private var csvStatusIndicator: some View {
        HStack {
            Image(systemName: viewModel.hasCSV ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(viewModel.hasCSV ? Constants.Colors.successGreen : Constants.Colors.errorRed)
            Text(viewModel.hasCSV ? "CSV file found" : "No CSV file found")
                .font(.caption)
        }
    }
    
    private var validationSummarySection: some View {
        Group {
            if let report = viewModel.validationReport,
               (report.errorCount + report.warningCount) > 0 {
                GroupBox("Preflight Validation") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("Errors: \(report.errorCount)")
                                .foregroundColor(report.errorCount > 0 ? Constants.Colors.errorRed : .secondary)
                            Text("Warnings: \(report.warningCount)")
                                .foregroundColor(report.warningCount > 0 ? Constants.Colors.warningOrange : .secondary)
                            if let req = report.requiredDiskSpace, let avail = report.availableDiskSpace {
                                Text("Backup size: \(formatBytes(req)) / Free: \(formatBytes(avail))")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Details") { showingPreflight = true }
                                .buttonStyle(.bordered)
                            Button(showingInlinePreflightFixes ? "Hide Fixes" : "Fix Issues") {
                                showingInlinePreflightFixes.toggle()
                                if showingInlinePreflightFixes {
                                    manualFixNames = [:]
                                    for url in viewModel.findInvalidFilenameURLs() {
                                        manualFixNames[url] = viewModel.sanitizedName(for: url.lastPathComponent)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
    
    private var preflightInlineFixes: some View {
        GroupBox("Fix Preflight Issues") {
            VStack(alignment: .leading, spacing: 12) {
                // Invalid filenames
                let invalids = viewModel.findInvalidFilenameURLs()
                if !invalids.isEmpty {
                    Text("Invalid filenames (") + Text("\(invalids.count)").bold() + Text(")")
                    ForEach(invalids, id: \.self) { url in
                        HStack(spacing: 8) {
                            ThumbnailTitleRow(url: url, title: url.lastPathComponent) {
                                previewURLs = viewModel.allImageURLsInSource()
                                previewURL = url
                                previewStartIndex = previewURLs.firstIndex(of: url) ?? 0
                                showingPreview = true
                            }
                            Text("→").foregroundColor(.secondary)
                            TextField("New name", text: Binding(
                                get: { manualFixNames[url] ?? viewModel.sanitizedName(for: url.lastPathComponent) },
                                set: { manualFixNames[url] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                            Button("Rename") {
                                let newName = (manualFixNames[url] ?? viewModel.sanitizedName(for: url.lastPathComponent)).trimmingCharacters(in: .whitespaces)
                                do {
                                    _ = try viewModel.renameOnDisk(url: url, to: newName)
                                    Task { await viewModel.analyzeFiles() }
                                } catch {
                                    errorContext = ErrorContext(error: .unableToWriteFile(path: url.path, underlyingError: error), operation: "Fix Invalid Filename", affectedFiles: [url], recoveryOptions: [.cancel])
                                    showingError = true
                                }
                            }
                            .buttonStyle(.bordered)
                            Button("Skip") {
                                do {
                                    let newURL = try viewModel.skipFileOnDisk(url)
                                    viewModel.skipURLInMemory(newURL)
                                    Task { await viewModel.analyzeFiles() }
                                } catch {
                                    errorContext = ErrorContext(error: .unableToWriteFile(path: url.path, underlyingError: error), operation: "Skip File", affectedFiles: [url], recoveryOptions: [.cancel])
                                    showingError = true
                                }
                            }
                            .buttonStyle(.bordered)
                            Button("Add to CSV") {
                                Task {
                                    do {
                                        let base = url.deletingPathExtension().lastPathComponent
                                        // Attempt to split into first/last by last space; user can edit later in CSV
                                        let parts = base.split(separator: " ")
                                        let first = parts.first.map(String.init) ?? base
                                        let last = parts.dropFirst().joined(separator: " ")
                                        let group = jobFolder.lastPathComponent
                                        try await viewModel.appendToCSV(original: url.lastPathComponent, firstName: first, lastName: last, groupName: group)
                                        await viewModel.analyzeFiles()
                                    } catch {
                                        errorContext = ErrorContext(error: .unableToWriteFile(path: jobFolder.path, underlyingError: error), operation: "Add to CSV", affectedFiles: [url], recoveryOptions: [.cancel])
                                        showingError = true
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .font(.caption)
                    }
                }
                
                // Unmatched CSV images
                if viewModel.config.dataSource == .csv {
                    let unmatched = viewModel.findUnmatchedCSVImageURLs()
                    if !unmatched.isEmpty {
                        Divider()
                        Text("Not in CSV (") + Text("\(unmatched.count)").bold() + Text(")")
                        ForEach(unmatched, id: \.self) { url in
                            HStack(spacing: 8) {
                                ThumbnailTitleRow(url: url, title: url.lastPathComponent) {
                                    previewURLs = viewModel.allImageURLsInSource()
                                    previewURL = url
                                    previewStartIndex = previewURLs.firstIndex(of: url) ?? 0
                                    showingPreview = true
                                }
                                Spacer()
                                Button("Skip") {
                                    do {
                                        let newURL = try viewModel.skipFileOnDisk(url)
                                        viewModel.skipURLInMemory(newURL)
                                        Task { await viewModel.analyzeFiles() }
                                    } catch {
                                        errorContext = ErrorContext(error: .unableToWriteFile(path: url.path, underlyingError: error), operation: "Skip File", affectedFiles: [url], recoveryOptions: [.cancel])
                                        showingError = true
                                    }
                                }
                                .buttonStyle(.bordered)
                                Button("Add to CSV") {
                                    Task {
                                        do {
                                            let base = url.deletingPathExtension().lastPathComponent
                                            let parts = base.split(separator: " ")
                                            let first = parts.first.map(String.init) ?? base
                                            let last = parts.dropFirst().joined(separator: " ")
                                            let group = jobFolder.lastPathComponent
                                            try await viewModel.appendToCSV(original: url.lastPathComponent, firstName: first, lastName: last, groupName: group)
                                            await viewModel.analyzeFiles()
                                            if let csvURL = viewModel.currentCSVURL {
                                                csvToEditURL = csvURL
                                            }
                                        } catch {
                                            errorContext = ErrorContext(error: .unableToWriteFile(path: jobFolder.path, underlyingError: error), operation: "Add to CSV", affectedFiles: [url], recoveryOptions: [.cancel])
                                            showingError = true
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
    
    private var analysisSection: some View {
        Group {
            if viewModel.isAnalyzing {
                DetailedProgressView(
                    progress: viewModel.operationProgress,
                    currentFile: extractFileName(viewModel.currentOperation),
                    filesCompleted: Int(viewModel.operationProgress * 100),
                    totalFiles: 100,
                    status: viewModel.currentOperation.isEmpty ? "Analyzing files..." : viewModel.currentOperation,
                    etaText: nil,
                    onCancel: {
                        Task { await viewModel.cancelOperation() }
                    }
                )
                .padding(.horizontal)
            } else if !viewModel.filesToRename.isEmpty {
                analysisResultsView
            } else {
                emptyStateView
            }
        }
    }
    
    private var analysisResultsView: some View {
        GroupBox("Analysis Results") {
            VStack(alignment: .leading, spacing: 10) {
                summaryHeader
                
                if let validation = viewModel.poseCountValidation {
                    Divider()
                    validationStatus(validation)
                }
                
                if viewModel.filesToRename.count > 0 {
                    Divider()
                    sampleRenames
                }
            }
            .padding()
        }
    }
    
    private var summaryHeader: some View {
        HStack {
            Text("Files to rename: \(viewModel.filesToRename.count)")
                .font(.headline)
            
            if viewModel.hasConflicts {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Constants.Colors.warningOrange)
                    Button("\(viewModel.conflictCount) conflicts") { showingConflictDetails = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            
            Spacer()
        }
    }
    
    private func validationStatus(_ validation: PoseCountValidation) -> some View {
        HStack(spacing: 8) {
            if validation.hasIssues {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Constants.Colors.warningOrange)
                Text("\(validation.issueCount) player(s) have pose count issues")
                    .font(.caption)
                    .foregroundColor(Constants.Colors.warningOrange)
                Spacer()
                Button("Review Issues") {
                    showingValidationReport = true
                }
                .buttonStyle(.bordered)
                .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Constants.Colors.successGreen)
                Text("All players have consistent pose counts")
                    .font(.caption)
            }
        }
    }
    
    private var sampleRenames: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample renames:")
                .font(.subheadline)
                .fontWeight(.medium)
            
            let list = showAllSamples ? viewModel.filesToRename : Array(viewModel.filesToRename.prefix(5))
            ForEach(list) { operation in
                HStack {
                    ThumbnailTitleRow(url: operation.sourceURL, title: operation.originalName) {
                        previewURLs = viewModel.filesToRename.map { $0.sourceURL }
                        previewURL = operation.sourceURL
                        previewStartIndex = previewURLs.firstIndex(of: operation.sourceURL) ?? 0
                        showingPreview = true
                    }
                    .buttonStyle(.plain)
                    
                    Image(systemName: "arrow.right")
                        .foregroundColor(.blue)
                    
                    Text(operation.newName)
                        .fontWeight(.medium)
                        .foregroundColor(operation.hasConflict ? Constants.Colors.warningOrange : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            if operation.hasConflict {
                                Button("View Conflict Details") { showingConflictDetails = true }
                            }
                        }
                    
                    if operation.hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Constants.Colors.warningOrange)
                            .font(.caption)
                            .help("A file with this new name already exists in the folder.")
                    }
                }
                .font(.caption)
            }
            
            if viewModel.filesToRename.count > 5 {
                Button(showAllSamples ? "Show less" : "... and \(viewModel.filesToRename.count - 5) more") {
                    withAnimation { showAllSamples.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack {
            Text("No files to rename")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Click 'Analyze Files' to scan for images")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 100)
    }
    
    private var actionButtons: some View {
        HStack(spacing: 15) {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)
            
            Button("Analyze Files") {
                Task { await viewModel.analyzeFiles() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isAnalyzing)
            
            if let csvURL = viewModel.currentCSVURL {
                Button("Open CSV Editor") {
                    csvToEditURL = csvURL
                }
                .buttonStyle(.bordered)
            }

            if !viewModel.filesToRename.isEmpty {
                if viewModel.isRenaming {
                    DetailedProgressView(
                        progress: viewModel.operationProgress,
                        currentFile: extractFileName(viewModel.currentOperation),
                        filesCompleted: Int(viewModel.operationProgress * Double(viewModel.filesToRename.count)),
                        totalFiles: viewModel.filesToRename.count,
                        status: viewModel.currentOperation.isEmpty ? "Renaming files..." : viewModel.currentOperation,
                        etaText: estimateTimeRemaining(),
                        onCancel: {
                            Task { await viewModel.cancelOperation() }
                        }
                    )
                    .frame(maxWidth: 400)
                } else {
                    Button("Execute Rename") {
                        if viewModel.hasConflicts {
                            showingConflictDialog = true
                        } else {
                            Task { await executeRename() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(viewModel.isRenaming)
                }
            }
            
            if viewModel.lastRenameOperationId != nil {
                Button("Undo Last Rename") {
                    Task { await viewModel.undoLastRename() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    // MARK: - Helper Methods
    private func extractFileName(_ operation: String) -> String? {
        let components = operation.components(separatedBy: " ")
        return components.first(where: { $0.contains(".") })
    }
    
    private func estimateTimeRemaining() -> String? {
        guard viewModel.operationProgress > 0.1 else { return nil }
        let remaining = (1.0 - viewModel.operationProgress) / viewModel.operationProgress
        let seconds = Int(remaining * 10)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
    }
    
    private func executeRename(handling: OperationConfig.RenameConfig.ConflictHandling = .skip) async {
        viewModel.config.handleConflicts = handling
        
        do {
            try await viewModel.executeRenames()
            jobManager.updateOperationStatus(.renameFiles, status: .completed(Date()))
        } catch let error as PhotoWorkflowError {
            showError(error)
        } catch {
            showError(.unableToWriteFile(path: "Multiple files", underlyingError: error))
        }
    }
    
    private func showError(_ error: PhotoWorkflowError) {
        errorContext = ErrorContext(
            error: error,
            operation: "Rename Files",
            affectedFiles: viewModel.filesToRename.map { $0.sourceURL },
            recoveryOptions: [.retry, .cancel]
        )
        showingError = true
    }
    
    private func handleErrorRecovery(_ action: ErrorRecoveryAction, for context: ErrorContext) {
        switch action {
        case .retry:
            Task { await viewModel.analyzeFiles() }
        case .cancel:
            break
        default:
            break
        }
    }
}

// MARK: - Enhanced Conflict Details View with previews and manual fix
private struct ConflictDetailsViewEnhanced: View {
    let operations: [RenameOperation]
    @ObservedObject var viewModel: FileRenamerViewModel
    let onDismiss: () -> Void
    
    @State private var selectedOp: RenameOperation?
    @State private var manualName: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conflict Details").font(.title2).bold()
                Spacer()
                Button("Close", action: onDismiss).buttonStyle(.bordered)
            }
            Divider()
            if operations.isEmpty {
                Text("No conflicts to show.")
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 16) {
                    // Left: list of conflicting ops
                    List(operations) { op in
                        HStack(spacing: 8) {
                            ThumbnailTitleRow(url: op.sourceURL, title: op.originalName, onTap: {
                                selectedOp = op
                                manualName = op.newName
                            })
                        }
                    }
                    .frame(minWidth: 280)
                    
                    // Right: details and previews
                    VStack(alignment: .leading, spacing: 12) {
                        if let op = selectedOp ?? operations.first {
                            Text("Original → New")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                Text(op.originalName)
                                    .font(.system(.caption, design: .monospaced))
                                Image(systemName: "arrow.right")
                                Text(op.newName)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(Constants.Colors.warningOrange)
                            }
                            
                            Text("Reason: A file named '\(op.newName)' already exists in the folder.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            // Previews (current source + existing conflicting file if any)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text("Current")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    ThumbnailTitleRow(url: op.sourceURL, title: "") {}
                                }
                                if let existing = viewModel.existingFileURL(for: op) {
                                    VStack(alignment: .leading) {
                                        Text("Existing")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        ThumbnailTitleRow(url: existing, title: "") {}
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Text("Manually fix new name")
                                .font(.subheadline)
                            HStack(spacing: 8) {
                                TextField("New file name", text: $manualName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 320)
                                Button("Apply") {
                                    guard !manualName.isEmpty, viewModel.isValidFileName(manualName) else { return }
                                    viewModel.updateNewName(for: op.sourceURL, to: manualName)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .help("Enter a unique, valid filename including extension (e.g., Player Name_3.JPG)")
                        } else {
                            Text("Select a conflict to view details")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .frame(minWidth: 380)
                }
                .frame(minHeight: 360)
            }
        }
        .padding()
        .frame(width: 820, height: 520)
    }
}

// MARK: - Pose Count Validation View (Simplified)
struct PoseCountValidationView: View {
    let validation: PoseCountValidation
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Pose Count Validation")
                .font(.title2)
                .fontWeight(.semibold)
            
            if validation.hasIssues {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(validation.playersWithIssues, id: \.player) { issue in
                            HStack {
                                Text(issue.player)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(issue.count) poses")
                                    .font(.caption)
                                Text(validation.issueType(for: issue.count).description)
                                    .font(.caption)
                                    .foregroundColor(Constants.Colors.warningOrange)
                            }
                            Divider()
                        }
                    }
                    .padding()
                }
            } else {
                Text("All players have the expected \(validation.expectedCount) poses")
                    .foregroundColor(Constants.Colors.successGreen)
            }
            
            Button("Close") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .padding()
        .frame(width: 650, height: 600)
    }
}

// MARK: - Preflight Validation Details
struct PreflightValidationView: View {
    let report: ValidationReport
    let onDismiss: () -> Void
    
    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preflight Validation Details")
                    .font(.title2).bold()
                Spacer()
                Button("Close") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            if let req = report.requiredDiskSpace, let avail = report.availableDiskSpace {
                Text("Backup estimate: \(formatBytes(req)) • Free: \(formatBytes(avail))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(color(for: issue.severity))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.message)
                                if let suggestion = issue.suggestion {
                                    Text(suggestion)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .padding()
        .frame(width: 650, height: 500)
    }
    
    private func color(for severity: ValidationSeverity) -> Color {
        switch severity {
        case .error: return Constants.Colors.errorRed
        case .warning: return Constants.Colors.warningOrange
        case .info: return .secondary
        }
    }
}

// MARK: - Placeholder Views removed (migrated to dedicated files)
