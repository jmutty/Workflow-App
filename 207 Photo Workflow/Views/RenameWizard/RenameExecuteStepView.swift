import SwiftUI

// MARK: - Execute Step View
struct RenameExecuteStepView: View {
    @ObservedObject var coordinator: RenameWizardCoordinator
    @Environment(\.dismiss) private var dismiss
    
    @State private var isExecuting = false
    @State private var hasStarted = false
    @State private var executionResult: ExecutionResult?
    @State private var showingError = false
    @State private var errorContext: ErrorContext?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            executeHeader
            
            Divider()
            
            // Main content
            if !hasStarted {
                preExecutionView
            } else if isExecuting {
                executionProgressView
            } else if let result = executionResult {
                executionResultView(result)
            }
        }
        .alert("Error", isPresented: $showingError, presenting: errorContext) { context in
            Button("OK") { }
            if context.operation == "Rename Files" {
                Button("Retry") {
                    executeRename()
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
    
    // MARK: - Header
    private var executeHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundColor(Constants.Colors.brandTint)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rename Files")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !hasStarted {
                    executeButton
                }
            }
        }
        .padding()
        .background(Constants.Colors.surface)
    }
    
    private var headerSubtitle: String {
        if !hasStarted {
            return "Ready to rename \(coordinator.viewModel.filesToRename.count) files"
        } else if isExecuting {
            return "Renaming files in progress..."
        } else if let result = executionResult {
            if result.success {
                return "Successfully renamed \(result.successCount) files"
            } else {
                return "Completed with \(result.errorCount) errors"
            }
        }
        return ""
    }
    
    private var executeButton: some View {
        Button("Start Renaming") {
            executeRename()
        }
        .buttonStyle(.borderedProminent)
        .font(.headline)
        .disabled(coordinator.viewModel.filesToRename.isEmpty)
        .keyboardShortcut(.return)
    }
    
    // MARK: - Pre-execution View
    private var preExecutionView: some View {
        VStack(spacing: 30) {
            // Summary card
            executionSummaryCard
            
            // Final checklist
            finalChecklistCard
            
            // Warning if issues remain
            if coordinator.hasUnresolvedIssues {
                remainingIssuesWarning
            }
            
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: 600)
    }
    
    private var executionSummaryCard: some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title)
                    .foregroundColor(Constants.Colors.brandTint)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to Execute")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Text("Review the summary below before proceeding")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Summary stats
            HStack(spacing: 20) {
                SummaryStatCard(
                    icon: "photo.stack.fill",
                    title: "Files to Rename",
                    value: "\(coordinator.viewModel.filesToRename.count)",
                    color: Constants.Colors.brandTint
                )
                
                SummaryStatCard(
                    icon: "checkmark.circle.fill",
                    title: "Ready",
                    value: "\(coordinator.viewModel.filesToRename.filter { !$0.hasConflict }.count)",
                    color: Constants.Colors.successGreen
                )
                
                if coordinator.viewModel.conflictCount > 0 {
                    SummaryStatCard(
                        icon: "exclamationmark.triangle.fill",
                        title: "Conflicts",
                        value: "\(coordinator.viewModel.conflictCount)",
                        color: Constants.Colors.warningOrange
                    )
                }
            }
        }
        .padding(20)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    private var finalChecklistCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundColor(Constants.Colors.brandTint)
                
                Text("Final Checklist")
                    .font(.headline)
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                ChecklistItem(
                    text: "Source folder: \(coordinator.viewModel.config.sourceFolder.rawValue)",
                    isChecked: true
                )
                
                ChecklistItem(
                    text: "Naming method: \(coordinator.viewModel.config.dataSource.rawValue)",
                    isChecked: true
                )
                
                ChecklistItem(
                    text: "Backup will be created automatically",
                    isChecked: coordinator.viewModel.config.createBackupBeforeRename
                )
                
                ChecklistItem(
                    text: "All conflicts resolved",
                    isChecked: coordinator.viewModel.conflictCount == 0
                )
            }
        }
        .padding(20)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    private var remainingIssuesWarning: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Constants.Colors.warningOrange)
                
                Text("Unresolved Issues")
                    .font(.headline)
                    .foregroundColor(Constants.Colors.warningOrange)
                
                Spacer()
            }
            
            Text("There are still \(coordinator.issueCount) unresolved issues. The rename operation will proceed, but some files may be skipped or renamed differently than expected.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("← Go Back to Fix Issues") {
                coordinator.goToStep(.resolveIssues)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Constants.Colors.warningOrange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.warningOrange.opacity(0.3), lineWidth: 1)
        )
    }
    
    // MARK: - Execution Progress View
    private var executionProgressView: some View {
        VStack(spacing: 30) {
            // Progress circle
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Constants.Colors.cardBorder, lineWidth: 8)
                        .frame(width: 120, height: 120)
                    
                    Circle()
                        .trim(from: 0, to: coordinator.viewModel.operationProgress)
                        .stroke(Constants.Colors.brandTint, lineWidth: 8)
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: coordinator.viewModel.operationProgress)
                    
                    VStack(spacing: 4) {
                        Text("\(Int(coordinator.viewModel.operationProgress * 100))%")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(Constants.Colors.brandTint)
                        
                        Text("Complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Text("Renaming Files...")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            
            // Progress details
            VStack(spacing: 16) {
                if !coordinator.viewModel.currentOperation.isEmpty {
                    Text(coordinator.viewModel.currentOperation)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                HStack(spacing: 30) {
                    ProgressStat(
                        title: "Files Processed",
                        value: "\(Int(coordinator.viewModel.operationProgress * Double(coordinator.viewModel.filesToRename.count)))/\(coordinator.viewModel.filesToRename.count)"
                    )
                    
                    if let eta = estimateTimeRemaining() {
                        ProgressStat(
                            title: "Time Remaining",
                            value: eta
                        )
                    }
                }
            }
            
            // Cancel button
            Button("Cancel") {
                Task {
                    await coordinator.viewModel.cancelOperation()
                    isExecuting = false
                    hasStarted = false
                }
            }
            .buttonStyle(.bordered)
            
            Spacer()
        }
        .padding(30)
    }
    
    // MARK: - Execution Result View
    private func executionResultView(_ result: ExecutionResult) -> some View {
        VStack(spacing: 30) {
            // Result icon and title
            VStack(spacing: 16) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(result.success ? Constants.Colors.successGreen : Constants.Colors.warningOrange)
                
                Text(result.success ? "Rename Complete!" : "Completed with Issues")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(result.success ? Constants.Colors.successGreen : Constants.Colors.warningOrange)
            }
            
            // Result summary
            resultSummaryCard(result)
            
            // Actions
            VStack(spacing: 12) {
                if coordinator.viewModel.lastRenameOperationId != nil {
                    Button("Undo Rename") {
                        Task {
                            await coordinator.viewModel.undoLastRename()
                            coordinator.updateFromViewModel()
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Revert all files back to their original names")
                    .onAppear {
                        print("🔘 Wizard undo button appeared! lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
                    }
                } else {
                    // Debug: Show why undo button is not showing
                    Text("")
                        .onAppear {
                            print("🔘 ❌ Wizard undo button NOT showing. lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
                        }
                }
                
                Button("Finish") {
                    coordinator.jobManager.updateOperationStatus(.renameFiles, status: .completed(Date()))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
            
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: 600)
    }
    
    private func resultSummaryCard(_ result: ExecutionResult) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                ResultStatCard(
                    icon: "checkmark.circle.fill",
                    title: "Successful",
                    value: "\(result.successCount)",
                    color: Constants.Colors.successGreen
                )
                
                if result.errorCount > 0 {
                    ResultStatCard(
                        icon: "xmark.circle.fill",
                        title: "Failed",
                        value: "\(result.errorCount)",
                        color: Constants.Colors.errorRed
                    )
                }
                
                if result.skippedCount > 0 {
                    ResultStatCard(
                        icon: "minus.circle.fill",
                        title: "Skipped",
                        value: "\(result.skippedCount)",
                        color: Constants.Colors.warningOrange
                    )
                }
            }
            
            if !result.errors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Issues Encountered:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ForEach(Array(result.errors.prefix(3).enumerated()), id: \.offset) { _, error in
                        Text("• \(error)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if result.errors.count > 3 {
                        Text("... and \(result.errors.count - 3) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    // MARK: - Helper Methods
    private func executeRename() {
        hasStarted = true
        isExecuting = true
        
        Task {
            do {
                try await coordinator.viewModel.executeRenames()
                
                // Create execution result
                await MainActor.run {
                    executionResult = ExecutionResult(
                        success: true,
                        successCount: coordinator.viewModel.filesToRename.count,
                        errorCount: 0,
                        skippedCount: 0,
                        errors: []
                    )
                    isExecuting = false
                }
                
            } catch let error as PhotoWorkflowError {
                await MainActor.run {
                    executionResult = ExecutionResult(
                        success: false,
                        successCount: 0,
                        errorCount: coordinator.viewModel.filesToRename.count,
                        skippedCount: 0,
                        errors: [error.localizedDescription]
                    )
                    isExecuting = false
                    
                    errorContext = ErrorContext(
                        error: error,
                        operation: "Rename Files",
                        affectedFiles: coordinator.viewModel.filesToRename.map { $0.sourceURL },
                        recoveryOptions: [.retry, .cancel]
                    )
                    showingError = true
                }
            } catch {
                await MainActor.run {
                    let workflowError = PhotoWorkflowError.unableToWriteFile(path: "Multiple files", underlyingError: error)
                    executionResult = ExecutionResult(
                        success: false,
                        successCount: 0,
                        errorCount: coordinator.viewModel.filesToRename.count,
                        skippedCount: 0,
                        errors: [error.localizedDescription]
                    )
                    isExecuting = false
                    
                    errorContext = ErrorContext(
                        error: workflowError,
                        operation: "Rename Files",
                        affectedFiles: coordinator.viewModel.filesToRename.map { $0.sourceURL },
                        recoveryOptions: [.retry, .cancel]
                    )
                    showingError = true
                }
            }
        }
    }
    
    private func estimateTimeRemaining() -> String? {
        guard coordinator.viewModel.operationProgress > 0.1 else { return nil }
        let remaining = (1.0 - coordinator.viewModel.operationProgress) / coordinator.viewModel.operationProgress
        let seconds = Int(remaining * 10)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
    }
}

// MARK: - Execution Result Model
private struct ExecutionResult {
    let success: Bool
    let successCount: Int
    let errorCount: Int
    let skippedCount: Int
    let errors: [String]
}

// MARK: - Component Views
private struct SummaryStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct ChecklistItem: View {
    let text: String
    let isChecked: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isChecked ? Constants.Colors.successGreen : .secondary)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(isChecked ? .primary : .secondary)
            
            Spacer()
        }
    }
}

private struct ProgressStat: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct ResultStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview
#if DEBUG
struct RenameExecuteStepView_Previews: PreviewProvider {
    static var previews: some View {
        RenameExecuteStepView(
            coordinator: RenameWizardCoordinator(
                jobFolder: URL(fileURLWithPath: "/tmp/test"),
                jobManager: JobManager()
            )
        )
    }
}
#endif
