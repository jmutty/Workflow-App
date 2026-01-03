import SwiftUI

// MARK: - Conflict Resolution Card
struct ConflictResolutionCard: View {
    let operation: RenameOperation
    @Binding var manualName: String
    let onPreview: () -> Void
    let onResolve: (String) -> Void
    let onSkip: () -> Void
    
    @State private var isEditing = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header with conflict indicator
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Constants.Colors.errorRed)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name Conflict")
                        .font(.headline)
                        .foregroundColor(Constants.Colors.errorRed)
                    
                    Text("A file with the new name already exists")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Before/After with thumbnail
            HStack(spacing: 16) {
                // Thumbnail and original name
                VStack(spacing: 8) {
                    LargeThumbnailView(
                        url: operation.sourceURL,
                        size: CGSize(width: 120, height: 120),
                        onTap: onPreview
                    )
                    
                    Text(operation.originalName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 120)
                }
                
                Image(systemName: "arrow.right")
                    .foregroundColor(Constants.Colors.brandTint)
                
                // New name with conflict
                VStack(spacing: 8) {
                    ZStack {
                        LargeThumbnailView(
                            url: operation.sourceURL,
                            size: CGSize(width: 120, height: 120),
                            onTap: onPreview
                        )
                        
                        // Conflict overlay
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Constants.Colors.errorRed)
                                    .background(Circle().fill(Color.white).frame(width: 20, height: 20))
                                    .padding(4)
                            }
                        }
                    }
                    
                    Text(operation.newName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(Constants.Colors.errorRed)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 120)
                }
            }
            
            Divider()
            
            // Resolution options
            VStack(spacing: 12) {
                Text("How would you like to fix this?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if isEditing {
                    // Manual name editing
                    VStack(spacing: 8) {
                        HStack {
                            Text("New name:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            TextField("Enter new filename", text: $manualName)
                                .textFieldStyle(.roundedBorder)
                            
                            Button("Apply") {
                                let trimmed = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onResolve(trimmed)
                                    isEditing = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Cancel") {
                                manualName = operation.newName
                                isEditing = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    // Quick resolution options
                    HStack(spacing: 12) {
                        Button("Add Number") {
                            let newName = addNumberSuffix(to: operation.newName)
                            onResolve(newName)
                        }
                        .buttonStyle(.bordered)
                        .help("Add a number to make the name unique (e.g., filename_1.jpg)")
                        
                        Button("Edit Name") {
                            isEditing = true
                        }
                        .buttonStyle(.bordered)
                        .help("Manually type a new filename")
                        
                        Button("Skip File") {
                            onSkip()
                        }
                        .buttonStyle(.bordered)
                        .help("Move this file to a Skipped folder")
                    }
                }
            }
        }
        .padding(16)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.errorRed, lineWidth: 1)
        )
    }
    
    private func addNumberSuffix(to filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        return ext.isEmpty ? "\(nameWithoutExt)_1" : "\(nameWithoutExt)_1.\(ext)"
    }
}

