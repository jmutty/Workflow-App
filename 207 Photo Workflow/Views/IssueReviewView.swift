import SwiftUI
import AppKit

// MARK: - Individual Issue Review View
struct IssueReviewView: View {
    let issues: [ValidationIssue]
    let jobFolderPath: String
    let onDismiss: () -> Void
    let onImagePreview: ((URL, [URL], Int) -> Void)?
    
    @StateObject private var flagStore = IssueFlagStore()
    @State private var currentIssueIndex = 0
    @State private var showingImagePreview = false
    @State private var selectedImageURL: URL?
    @State private var previewImageURLs: [URL] = []
    @State private var previewStartIndex = 0
    
    private var unflaggedIssues: [ValidationIssue] {
        issues.filter { !flagStore.isDismissed($0.id) }
    }
    
    private var currentIssue: ValidationIssue? {
        guard currentIssueIndex < unflaggedIssues.count else { return nil }
        return unflaggedIssues[currentIssueIndex]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            if unflaggedIssues.isEmpty {
                emptyStateView
            } else {
                // Main content
                HSplitView {
                    // Left: scrollable issue details
                    ScrollView {
                        issueDetailsSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 350, idealWidth: 400, maxWidth: 450)
                    
                    // Right: static image previews
                    imagePreviewSection
                        .frame(minWidth: 550, maxWidth: .infinity)
                }
            }
            
            Divider()
            
            // Footer with navigation and actions
            footerSection
        }
        .frame(width: 1000, height: 700)
        .background(
            KeyCatcher { keyCode in
                switch keyCode {
                case 53: // Escape
                    onDismiss()
                case 123: // Left arrow
                    moveToPreviousIssue()
                case 124: // Right arrow
                    moveToNextIssue()
                default:
                    break
                }
            }
        )
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Issue Review")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if !unflaggedIssues.isEmpty {
                    Text("Issue \(currentIssueIndex + 1) of \(unflaggedIssues.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button("Close") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Constants.Colors.successGreen)
            
            Text("All Issues Reviewed")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("You've reviewed all validation issues for this job.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Issue Details Section
    private var issueDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let issue = currentIssue {
                // Issue severity and message
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(severityColor(issue.severity))
                            .frame(width: 12, height: 12)
                        
                        Text(issue.severity.rawValue.capitalized)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(severityColor(issue.severity))
                        
                        // Show issue category
                        if issue.message.contains("poses") {
                            Text("• Pose Count")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if issue.message.contains("invalid characters") {
                            Text("• Invalid Filename")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if issue.message.contains("not found in CSV") {
                            Text("• Missing from CSV")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Text(issue.message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if let suggestion = issue.suggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                // Affected files list
                if !issue.affectedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Affected Files (\(issue.affectedFiles.count))")
                            .font(.headline)
                        
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(issue.affectedFiles, id: \.self) { fileURL in
                                    Button(action: {
                                        if let onImagePreview = onImagePreview {
                                            onImagePreview(fileURL, issue.affectedFiles, issue.affectedFiles.firstIndex(of: fileURL) ?? 0)
                                        } else {
                                            selectedImageURL = fileURL
                                            previewImageURLs = issue.affectedFiles
                                            previewStartIndex = issue.affectedFiles.firstIndex(of: fileURL) ?? 0
                                            showingImagePreview = true
                                        }
                                    }) {
                                        HStack {
                                            Image(systemName: "photo")
                                                .foregroundColor(.secondary)
                                            Text(fileURL.lastPathComponent)
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }
                
                Spacer()
                
                // Flagging actions
                flaggingActionsSection(for: issue)
            }
        }
        .padding()
    }
    
    // MARK: - Image Preview Section
    private var imagePreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = currentIssue {
                let isPoseCountIssue = issue.message.contains("poses")
                Text(isPoseCountIssue ? "All Player Photos (\(issue.affectedFiles.count))" : "Image Previews")
                    .font(.headline)
            } else {
                Text("Image Previews")
                    .font(.headline)
            }
            
            if let issue = currentIssue, !issue.affectedFiles.isEmpty {
                let isPoseCountIssue = issue.message.contains("poses")
                let columns = isPoseCountIssue ? [
                    // Larger grid for pose count issues to see all player photos
                    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 12)
                ] : [
                    // Standard grid for other issues - also increased for better visibility
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 10)
                ]
                
                LazyVGrid(columns: columns, spacing: isPoseCountIssue ? 12 : 8) {
                    ForEach(issue.affectedFiles, id: \.self) { fileURL in
                        ThumbnailPreviewCard(
                            imageURL: fileURL,
                            isLarge: isPoseCountIssue,
                            onTap: {
                                if let onImagePreview = onImagePreview {
                                    onImagePreview(fileURL, issue.affectedFiles, issue.affectedFiles.firstIndex(of: fileURL) ?? 0)
                                } else {
                                    selectedImageURL = fileURL
                                    previewImageURLs = issue.affectedFiles
                                    previewStartIndex = issue.affectedFiles.firstIndex(of: fileURL) ?? 0
                                    showingImagePreview = true
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            } else {
                VStack {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No images associated with this issue")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }
    
    // MARK: - Flagging Actions
    private func flaggingActionsSection(for issue: ValidationIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)
            
            ForEach(IssueFlag.allCases, id: \.self) { flag in
                Button(action: {
                    flagStore.flagIssue(issue, flag: flag, jobFolderPath: jobFolderPath)
                    
                    // Move to next issue immediately for all flags
                    // Small delay to allow the UI to update the flagStore state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        moveToNextIssue()
                    }
                }) {
                    HStack {
                        Image(systemName: flag.iconName)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flag.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(flag.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(flag.backgroundColor)
                    .foregroundColor(flag.foregroundColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Footer Section
    private var footerSection: some View {
        HStack {
            // Navigation buttons
            if unflaggedIssues.count > 1 {
                HStack(spacing: 8) {
                    Button("Previous") {
                        moveToPreviousIssue()
                    }
                    .disabled(unflaggedIssues.count <= 1)
                    .buttonStyle(.bordered)
                    
                    Button("Next") {
                        moveToNextIssue()
                    }
                    .disabled(unflaggedIssues.count <= 1)
                    .buttonStyle(.bordered)
                }
            }
            
            Spacer()
            
            // Progress indicator
            if !unflaggedIssues.isEmpty {
                HStack(spacing: 4) {
                    ForEach(0..<min(unflaggedIssues.count, 10), id: \.self) { index in
                        Circle()
                            .fill(index == currentIssueIndex ? Constants.Colors.brandTint : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                    
                    if unflaggedIssues.count > 10 {
                        Text("...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Helper Methods
    private func severityColor(_ severity: ValidationSeverity) -> Color {
        switch severity {
        case .error: return Constants.Colors.errorRed
        case .warning: return Constants.Colors.warningOrange
        case .info: return .secondary
        }
    }
    
    private func moveToNextIssue() {
        // Check if we have any unflagged issues left after the current state update
        if unflaggedIssues.isEmpty {
            onDismiss()
            return
        }
        
        // If the current index is now beyond the available issues, reset to 0
        if currentIssueIndex >= unflaggedIssues.count {
            if unflaggedIssues.isEmpty {
                onDismiss()
                return
            } else {
                currentIssueIndex = 0
            }
        } else if currentIssueIndex < unflaggedIssues.count - 1 {
            // Move to next issue if available
            currentIssueIndex += 1
        } else {
            // We're at the last issue, cycle to beginning or close if no more issues
            if unflaggedIssues.count > 1 {
                currentIssueIndex = 0
            } else {
                // This was the last issue and it's been dismissed
                onDismiss()
            }
        }
    }
    
    private func moveToPreviousIssue() {
        if unflaggedIssues.isEmpty {
            return
        }
        
        if currentIssueIndex > 0 {
            currentIssueIndex -= 1
        } else {
            // Cycle to the last issue
            currentIssueIndex = unflaggedIssues.count - 1
        }
    }
}

// MARK: - Thumbnail Preview Card
private struct ThumbnailPreviewCard: View {
    let imageURL: URL
    let isLarge: Bool
    let onTap: () -> Void
    
    init(imageURL: URL, isLarge: Bool = false, onTap: @escaping () -> Void) {
        self.imageURL = imageURL
        self.isLarge = isLarge
        self.onTap = onTap
    }
    
    var body: some View {
        let height: CGFloat = isLarge ? 200 : 160
        
        Button(action: onTap) {
            VStack(spacing: 4) {
                AsyncImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: height)
                        .cornerRadius(8)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: height)
                        .frame(width: height) // Square placeholder since we don't know aspect ratio yet
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        )
                }
                
                if isLarge {
                    Text(imageURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .help(imageURL.lastPathComponent)
    }
}

// MARK: - IssueFlag Extensions
extension IssueFlag {
    var iconName: String {
        switch self {
        case .dismiss: return "eye.slash"
        case .addressOutside: return "arrow.up.right.square"
        case .addressInCSV: return "tablecells"
        }
    }
    
    var backgroundColor: Color {
        switch self {
        case .dismiss: return Color.secondary.opacity(0.1)
        case .addressOutside: return Constants.Colors.warningOrange.opacity(0.1)
        case .addressInCSV: return Constants.Colors.brandTint.opacity(0.1)
        }
    }
    
    var foregroundColor: Color {
        switch self {
        case .dismiss: return .secondary
        case .addressOutside: return Constants.Colors.warningOrange
        case .addressInCSV: return Constants.Colors.brandTint
        }
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
        
        override var acceptsFirstResponder: Bool { true }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        
        override func keyDown(with event: NSEvent) {
            onKeyDown?(event.keyCode)
        }
    }
}
