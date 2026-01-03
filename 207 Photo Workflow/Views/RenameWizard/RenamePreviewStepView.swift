import SwiftUI

// MARK: - Preview Step View
struct RenamePreviewStepView: View {
    @ObservedObject var coordinator: RenameWizardCoordinator
    
    @State private var searchText = ""
    @State private var selectedFilter: PreviewFilter = .all
    
    private let columns = [
        GridItem(.adaptive(minimum: 360, maximum: 400), spacing: 16)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with controls
            previewHeader
            
            Divider()
            
            // Main content
            if coordinator.viewModel.filesToRename.isEmpty {
                emptyStateView
            } else {
                previewGrid
            }
        }
    }
    
    // MARK: - Header Section
    private var previewHeader: some View {
        VStack(spacing: 16) {
            // Title and summary
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview Changes")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("\(filteredOperations.count) of \(coordinator.viewModel.filesToRename.count) files")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Quick stats
                previewStats
            }
            
            // Controls
            HStack(spacing: 16) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search files...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Constants.Colors.cardBackground)
                .cornerRadius(8)
                .frame(maxWidth: 300)
                
                // Filter
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(PreviewFilter.allCases, id: \.self) { filter in
                        Label(filter.title, systemImage: filter.icon)
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                
                Spacer()
            }
        }
        .padding()
        .background(Constants.Colors.surface)
    }
    
    private var previewStats: some View {
        HStack(spacing: 20) {
            StatBadge(
                icon: "checkmark.circle.fill",
                title: "Ready",
                count: coordinator.viewModel.filesToRename.filter { !$0.hasConflict }.count,
                color: Constants.Colors.successGreen
            )
            
            if coordinator.viewModel.conflictCount > 0 {
                StatBadge(
                    icon: "exclamationmark.triangle.fill",
                    title: "Conflicts",
                    count: coordinator.viewModel.conflictCount,
                    color: Constants.Colors.warningOrange
                )
            }
            
            if let poseIssues = coordinator.viewModel.poseCountValidation?.playersWithIssues.count, poseIssues > 0 {
                StatBadge(
                    icon: "person.2.badge.minus",
                    title: "Pose Issues",
                    count: poseIssues,
                    color: Constants.Colors.warningOrange
                )
            }
        }
    }
    
    // MARK: - Preview List
    private var previewGrid: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(filteredOperations.enumerated()), id: \.offset) { index, operation in
                    BeforeAfterRow(
                        operation: operation,
                        onPreview: {
                            openPreview(for: operation, at: index)
                        }
                    )
                    .contextMenu {
                        contextMenuItems(for: operation)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("No Photos to Rename")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Go back to setup and make sure you've selected the right folder and naming source.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Button("← Back to Setup") {
                coordinator.goToStep(.setup)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Context Menu
    @ViewBuilder
    private func contextMenuItems(for operation: RenameOperation) -> some View {
        Button("Preview Image") {
            if let index = filteredOperations.firstIndex(where: { $0.id == operation.id }) {
                openPreview(for: operation, at: index)
            }
        }
        
        if operation.hasConflict {
            Button("Fix Conflict") {
                coordinator.goToStep(.resolveIssues)
            }
        }
        
        Divider()
        
        Button("Copy Original Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(operation.originalName, forType: .string)
        }
        
        Button("Copy New Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(operation.newName, forType: .string)
        }
    }
    
    // MARK: - Helper Properties
    private var filteredOperations: [RenameOperation] {
        var operations = coordinator.viewModel.filesToRename
        
        // Apply search filter
        if !searchText.isEmpty {
            operations = operations.filter { operation in
                operation.originalName.localizedCaseInsensitiveContains(searchText) ||
                operation.newName.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Apply category filter
        switch selectedFilter {
        case .all:
            break
        case .conflicts:
            operations = operations.filter { $0.hasConflict }
        case .ready:
            operations = operations.filter { !$0.hasConflict }
        }
        
        // Sort by renamed player name
        operations = operations.sorted { op1, op2 in
            op1.newName.localizedStandardCompare(op2.newName) == .orderedAscending
        }
        
        return operations
    }
    
    // MARK: - Helper Methods
    private func openPreview(for operation: RenameOperation, at index: Int) {
        coordinator.openImagePreview(for: operation, at: index, from: filteredOperations)
    }
}

// MARK: - Before/After Row Component
struct BeforeAfterRow: View {
    let operation: RenameOperation
    let onPreview: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 16) {
            // Status indicator
            Image(systemName: operation.hasConflict ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(operation.hasConflict ? Constants.Colors.warningOrange : Constants.Colors.successGreen)
                .frame(width: 20)
            
            // Original filename
            VStack(alignment: .leading, spacing: 2) {
                Text("Original")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(operation.originalName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Arrow
            Image(systemName: "arrow.right")
                .foregroundColor(Constants.Colors.brandTint)
                .frame(width: 20)
            
            // New filename
            VStack(alignment: .leading, spacing: 2) {
                Text("New Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(operation.newName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(operation.hasConflict ? Constants.Colors.warningOrange : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Preview button
            Button("Preview") {
                onPreview?()
            }
            .buttonStyle(.borderless)
            .foregroundColor(Constants.Colors.brandTint)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(operation.hasConflict ? Constants.Colors.warningOrange : Constants.Colors.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Preview Filter Enum
private enum PreviewFilter: String, CaseIterable {
    case all = "all"
    case conflicts = "conflicts"
    case ready = "ready"
    
    var title: String {
        switch self {
        case .all: return "All Files"
        case .conflicts: return "Conflicts"
        case .ready: return "Ready"
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "photo.stack"
        case .conflicts: return "exclamationmark.triangle"
        case .ready: return "checkmark.circle"
        }
    }
}

// MARK: - Stat Badge Component
private struct StatBadge: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            
            Text("\(count)")
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(16)
    }
}

// MARK: - Preview
#if DEBUG
struct RenamePreviewStepView_Previews: PreviewProvider {
    static var previews: some View {
        RenamePreviewStepView(
            coordinator: RenameWizardCoordinator(
                jobFolder: URL(fileURLWithPath: "/tmp/test"),
                jobManager: JobManager()
            )
        )
    }
}
#endif
