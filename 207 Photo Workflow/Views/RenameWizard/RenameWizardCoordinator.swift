import SwiftUI

// MARK: - Wizard Step Definition
enum RenameWizardStep: Int, CaseIterable {
    case setup = 0
    case preview = 1
    case resolveIssues = 2
    case execute = 3
    
    var title: String {
        switch self {
        case .setup: return "Setup"
        case .preview: return "Preview Changes"
        case .resolveIssues: return "Fix Issues"
        case .execute: return "Rename Files"
        }
    }
    
    var icon: String {
        switch self {
        case .setup: return "gearshape.fill"
        case .preview: return "eye.fill"
        case .resolveIssues: return "wrench.and.screwdriver.fill"
        case .execute: return "play.fill"
        }
    }
    
    var description: String {
        switch self {
        case .setup: return "Choose source and naming method"
        case .preview: return "Review proposed file names"
        case .resolveIssues: return "Handle conflicts and pose issues"
        case .execute: return "Apply changes to your files"
        }
    }
}

// MARK: - Wizard State
@MainActor
class RenameWizardCoordinator: ObservableObject {
    @Published var currentStep: RenameWizardStep = .setup
    @Published var canProceedToNext: Bool = false
    @Published var canGoBack: Bool = false
    @Published var issueCount: Int = 0
    @Published var hasUnresolvedIssues: Bool = false
    @Published var resolvedIssueIds: Set<String> = [] // Persistent across navigation
    
    // Image Preview Properties
    @Published var showingImagePreview: Bool = false
    @Published var selectedImageOperation: RenameOperation?
    @Published var previewImageURLs: [URL] = []
    @Published var previewStartIndex: Int = 0
    
    // Dependencies
    let jobFolder: URL
    let jobManager: JobManager
    @Published var viewModel: FileRenamerViewModel
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        self.viewModel = FileRenamerViewModel(jobFolder: jobFolder)
        updateNavigationState()
    }
    
    // MARK: - Navigation Methods
    func goToNext() {
        guard canProceedToNext else { return }
        
        // Skip issues step if no issues to resolve
        if currentStep == .preview && !hasUnresolvedIssues {
            currentStep = .execute
        } else if let nextStep = RenameWizardStep(rawValue: currentStep.rawValue + 1) {
            currentStep = nextStep
        }
        
        updateNavigationState()
    }
    
    func goBack() {
        guard canGoBack else { return }
        
        // Skip issues step when going back if no issues
        if currentStep == .execute && !hasUnresolvedIssues {
            currentStep = .preview
        } else if let prevStep = RenameWizardStep(rawValue: currentStep.rawValue - 1) {
            currentStep = prevStep
        }
        
        updateNavigationState()
    }
    
    func goToStep(_ step: RenameWizardStep) {
        currentStep = step
        updateNavigationState()
    }
    
    // MARK: - Image Preview Methods
    func openImagePreview(for operation: RenameOperation, at index: Int, from operations: [RenameOperation]) {
        selectedImageOperation = operation
        previewImageURLs = operations.map { $0.sourceURL }
        previewStartIndex = index
        showingImagePreview = true
    }
    
    // MARK: - CSV Editor Methods
    func openCSVEditor() {
        // Find and open the CSV file in the job folder
        let csvFiles = findCSVFiles()
        if let csvFile = csvFiles.first {
            NSWorkspace.shared.open(csvFile)
        } else {
            // No CSV file found - could show an alert or create one
            print("No CSV file found in job folder")
        }
    }
    
    private func findCSVFiles() -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: jobFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var csvFiles: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "csv" {
                csvFiles.append(url)
            }
        }
        return csvFiles
    }
    
    // MARK: - State Management
    func updateFromViewModel() {
        // Calculate total issues including pose count problems
        let validationIssues = (viewModel.validationReport?.errorCount ?? 0) + (viewModel.validationReport?.warningCount ?? 0)
        let poseIssues = viewModel.poseCountValidation?.playersWithIssues.count ?? 0
        let conflictIssues = viewModel.conflictCount
        
        issueCount = validationIssues + poseIssues + conflictIssues
        hasUnresolvedIssues = issueCount > 0
        
        updateNavigationState()
    }
    
    private func updateNavigationState() {
        // Update navigation availability based on current step and state
        canGoBack = currentStep != .setup
        
        switch currentStep {
        case .setup:
            canProceedToNext = true // Always allow proceeding from setup
            
        case .preview:
            canProceedToNext = !viewModel.filesToRename.isEmpty
            
        case .resolveIssues:
            // Can proceed if willing to accept remaining issues
            canProceedToNext = true
            
        case .execute:
            canProceedToNext = false // Final step
        }
    }
    
    // MARK: - Issue Resolution Helpers
    func getIssuesSummary() -> (conflicts: Int, poseIssues: Int, validationIssues: Int) {
        let conflicts = viewModel.conflictCount
        let poseIssues = viewModel.poseCountValidation?.playersWithIssues.count ?? 0
        let validationIssues = (viewModel.validationReport?.errorCount ?? 0) + (viewModel.validationReport?.warningCount ?? 0)
        
        return (conflicts: conflicts, poseIssues: poseIssues, validationIssues: validationIssues)
    }
    
    func shouldShowIssuesStep() -> Bool {
        return hasUnresolvedIssues
    }
    
    // MARK: - Resolved Issues Management
    
    func markIssueAsResolved(_ issueId: String) {
        resolvedIssueIds.insert(issueId)
        print("✅ Marked issue as resolved: \(issueId)")
        print("✅ Total resolved issues: \(resolvedIssueIds.count)")
    }
    
    func isIssueResolved(_ issueId: String) -> Bool {
        return resolvedIssueIds.contains(issueId)
    }
    
    func clearResolvedIssues() {
        resolvedIssueIds.removeAll()
        print("🗑️ Cleared all resolved issues")
    }
    
    func getResolvedIssuesCount() -> Int {
        return resolvedIssueIds.count
    }
}