// MARK: - Pose Issue Summary Card
struct PoseIssueSummaryCard: View {
    let validation: PoseCountValidation
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "person.2.badge.minus")
                    .font(.title2)
                    .foregroundColor(Constants.Colors.warningOrange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pose Count Issues Found")
                        .font(.headline)
                    
                    Text("\(validation.playersWithIssues.count) players have incorrect pose counts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Summary stats
            HStack(spacing: 20) {
                StatItem(
                    title: "Expected Poses",
                    value: "\(validation.expectedCount)",
                    color: Constants.Colors.successGreen
                )
                
                StatItem(
                    title: "Players with Issues",
                    value: "\(validation.playersWithIssues.count)",
                    color: Constants.Colors.warningOrange
                )
                
                StatItem(
                    title: "Total Players",
                    value: "\(validation.totalPlayers)",
                    color: .secondary
                )
                
                Spacer()
            }
        }
        .padding(16)
        .background(Constants.Colors.warningOrange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.warningOrange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Pose Issue Player Card
struct PoseIssuePlayerCard: View {
    let playerIssue: (player: String, count: Int)
    let expectedCount: Int
    @ObservedObject var coordinator: RenameWizardCoordinator
    let onPreview: (URL, [URL]) -> Void
    let onError: (PhotoWorkflowError, String, [URL]) -> Void
    
    @State private var showingPlayerPhotos = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Player header
            HStack {
                Image(systemName: issueIcon)
                    .foregroundColor(issueColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(playerIssue.player)
                        .font(.headline)
                    
                    Text(issueDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Pose count badge
                HStack(spacing: 4) {
                    Text("\(playerIssue.count)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(issueColor)
                    
                    Text("poses")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(issueColor.opacity(0.1))
                .cornerRadius(16)
            }
            
            // Player photos preview (first few)
            if !playerPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(playerPhotos.prefix(6).enumerated()), id: \.offset) { index, operation in
                            VStack(spacing: 4) {
                                LargeThumbnailView(
                                    url: operation.sourceURL,
                                    size: CGSize(width: 80, height: 80),
                                    cornerRadius: 6,
                                    onTap: {
                                        onPreview(operation.sourceURL, playerPhotos.map { $0.sourceURL })
                                    }
                                )
                                
                                Text("Pose \(index + 1)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if playerPhotos.count > 6 {
                            Button("View All") {
                                showingPlayerPhotos = true
                            }
                            .buttonStyle(.bordered)
                            .frame(width: 80, height: 80)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            
            Divider()
            
            // Resolution options
            HStack(spacing: 12) {
                if playerIssue.count < expectedCount {
                    // Missing poses
                    Button("Find Missing Photos") {
                        // Could implement a search/match feature
                    }
                    .buttonStyle(.bordered)
                    .help("Search for photos that might belong to this player")
                } else {
                    // Too many poses
                    Button("Review Extra Photos") {
                        showingPlayerPhotos = true
                    }
                    .buttonStyle(.bordered)
                    .help("Review which photos might be duplicates or incorrectly assigned")
                }
                
                Button("Mark as OK") {
                    markPlayerAsOK()
                }
                .buttonStyle(.bordered)
                .help("Accept this pose count and continue")
                
                Spacer()
                
                Button("View All Photos") {
                    showingPlayerPhotos = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(issueColor.opacity(0.3), lineWidth: 1)
        )
        .sheet(isPresented: $showingPlayerPhotos) {
            PlayerPhotosDetailView(
                playerName: playerIssue.player,
                photos: playerPhotos,
                expectedCount: expectedCount,
                onPreview: onPreview,
                onDismiss: { showingPlayerPhotos = false }
            )
        }
    }
    
    // MARK: - Helper Properties
    private var playerPhotos: [RenameOperation] {
        coordinator.viewModel.filesToRename.filter { operation in
            let parts = operation.newName.components(separatedBy: "_")
            if parts.count >= 3,
               Int(parts.last?.components(separatedBy: ".").first ?? "") != nil {
                let playerKey = parts.dropLast().joined(separator: "_")
                return playerKey == playerIssue.player
            }
            return false
        }
    }
    
    private var issueIcon: String {
        playerIssue.count < expectedCount ? "minus.circle.fill" : "plus.circle.fill"
    }
    
    private var issueColor: Color {
        playerIssue.count < expectedCount ? Constants.Colors.errorRed : Constants.Colors.warningOrange
    }
    
    private var issueDescription: String {
        if playerIssue.count < expectedCount {
            let missing = expectedCount - playerIssue.count
            return "Missing \(missing) pose\(missing == 1 ? "" : "s")"
        } else {
            let extra = playerIssue.count - expectedCount
            return "\(extra) extra pose\(extra == 1 ? "" : "s")"
        }
    }
    
    // MARK: - Helper Methods
    private func markPlayerAsOK() {
        // Create a validation issue for this player and mark it as dismissed
        let issue = ValidationIssue(
            severity: .warning,
            message: "Player '\(playerIssue.player)' has \(playerIssue.count) poses (expected \(expectedCount))",
            suggestion: "Marked as acceptable by user",
            affectedFiles: playerPhotos.map { $0.sourceURL }
        )
        
        coordinator.viewModel.flagStore.flagIssue(
            issue,
            flag: .dismiss,
            jobFolderPath: coordinator.jobFolder.path
        )
        
        // Trigger a full re-validation to update the pose count validation
        Task {
            await coordinator.viewModel.runPreflightValidation()
            await MainActor.run {
                coordinator.updateFromViewModel()
            }
        }
    }
}

// MARK: - Validation Issue Card
struct ValidationIssueCard: View {
    let issue: ValidationIssue
    let onPreview: (URL, [URL]) -> Void
    let onResolve: (ValidationIssue) -> Void
    
    @State private var showingDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Issue header
            HStack {
                Image(systemName: severityIcon)
                    .foregroundColor(severityColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.message)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if let suggestion = issue.suggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(showingDetails ? "Hide" : "Details") {
                    showingDetails.toggle()
                }
                .buttonStyle(.bordered)
            }
            
            // Affected files (if showing details)
            if showingDetails && !issue.affectedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Affected Files (\(issue.affectedFiles.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(issue.affectedFiles.prefix(10).enumerated()), id: \.offset) { index, url in
                                VStack(spacing: 4) {
                                    LargeThumbnailView(
                                        url: url,
                                        size: CGSize(width: 60, height: 60),
                                        cornerRadius: 4,
                                        onTap: {
                                            onPreview(url, issue.affectedFiles)
                                        }
                                    )
                                    
                                    Text(url.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 60)
                                }
                            }
                            
                            if issue.affectedFiles.count > 10 {
                                Text("+\(issue.affectedFiles.count - 10) more")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, height: 60)
                                    .background(Constants.Colors.cardBackground)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            
            // Resolution actions
            HStack(spacing: 12) {
                Button("Dismiss Issue") {
                    onResolve(issue)
                }
                .buttonStyle(.bordered)
                .help("Hide this issue and continue")
                
                if !issue.affectedFiles.isEmpty {
                    Button("Preview Files") {
                        if let firstFile = issue.affectedFiles.first {
                            onPreview(firstFile, issue.affectedFiles)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
            }
        }
        .padding(16)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(severityColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    // MARK: - Helper Properties
    private var severityIcon: String {
        switch issue.severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    private var severityColor: Color {
        switch issue.severity {
        case .error: return Constants.Colors.errorRed
        case .warning: return Constants.Colors.warningOrange
        case .info: return .blue
        }
    }
}

// MARK: - Player Photos Detail View
private struct PlayerPhotosDetailView: View {
    let playerName: String
    let photos: [RenameOperation]
    let expectedCount: Int
    let onPreview: (URL, [URL]) -> Void
    let onDismiss: () -> Void
    
    private let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 12)
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playerName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("\(photos.count) photos (expected \(expectedCount))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Close") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            
            Divider()
            
            // Photos grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, operation in
                        VStack(spacing: 6) {
                            LargeThumbnailView(
                                url: operation.sourceURL,
                                size: CGSize(width: 120, height: 120),
                                onTap: {
                                    onPreview(operation.sourceURL, photos.map { $0.sourceURL })
                                }
                            )
                            
                            Text("Pose \(index + 1)")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Text(operation.originalName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 600, height: 500)
    }
}

// MARK: - Stat Item Component
private struct StatItem: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
