import SwiftUI
import AppKit

// Removed complex preview modes - keeping it simple

// MARK: - Issues Resolution Step View
struct RenameIssuesStepView: View {
    @ObservedObject var coordinator: RenameWizardCoordinator
    
    @State private var selectedIssue: IssueItem?
    @State private var selectedImageIndex: Int = 0
    @State private var issueImageSelections: [String: Int] = [:] // Track selection per issue
    @State private var showingImagePreviewSheet: Bool = false
    @State private var errorContext: ErrorContext?
    @State private var showingError = false
    // Resolved issues are now managed by the coordinator for persistence
    @State private var showingFixOptionsMenu = false
    @State private var issueToFix: IssueItem?
    @State private var capturedIssueForSheet: IssueItem? // Backup reference
    @State private var sheetIssue: IssueItem? // Direct sheet item
    @State private var metadataEditorIssue: IssueItem? // Direct item for metadata editor
    @State private var pendingScrollToId: String? = nil
    @State private var pendingNextIssueId: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            issuesHeader
            
            Divider()
            
            if hasAnyIssues {
                // Main split view
                HStack(spacing: 0) {
                    // Issues list (left)
                    issuesListView
                        .frame(minWidth: 400, maxWidth: 450)
                    
                Divider()
                
                    // Preview and details (right)
                    previewAndDetailsView
                        .frame(minWidth: 500)
                }
            } else {
                noIssuesView
            }
        }
        .alert("Error", isPresented: $showingError, presenting: errorContext) { context in
            Button("OK") { }
        } message: { context in
            Text(context.error.localizedDescription)
        }
        .background(
            KeyCatcher { keyCode in
                handleKeyPressWithCode(keyCode)
            }
            .allowsHitTesting(false)
        )
        .focusable(true)
        .onTapGesture {
            // Force focus when user clicks anywhere
        }
        .onAppear {
            coordinator.updateFromViewModel()
            // Auto-select first issue
            if selectedIssue == nil {
                selectedIssue = allIssues.first
                selectedImageIndex = 0
            }
        }
        .onChange(of: selectedIssue?.id) { _, _ in
            // Sync image index when issue changes
            if let issue = selectedIssue {
                syncSelectedImageIndex(for: issue)
            } else {
                selectedImageIndex = 0
            }
        }
        .sheet(isPresented: $showingImagePreviewSheet) {
            if let issue = selectedIssue, !issue.imageURLs.isEmpty {
                ImagePreviewView(
                    imageURL: issue.imageURLs[selectedImageIndex],
                    allImageURLs: issue.imageURLs,
                    initialIndex: selectedImageIndex
                )
            }
        }
        .sheet(item: $sheetIssue) { issue in
            IssueFixOptionsView(
                issue: issue,
                coordinator: coordinator,
                onResolutionSelected: { resolution in
                    handleResolutionOption(issue: issue, resolution: resolution)
                    sheetIssue = nil
                },
                onCancel: {
                    sheetIssue = nil
                }
            )
        }
        .sheet(item: $metadataEditorIssue) { issue in
            MetadataEditorView(
                imageURLs: issue.imageURLs,
                initialImageIndex: getSelectedImageIndex(for: issue),
                onSave: {
                    metadataEditorIssue = nil
                    coordinator.markIssueAsResolved(issue.id)
                    updateSelectionAfterResolution(resolvedIssueId: issue.id)
                },
                onCancel: {
                    metadataEditorIssue = nil
                }
            )
        }
    }
    
    // MARK: - Image Selection Management
    private func getSelectedImageIndex(for issue: IssueItem) -> Int {
        let storedIndex = issueImageSelections[issue.id] ?? 0
        // Ensure the stored index is valid for this issue's images
        return min(storedIndex, max(0, issue.imageURLs.count - 1))
    }
    
    private func setSelectedImageIndex(_ index: Int, for issue: IssueItem) {
        let validIndex = min(max(0, index), issue.imageURLs.count - 1)
        issueImageSelections[issue.id] = validIndex
        selectedImageIndex = validIndex
    }
    
    private func syncSelectedImageIndex(for issue: IssueItem) {
        let correctIndex = getSelectedImageIndex(for: issue)
        selectedImageIndex = correctIndex
    }
    
    // MARK: - Header
    private var issuesHeader: some View {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fix Issues")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                Text("\(allIssues.count) issues found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
            // Quick summary
            HStack(spacing: 16) {
                let summary = coordinator.getIssuesSummary()
                
                if summary.conflicts > 0 {
                    Label("\(summary.conflicts)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(Constants.Colors.errorRed)
                        .font(.caption)
                }
                
                if summary.poseIssues > 0 {
                    Label("\(summary.poseIssues)", systemImage: "person.2.badge.minus")
                        .foregroundColor(Constants.Colors.warningOrange)
                        .font(.caption)
                }
                
                if summary.validationIssues > 0 {
                    Label("\(summary.validationIssues)", systemImage: "checkmark.shield")
                        .foregroundColor(Constants.Colors.warningOrange)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Constants.Colors.surface)
    }
    
    // MARK: - Issues List
    private var issuesListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(allIssues, id: \.id) { issue in
                        IssueRowView(
                            issue: issue,
                            isSelected: selectedIssue?.id == issue.id,
                            onSelect: { selectedIssue = issue },
                            onAction: { action in
                                handleIssueAction(issue: issue, action: action)
                            }
                        )
                        .id(issue.id)
                    }
                }
                .padding()
            }
            .onChange(of: selectedIssue?.id) { _, newValue in
                if let id = newValue {
                    // Defer to next runloop so the list is updated before scrolling
                    DispatchQueue.main.async {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: pendingScrollToId) { _, target in
                guard let id = target else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    pendingScrollToId = nil
                }
            }
        }
        .background(Constants.Colors.background)
    }
    
    // MARK: - Preview and Details
    private var previewAndDetailsView: some View {
        VStack(spacing: 0) {
            if let issue = selectedIssue {
                // Simple thumbnail grid
                if !issue.imageURLs.isEmpty {
                    VStack(spacing: 0) {
                        // Header with selection info and preview button
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Photos (\(issue.imageURLs.count))")
                                    .font(.headline)
                                if issue.imageURLs.count > 1 {
                                    Text("Selected: \(selectedImageIndex + 1) of \(issue.imageURLs.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                showingImagePreviewSheet = true
                            } label: {
                                Label("Preview Selected", systemImage: "eye")
                            }
                            .buttonStyle(.bordered)
                            .help("Open full preview of selected image")
                        }
                        .padding([.horizontal, .top], 12)
                        .padding(.bottom, 6)

                        // Simple thumbnail grid
                        simpleThumbnailGrid(for: issue)
                            .frame(maxHeight: 400)
                            .id(issue.id) // Force refresh when issue changes
                    }
                } else {
                    emptyPreviewState
                        .frame(height: 400)
                }
                
                Divider()
                
                // Issue details footer (compact)
                issueDetailsFooter(for: issue)
                    .frame(height: 100)
            } else {
                selectIssuePrompt
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Constants.Colors.surface)
    }
    
    private func issueDetailsFooter(for issue: IssueItem) -> some View {
        VStack(spacing: 8) {
            // Issue info (compact)
            HStack {
                Image(systemName: issue.icon)
                    .foregroundColor(issue.color)
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(issue.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Navigation info
                if !issue.imageURLs.isEmpty {
                    if issue.imageURLs.count > 1 {
                        Text("\(selectedImageIndex + 1) of \(issue.imageURLs.count)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(issue.color.opacity(0.2))
                            .cornerRadius(4)
                    } else {
                        Text("1 file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Fix Issue") {
                    // Use direct item pattern - more reliable than boolean + state
                    sheetIssue = issue
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button("Mark as OK") {
                    handleIssueAction(issue: issue, action: .markAsOK)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Spacer()
                
                // Keyboard hints
                HStack(spacing: 12) {
                    Text("↑↓ Issues")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if issue.imageURLs.count > 1 {
                        Text("←→ Select Photo")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("F Fix")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("⏎ OK")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(issue.color.opacity(0.05))
    }
    
    private var emptyPreviewState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No images to preview")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var selectIssuePrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("Select an issue to preview")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - No Issues View
    private var noIssuesView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(Constants.Colors.successGreen)
            
            VStack(spacing: 8) {
                Text("All Good!")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("No issues found. Your files are ready to be renamed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helper Properties
    private var hasAnyIssues: Bool {
        !allIssues.isEmpty
    }
    
    private var allIssues: [IssueItem] {
        var issues: [IssueItem] = []
        var processedFiles: Set<String> = [] // Track files we've already included
        
        // Add conflict issues
        let conflicts = coordinator.viewModel.filesToRename.filter { $0.hasConflict }
        for conflict in conflicts {
            let fileName = conflict.sourceURL.lastPathComponent
            if !processedFiles.contains(fileName) {
                issues.append(IssueItem(
                    id: "conflict-\(fileName)",
                    type: .conflict,
                    title: "Name Conflict",
                    description: conflict.originalName,
                    imageURLs: [conflict.sourceURL],
                    data: conflict
                ))
                processedFiles.insert(fileName)
            }
        }
        
        // Note: Pose count issues are now handled as validation issues in the validation report
        // This section is commented out to avoid double-processing
        // The pose count issues are created in FileRenamerViewModel.createPoseCountIssues()
        // and added to the validation report, so they'll be processed below
        
        // Add validation issues (only if not already covered)
        if let validationReport = coordinator.viewModel.validationReport {
            for issue in validationReport.issues {
                let unprocessedFiles = issue.affectedFiles.filter { url in
                    !processedFiles.contains(url.lastPathComponent)
                }
                
                // Determine issue type based on message content
                let issueType: IssueType
                if issue.message.contains("poses") {
                    issueType = .poseCount
                } else {
                    issueType = .validation
                }
                
                // For pose count issues, use all affected files (don't filter by processed files)
                let filesToUse = issueType == .poseCount ? issue.affectedFiles : unprocessedFiles
                
                // Only add issue if it has files
                if !filesToUse.isEmpty {
                    issues.append(IssueItem(
                        id: "validation-\(issue.id)",
                        type: issueType,
                        title: issue.message,
                        description: issue.suggestion ?? "",
                        imageURLs: filesToUse,
                        data: issue
                    ))
                    
                    // Mark these files as processed (only for non-pose-count issues)
                    if issueType != .poseCount {
                        for file in filesToUse {
                            processedFiles.insert(file.lastPathComponent)
                        }
                    }
                } else {
                    // No files associated with this issue; nothing to show in UI
                }
            }
        }
        
        // Filter out resolved issues
        let filteredIssues = issues.filter { !coordinator.isIssueResolved($0.id) }
        return filteredIssues
    }
    
    // MARK: - Helper Methods
    private func handleKeyPressWithCode(_ keyCode: UInt16) {
        switch keyCode {
        case 126: // Up arrow - previous issue
            navigateToPreviousIssue()
        case 125: // Down arrow - next issue
            navigateToNextIssue()
        case 123: // Left arrow - previous image
            navigateToPreviousImage()
        case 124: // Right arrow - next image
            navigateToNextImage()
        case 3: // F key - Fix issue
            if let issue = selectedIssue {
                issueToFix = issue
                showingFixOptionsMenu = true
            }
        case 36: // Return key - Mark as OK
            if let issue = selectedIssue {
                handleIssueAction(issue: issue, action: .markAsOK)
            }
        default:
            break
        }
    }
    
    private func navigateToPreviousIssue() {
        guard let currentIssue = selectedIssue,
              let currentIndex = allIssues.firstIndex(where: { $0.id == currentIssue.id }),
              currentIndex > 0 else { return }
        
        selectedIssue = allIssues[currentIndex - 1]
        if let issue = selectedIssue {
            syncSelectedImageIndex(for: issue)
        }
    }
    
    private func navigateToNextIssue() {
        guard let currentIssue = selectedIssue,
              let currentIndex = allIssues.firstIndex(where: { $0.id == currentIssue.id }),
              currentIndex < allIssues.count - 1 else { return }
        
        selectedIssue = allIssues[currentIndex + 1]
        if let issue = selectedIssue {
            syncSelectedImageIndex(for: issue)
        }
    }
    
    private func navigateToPreviousImage() {
        guard let issue = selectedIssue, selectedImageIndex > 0 else { return }
        setSelectedImageIndex(selectedImageIndex - 1, for: issue)
    }
    
    private func navigateToNextImage() {
        guard let issue = selectedIssue, selectedImageIndex < issue.imageURLs.count - 1 else { return }
        setSelectedImageIndex(selectedImageIndex + 1, for: issue)
    }
    
    // MARK: - Simple Thumbnail Grid
    private func simpleThumbnailGrid(for issue: IssueItem) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)], spacing: 12) {
            ForEach(Array(issue.imageURLs.enumerated()), id: \.offset) { index, url in
                    LargeThumbnailView(
                        url: url,
                        size: CGSize(width: 140, height: 140),
                        cornerRadius: 8,
                        showBorder: true,
                        onTap: {
                            // Single click = select image
                            setSelectedImageIndex(index, for: issue)
                        }
                    )
                .onTapGesture(count: 2) {
                    // Double click = open preview
                    setSelectedImageIndex(index, for: issue)
                    showingImagePreviewSheet = true
                }
                .overlay(
                    Group {
                        RoundedRectangle(cornerRadius: 8)
                                .stroke(index == selectedImageIndex ? Constants.Colors.brandTint : Constants.Colors.cardBorder, lineWidth: index == selectedImageIndex ? 3 : 1)
                        
                        if index == selectedImageIndex {
                            VStack {
                                HStack {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Constants.Colors.brandTint)
                                        .background(Circle().fill(Color.white).scaleEffect(0.8))
                                        .font(.title3)
                                }
                                Spacer()
                            }
                            .padding(6)
                        }
                    }
                )
                .help("Click to select • Double-click to preview \(url.lastPathComponent)")
                .id("\(issue.id)-\(index)") // Unique ID for each thumbnail
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }


    
    
    private func handleIssueAction(issue: IssueItem, action: IssueAction) {
        switch action {
        case .resolve:
            resolveIssue(issue)
        case .markAsOK:
            markIssueAsOK(issue)
        case .preview:
            selectedIssue = issue
            syncSelectedImageIndex(for: issue)
        }
    }
    
    private func resolveIssue(_ issue: IssueItem) {
        
        switch issue.type {
        case .conflict:
            if let operation = issue.data as? RenameOperation {
                // Handle conflict resolution by adding a suffix
                let newName = operation.newName + "_1"
                coordinator.viewModel.updateNewName(for: operation.sourceURL, to: newName)
                coordinator.updateFromViewModel()
            }
        case .poseCount:
            // For pose count issues, just mark as resolved since user confirmed it's OK
            coordinator.markIssueAsResolved(issue.id)
        case .validation:
            if let validationIssue = issue.data as? ValidationIssue {
                coordinator.viewModel.flagStore.flagIssue(
                    validationIssue,
                    flag: .dismiss,
                    jobFolderPath: coordinator.jobFolder.path
                )
                coordinator.updateFromViewModel()
            }
        }
        
        // Update selection after resolution
        updateSelectionAfterResolution(resolvedIssueId: issue.id)
    }
    
    private func markIssueAsOK(_ issue: IssueItem) {
        // Compute the logical next issue ID based on current ordering before we mutate state
        let currentList = allIssues
        if let idx = currentList.firstIndex(where: { $0.id == issue.id }) {
            let tail = currentList.suffix(from: idx + 1)
            pendingNextIssueId = tail.first?.id ?? currentList.first(where: { $0.id != issue.id })?.id
        } else {
            pendingNextIssueId = nil
        }
        
        // Mark resolved
        coordinator.markIssueAsResolved(issue.id)
        
        // Refresh model on next runloop to let views settle, then restore selection and scroll
        DispatchQueue.main.async {
            coordinator.updateFromViewModel()
            if let nextId = pendingNextIssueId {
                // After update, find the next issue by ID and select it
                if let next = allIssues.first(where: { $0.id == nextId }) {
                    selectedIssue = next
                    pendingScrollToId = nextId
                } else {
                    // Fallback: select first if available
                    selectedIssue = allIssues.first
                    pendingScrollToId = selectedIssue?.id
                }
            } else {
                // No next; try to select first unresolved if any
                selectedIssue = allIssues.first
                pendingScrollToId = selectedIssue?.id
            }
            pendingNextIssueId = nil
        }
    }
    
    private func updateSelectionAfterResolution(resolvedIssueId: String) {
        // Auto-select next unresolved issue
        selectNextUnresolvedIssue(after: resolvedIssueId)
    }
    
    private func selectNextUnresolvedIssue(after resolvedIssueId: String) {
        // Only update selection if the resolved issue was currently selected
        guard selectedIssue?.id == resolvedIssueId else { return }
        
        // Get all unresolved issues (excluding the one just resolved)
        let unresolvedIssues = allIssues.filter { !coordinator.isIssueResolved($0.id) && $0.id != resolvedIssueId }
        
        if let currentIndex = allIssues.firstIndex(where: { $0.id == resolvedIssueId }) {
            // Try to find the next issue after the current position
            let issuesAfterCurrent = allIssues.suffix(from: currentIndex + 1).filter { !coordinator.isIssueResolved($0.id) }
            
            if let nextIssue = issuesAfterCurrent.first {
                // Select the next unresolved issue
                selectedIssue = nextIssue
            } else if let firstUnresolved = unresolvedIssues.first {
                // If no issues after current, wrap to first unresolved issue
                selectedIssue = firstUnresolved
            } else {
                // No more unresolved issues
                selectedIssue = nil
            }
        } else if let firstUnresolved = unresolvedIssues.first {
            // Fallback: select first unresolved issue
            selectedIssue = firstUnresolved
        } else {
            // No unresolved issues left
            selectedIssue = nil
        }
        
        // Sync image index for the new issue
        if let issue = selectedIssue {
            syncSelectedImageIndex(for: issue)
        }
    }
    
    private func handleResolutionOption(issue: IssueItem, resolution: ResolutionOption) {
        switch resolution {
        case .dismiss:
            // Dismiss the issue without changing anything
            dismissIssue(issue)
        case .appendSequence:
            // Append sequence number to resolve conflicts
            appendSequenceToConflict(issue: issue)
        case .editCSV:
            // Open CSV editor - delegate to coordinator
            coordinator.openCSVEditor()
        case .editMetadata:
            // Open metadata editor for the files
            openMetadataEditor(issue: issue)
        case .moveToIssues:
            // Move problematic files to Issues folder
            moveFilesToIssuesFolder(issue: issue)
        case .renameManually:
            // Mark for manual renaming later
            markForManualRenaming(issue: issue)
        }
    }
    
    private func moveFilesToIssuesFolder(issue: IssueItem) {
        // Determine the source folder where files are currently located
        let sourceFolder = coordinator.viewModel.config.sourceFolder.url(
            in: coordinator.jobFolder,
            customPath: coordinator.viewModel.config.customSourcePath
        )
        
        // Create "Issues" folder inside the source folder
        let issuesFolder = sourceFolder.appendingPathComponent("Issues")
        
        moveFiles(issue.imageURLs, to: issuesFolder, folderName: "Issues")
        coordinator.markIssueAsResolved(issue.id)
        updateSelectionAfterResolution(resolvedIssueId: issue.id)
        
    }
    
    private func dismissIssue(_ issue: IssueItem) {
        // Simply mark the issue as resolved without changing anything
        coordinator.markIssueAsResolved(issue.id)
        updateSelectionAfterResolution(resolvedIssueId: issue.id)
    }
    
    private func appendSequenceToConflict(issue: IssueItem) {
        // For conflict issues, append a sequence number
        if let operation = issue.data as? RenameOperation {
            let ext = (operation.newName as NSString).pathExtension
            let nameWithoutExt = (operation.newName as NSString).deletingPathExtension
            let newName = ext.isEmpty ? "\(nameWithoutExt)_1" : "\(nameWithoutExt)_1.\(ext)"
            
            coordinator.viewModel.updateNewName(for: operation.sourceURL, to: newName)
            coordinator.updateFromViewModel()
            coordinator.markIssueAsResolved(issue.id)
            updateSelectionAfterResolution(resolvedIssueId: issue.id)
        }
    }
    
    private func openMetadataEditor(issue: IssueItem) {
        // Validate inputs
        guard !issue.imageURLs.isEmpty else {
            errorContext = ErrorContext(
                error: .noFilesToProcess,
                operation: "Edit Metadata",
                affectedFiles: [],
                recoveryOptions: [.cancel]
            )
            showingError = true
            return
        }
        
        // Use direct item pattern - more reliable than boolean + state
        metadataEditorIssue = issue
    }
    
    private func markForManualRenaming(issue: IssueItem) {
        // Create a "Manual Rename" folder and move files there
        let manualRenameFolder = coordinator.jobFolder.appendingPathComponent("Manual Rename")
        moveFiles(issue.imageURLs, to: manualRenameFolder, folderName: "Manual Rename")
        coordinator.markIssueAsResolved(issue.id)
        updateSelectionAfterResolution(resolvedIssueId: issue.id)
    }
    
    private func moveFiles(_ urls: [URL], to destinationFolder: URL, folderName: String) {
        do {
            // Create destination folder if it doesn't exist
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            
            var movedCount = 0
            var errors: [String] = []
            
            for url in urls {
                do {
                    // Check if source file exists
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        errors.append("Source file not found: \(url.lastPathComponent)")
                        continue
                    }
                    
                    let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
                    
                    // If destination exists, create unique name
                    var finalDestination = destinationURL
                    var counter = 1
                    while FileManager.default.fileExists(atPath: finalDestination.path) {
                        let name = (url.lastPathComponent as NSString).deletingPathExtension
                        let ext = (url.lastPathComponent as NSString).pathExtension
                        let newName = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
                        finalDestination = destinationFolder.appendingPathComponent(newName)
                        counter += 1
                    }
                    
                    try FileManager.default.moveItem(at: url, to: finalDestination)
                    movedCount += 1
                    
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            if !errors.isEmpty {
                let errorMessage = "Moved \(movedCount) of \(urls.count) files to \(folderName). Errors:\n" + errors.joined(separator: "\n")
                handleError(.unableToWriteFile(path: destinationFolder.path, underlyingError: NSError(domain: "MoveFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])), operation: "Move Files", affectedFiles: urls)
            }
            
            // Refresh the view model after moving files
            Task {
                await coordinator.viewModel.initialize()
                coordinator.updateFromViewModel()
            }
            
        } catch {
            handleError(.unableToWriteFile(path: destinationFolder.path, underlyingError: error), operation: "Move Files", affectedFiles: urls)
        }
    }
    
    private func handleError(_ error: PhotoWorkflowError, operation: String, affectedFiles: [URL] = []) {
        errorContext = ErrorContext(
            error: error,
            operation: operation,
            affectedFiles: affectedFiles,
            recoveryOptions: [.cancel]
        )
        showingError = true
    }
}

// MARK: - Issue Item Model
private struct IssueItem: Identifiable, Equatable {
    let id: String
    let type: IssueType
    let title: String
    let description: String
    let imageURLs: [URL]
    let data: Any?
    
    var icon: String {
        switch type {
        case .conflict: return "exclamationmark.triangle.fill"
        case .poseCount: return "person.2.badge.minus"
        case .validation: return "checkmark.shield"
        }
    }
    
    var color: Color {
        switch type {
        case .conflict: return Constants.Colors.errorRed
        case .poseCount: return Constants.Colors.warningOrange
        case .validation: return Constants.Colors.warningOrange
        }
    }
    
    static func == (lhs: IssueItem, rhs: IssueItem) -> Bool {
        lhs.id == rhs.id
    }
}

private enum IssueType {
    case conflict, poseCount, validation
}

private enum IssueAction {
    case resolve, markAsOK, preview
}

private enum ResolutionOption {
    case dismiss
    case appendSequence
    case editCSV
    case editMetadata
    case moveToIssues
    case renameManually
}

// MARK: - Issue Row View
private struct IssueRowView: View {
    let issue: IssueItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onAction: (IssueAction) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Issue icon and info
            HStack(spacing: 10) {
                Image(systemName: issue.icon)
                    .foregroundColor(issue.color)
                    .font(.system(size: 16))
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .medium)
                    
                    Text(issue.description)
                    .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            
            // File count badge
            if !issue.imageURLs.isEmpty {
                Text("\(issue.imageURLs.count)")
                .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(issue.color.opacity(0.2))
                    .cornerRadius(4)
                    .foregroundColor(issue.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? issue.color.opacity(0.15) : Constants.Colors.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? issue.color : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture {
            onSelect()
        }
        .contentShape(Rectangle()) // Make entire area tappable
    }
}

// MARK: - Issue Fix Options View
private struct IssueFixOptionsView: View {
    let issue: IssueItem
    let coordinator: RenameWizardCoordinator
    let onResolutionSelected: (ResolutionOption) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fix Issue: \(issue.title)")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(issue.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(issue.color.opacity(0.1))
            
            Divider()
            
            // Options
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Context-specific options based on issue type
                    ForEach(getOptionsForIssue(issue)) { option in
                        resolutionOption(
                            title: option.title,
                            description: option.description,
                            icon: option.icon,
                            action: option.action
                        )
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Constants.Colors.background)
    }
    
    private func resolutionOption(title: String, description: String, icon: String, action: ResolutionOption) -> some View {
        Button(action: {
            onResolutionSelected(action)
        }) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .foregroundColor(Constants.Colors.brandTint)
                    .font(.title2)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()
            .background(Constants.Colors.surface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Constants.Colors.border.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(1.0)
        .onHover { hovering in
            // Add subtle visual feedback for hover state
        }
    }
    
    private func getOptionsForIssue(_ issue: IssueItem) -> [ResolutionOptionInfo] {
        var options: [ResolutionOptionInfo] = []
        
        // Common options for all issue types
        options.append(ResolutionOptionInfo(
            title: "Dismiss Issue",
            description: "Mark this issue as resolved without making changes",
            icon: "checkmark.circle",
            action: .dismiss
        ))
        
        // Issue-specific options
        switch issue.type {
        case .conflict:
            options.append(ResolutionOptionInfo(
                title: "Append Sequence Number",
                description: "Add '_1', '_2', etc. to resolve naming conflicts",
                icon: "number.circle",
                action: .appendSequence
            ))
            
        case .poseCount, .validation:
            // For pose and validation issues, metadata editing might help - but only if there are images
            if !issue.imageURLs.isEmpty {
                options.append(ResolutionOptionInfo(
                    title: "Edit Image Metadata",
                    description: "View and edit EXIF data, keywords, or other metadata",
                    icon: "info.circle",
                    action: .editMetadata
                ))
            }
        }
        
        // CSV editing for data-related issues
        if issue.type == .conflict || issue.type == .validation {
            options.append(ResolutionOptionInfo(
                title: "Edit CSV Data",
                description: "Open the CSV file to correct naming data or player information",
                icon: "tablecells",
                action: .editCSV
            ))
        }
        
        // Only offer file operations if there are actual files
        if !issue.imageURLs.isEmpty {
            options.append(ResolutionOptionInfo(
                title: "Move to Issues Folder",
                description: "Move these photos to an 'Issues' folder to address later",
                icon: "folder.badge.questionmark",
                action: .moveToIssues
            ))
            
            options.append(ResolutionOptionInfo(
                title: "Mark for Manual Renaming",
                description: "Keep photos but handle renaming manually after the batch process",
                icon: "hand.point.up.left",
                action: .renameManually
            ))
        }
        
        return options
    }
}

private struct ResolutionOptionInfo: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let action: ResolutionOption
}

// MARK: - Array Safe Access Extension
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - KeyCatcher for Keyboard Navigation
private struct KeyCatcher: NSViewRepresentable {
    var onKeyDown: (UInt16) -> Void
    
    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKeyDown = onKeyDown
        return view
    }
    
    func updateNSView(_ nsView: KeyCatcherView, context: Context) {}
    
    final class KeyCatcherView: NSView {
        var onKeyDown: ((UInt16) -> Void)?
        private var focusTimer: Timer?
        
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startFocusTimer()
        }
        
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            startFocusTimer()
        }
        
        private func startFocusTimer() {
            focusTimer?.invalidate()
            focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.window?.firstResponder != self {
                    self.window?.makeFirstResponder(self)
                }
            }
        }
        
        override func keyDown(with event: NSEvent) {
            // Handle the key event
            onKeyDown?(event.keyCode)
        }
        
        override func mouseDown(with event: NSEvent) {
            // When clicked, ensure we have focus
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
        
        override func mouseDragged(with event: NSEvent) {
            // Maintain focus during drag operations
            super.mouseDragged(with: event)
            window?.makeFirstResponder(self)
        }
        
        override func mouseUp(with event: NSEvent) {
            // Regain focus after mouse operations
            super.mouseUp(with: event)
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self)
            }
        }
        
        override func magnify(with event: NSEvent) {
            super.magnify(with: event)
            // Regain focus after magnification gestures
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self)
            }
        }
        
        deinit {
            focusTimer?.invalidate()
        }
    }
}