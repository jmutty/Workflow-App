import SwiftUI

// MARK: - Revert Rename View
struct RevertRenameView: View {
    @ObservedObject var viewModel: FileRenamerViewModel
    let onDismiss: () -> Void
    
    @State private var selectedBackup: RenameBackupInfo? = nil
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Revert to Original Filenames")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Close") {
                    onDismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            
            Divider()
            
            if viewModel.availableBackups.isEmpty {
                // No backups available
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Backup Files Found")
                        .font(.headline)
                    Text("Backup CSV files are created automatically when you rename files.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                HSplitView {
                    // Left side: Backup selection list
                    backupSelectionList
                        .frame(minWidth: 300, idealWidth: 350)
                    
                    // Right side: Preview
                    revertPreviewPane
                        .frame(minWidth: 400)
                }
                .frame(maxHeight: .infinity)
            }
            
            Divider()
            
            // Action buttons
            HStack(spacing: 12) {
                if let backup = selectedBackup {
                    Text("\(backup.fileCount) file(s) from \(backup.sourceFolder)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Refresh") {
                    Task {
                        await viewModel.detectAvailableBackups()
                    }
                }
                .buttonStyle(.bordered)
                
                if selectedBackup != nil && !viewModel.revertOperations.isEmpty {
                    let readyCount = viewModel.revertOperations.filter { $0.canRevert }.count
                    Button("Revert \(readyCount) File(s)") {
                        showingConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(readyCount == 0 || viewModel.isReverting)
                }
            }
            .padding()
        }
        .frame(width: 900, height: 600)
        .alert("Error", isPresented: $showingError) {
            Button("OK") { showingError = false }
        } message: {
            Text(errorMessage)
        }
        .alert("Confirm Revert", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Revert", role: .destructive) {
                Task {
                    await performRevert()
                }
            }
        } message: {
            let readyCount = viewModel.revertOperations.filter { $0.canRevert }.count
            Text("This will revert \(readyCount) file(s) to their original names and locations. The backup CSV will be archived. This action cannot be undone.")
        }
    }
    
    private var backupSelectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Available Backups")
                .font(.headline)
                .padding()
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.availableBackups) { backup in
                        BackupRowView(
                            backup: backup,
                            isSelected: selectedBackup?.csvURL == backup.csvURL
                        ) {
                            selectedBackup = backup
                            Task {
                                await loadPreview(for: backup)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .background(Constants.Colors.surface)
    }
    
    private var revertPreviewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedBackup == nil {
                // No selection
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("Select a backup to preview")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.revertOperations.isEmpty {
                // Loading
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading preview...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show preview
                revertOperationsPreview
            }
        }
        .background(Constants.Colors.background)
    }
    
    private var revertOperationsPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header
            HStack {
                Text("Revert Preview")
                    .font(.headline)
                Spacer()
                let stats = getStatusStats()
                HStack(spacing: 16) {
                    Label("\(stats.ready)", systemImage: "checkmark.circle.fill")
                        .foregroundColor(Constants.Colors.successGreen)
                        .font(.caption)
                    if stats.notFound > 0 {
                        Label("\(stats.notFound)", systemImage: "questionmark.circle.fill")
                            .foregroundColor(Constants.Colors.warningOrange)
                            .font(.caption)
                    }
                    if stats.conflict > 0 {
                        Label("\(stats.conflict)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(Constants.Colors.errorRed)
                            .font(.caption)
                    }
                }
            }
            .padding()
            
            Divider()
            
            // Operations list
            if viewModel.isReverting {
                VStack(spacing: 16) {
                    ProgressView(value: viewModel.operationProgress)
                        .progressViewStyle(.linear)
                    Text(viewModel.currentOperation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.revertOperations) { operation in
                            RevertOperationRowView(operation: operation)
                            Divider()
                        }
                    }
                    .padding()
                }
            }
        }
    }
    
    private func getStatusStats() -> (ready: Int, notFound: Int, conflict: Int) {
        let ready = viewModel.revertOperations.filter { $0.status == .ready }.count
        let notFound = viewModel.revertOperations.filter { $0.status == .notFound }.count
        let conflict = viewModel.revertOperations.filter { $0.status == .conflictAtDestination }.count
        return (ready, notFound, conflict)
    }
    
    private func loadPreview(for backup: RenameBackupInfo) async {
        do {
            try await viewModel.loadRevertPreview(from: backup)
        } catch {
            errorMessage = "Failed to load preview: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func performRevert() async {
        do {
            try await viewModel.executeRevert()
            // Success - close the view
            onDismiss()
        } catch {
            errorMessage = "Failed to revert files: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - Backup Row View
struct BackupRowView: View {
    let backup: RenameBackupInfo
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDate)
                        .font(.headline)
                        .foregroundColor(isSelected ? .white : Constants.Colors.textPrimary)
                    
                    HStack(spacing: 8) {
                        Label("\(backup.fileCount) files", systemImage: "doc.text")
                        Label(backup.sourceFolder, systemImage: "folder")
                    }
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : Constants.Colors.textSecondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding()
            .background(isSelected ? Constants.Colors.brandTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: backup.timestamp)
    }
}

// MARK: - Revert Operation Row View
struct RevertOperationRowView: View {
    let operation: RevertOperation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon
                Text(operation.currentName)
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(operation.originalName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
            }
            
            if operation.status != .ready {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundColor(statusColor)
                    .padding(.leading, 24)
            }
        }
        .opacity(operation.canRevert ? 1.0 : 0.6)
    }
    
    private var statusIcon: some View {
        Group {
            switch operation.status {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Constants.Colors.successGreen)
            case .notFound:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(Constants.Colors.warningOrange)
            case .conflictAtDestination:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Constants.Colors.errorRed)
            case .pending:
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }
    
    private var statusMessage: String {
        switch operation.status {
        case .ready:
            return "Ready to revert"
        case .notFound:
            return "File not found at expected location"
        case .conflictAtDestination:
            return "Original filename already exists at destination"
        case .pending:
            return "Checking..."
        }
    }
    
    private var statusColor: Color {
        switch operation.status {
        case .ready:
            return Constants.Colors.successGreen
        case .notFound:
            return Constants.Colors.warningOrange
        case .conflictAtDestination:
            return Constants.Colors.errorRed
        case .pending:
            return .secondary
        }
    }
}


