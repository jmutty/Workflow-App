import Foundation
import SwiftUI

// MARK: - Operation Type
enum Operation: String, CaseIterable, Identifiable, Codable {
    case renameFiles = "Rename Files"
    case sortIntoTeams = "Sort Into Teams"
    case createSPACSV = "Create SPA-Ready CSV"
    case createSeniorBannersCSV = "Create Senior Banner CSV"
    case sortTeamPhotos = "Sort Team & Alt Background PNGs"
    case adminMode = "Admin Mode"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .renameFiles:
            return "pencil.and.outline"
        case .sortIntoTeams:
            return "folder.badge.plus"
        case .createSPACSV:
            return "doc.text"
        case .createSeniorBannersCSV:
            return "flag.checkered"
        case .sortTeamPhotos:
            return "photo.stack"
        case .adminMode:
            return "gearshape"
        }
    }
    
    var description: String {
        switch self {
        case .renameFiles:
            return "Rename photos to standard format"
        case .sortIntoTeams:
            return "Organize photos into team folders"
        case .createSPACSV:
            return "Generate CSV for SPA processing"
        case .createSeniorBannersCSV:
            return "Parse order data, generate Senior Banners CSV, and copy banner PNGs"
        case .sortTeamPhotos:
            return "Move team photos and ALT background PNGs to upload folders"
        case .adminMode:
            return "Sample from capture and rate images"
        }
    }
    
    var requiredFolders: [String] {
        switch self {
        case .renameFiles:
            return [Constants.Folders.extracted]
        case .sortIntoTeams:
            return [Constants.Folders.extracted]
        case .createSPACSV:
            return [Constants.Folders.extracted]
        case .createSeniorBannersCSV:
            return [Constants.Folders.extracted]
        case .sortTeamPhotos:
            return [Constants.Folders.finishedTeams]
        case .adminMode:
            return [Constants.Folders.capture]
        }
    }
}

// MARK: - Operation Status
enum OperationStatus: Equatable {
    case ready
    case running(progress: Double?)
    case completed(Date)
    case error(String)
    case cancelled
    
    var description: String {
        switch self {
        case .ready:
            return "Ready"
        case .running(let progress):
            if let progress = progress {
                return "Running... \(Int(progress * 100))%"
            }
            return "Running..."
        case .completed:
            return "Completed"
        case .error(let message):
            return "Error: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
    
    var color: Color {
        switch self {
        case .ready:
            return Constants.Colors.brandTint
        case .running:
            return Constants.Colors.warningOrange
        case .completed:
            return Constants.Colors.successGreen
        case .error:
            return Constants.Colors.errorRed
        case .cancelled:
            return .secondary
        }
    }
    
    var isActive: Bool {
        if case .running = self {
            return true
        }
        return false
    }
    
    var canStart: Bool {
        switch self {
        case .ready, .completed, .error, .cancelled:
            return true
        case .running:
            return false
        }
    }
    
    static func == (lhs: OperationStatus, rhs: OperationStatus) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready),
             (.cancelled, .cancelled):
            return true
        case (.running(let lhsProgress), .running(let rhsProgress)):
            return lhsProgress == rhsProgress
        case (.completed(let lhsDate), .completed(let rhsDate)):
            return lhsDate == rhsDate
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

// MARK: - Source Folder
enum SourceFolder: String, CaseIterable {
    case output = "Output"
    case extracted = "Extracted"
    case custom = "Custom"
    
    var folderName: String {
        rawValue
    }
    
    func url(in jobFolder: URL, customPath: URL? = nil) -> URL {
        switch self {
        case .output, .extracted:
            return jobFolder.appendingPathComponent(folderName)
        case .custom:
            return customPath ?? jobFolder.appendingPathComponent("Custom")
        }
    }
}

// MARK: - Data Source
enum DataSource: String, CaseIterable {
    case csv = "CSV Data"
    case filenames = "Filenames"
    
    var description: String {
        switch self {
        case .csv:
            return "Use data from CSV file"
        case .filenames:
            return "Parse data from filenames"
        }
    }
    
    var requiresCSV: Bool {
        self == .csv
    }
}

// MARK: - Operation Configuration
struct OperationConfig {
    // Rename Files Configuration
    struct RenameConfig {
        var sourceFolder: SourceFolder = .extracted
        var customSourcePath: URL? = nil
        var dataSource: DataSource = .csv
        var handleConflicts: ConflictHandling = .skip
            // Default behavior: do not block on preflight errors
            var bypassPreflightErrors: Bool = true
        var dryRun: Bool = true
        var createBackupBeforeRename: Bool = true
        var exportDryRunReport: Bool = true
        var handleBuddySeparately: Bool = true
        
        enum ConflictHandling {
            case skip
            case overwrite
            case addSuffix
        }
    }
    
    // Sort Into Teams Configuration
    struct SortConfig {
        var selectedPose: String = Constants.Validation.defaultPoseNumber
        var copyTeamPhotos: Bool = true
        var processCoachFiles: Bool = true
        var createTeamFolders: Bool = true
        var overwriteExisting: Bool = false
    }
    
    // Create SPA CSV Configuration
    struct CSVConfig {
        var templateMode: TemplateMode = .sameForAll
        var includeManualPhotos: Bool = true
        var generateBackup: Bool = true
    }
    
    // Sort Team Photos Configuration
    struct TeamPhotosConfig {
        var overwriteExisting: Bool = false
        var createMissingFolders: Bool = true
        var copyMode: CopyMode = .copy
        
        enum CopyMode {
            case copy
            case move
        }
    }
}

// MARK: - Validation Models
enum ValidationSeverity: String {
    case error
    case warning
    case info
}

struct ValidationIssue: Identifiable, Equatable {
    let id = UUID()
    let severity: ValidationSeverity
    let message: String
    let suggestion: String?
    let affectedFiles: [URL]
    
    static func == (lhs: ValidationIssue, rhs: ValidationIssue) -> Bool {
        lhs.id == rhs.id
    }
    
    // Convenience initializer for backwards compatibility
    init(severity: ValidationSeverity, message: String, suggestion: String?, affectedFiles: [URL] = []) {
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
        self.affectedFiles = affectedFiles
    }
}

struct ValidationReport: Equatable {
    let operation: Operation
    let issues: [ValidationIssue]
    let requiredDiskSpace: Int64?
    let availableDiskSpace: Int64?
    
    static func == (lhs: ValidationReport, rhs: ValidationReport) -> Bool {
        lhs.operation == rhs.operation &&
        lhs.issues.count == rhs.issues.count &&
        lhs.requiredDiskSpace == rhs.requiredDiskSpace &&
        lhs.availableDiskSpace == rhs.availableDiskSpace
    }
    
    var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }
    
    var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }
    
    var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }
}

// MARK: - Operation Result
struct OperationResult {
    let operation: Operation
    let status: OperationStatus
    let startTime: Date
    let endTime: Date?
    let filesProcessed: Int
    let errors: [Error]
    let warnings: [String]
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "In progress" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "Unknown"
    }
    
    var success: Bool {
        if case .completed = status {
            return errors.isEmpty
        }
        return false
    }
}

// MARK: - Operation Progress
struct OperationProgress {
    let operation: Operation
    let currentFile: String?
    let filesCompleted: Int
    let totalFiles: Int
    let currentStep: String
    let estimatedTimeRemaining: TimeInterval?
    
    var percentComplete: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(filesCompleted) / Double(totalFiles)
    }
    
    var formattedTimeRemaining: String? {
        guard let time = estimatedTimeRemaining else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: time)
    }
}

// MARK: - Batch Operation
struct BatchOperation: Identifiable {
    let id = UUID()
    let operations: [Operation]
    let configurations: [Operation: Any]
    let name: String
    let createdDate: Date
    
    var operationCount: Int {
        operations.count
    }
}

// MARK: - Rename Revert Models
struct RenameBackupInfo: Identifiable, Equatable {
    let id = UUID()
    let csvURL: URL
    let timestamp: Date
    let fileCount: Int
    let sourceFolder: String // e.g., "Extracted", "Output"
    
    static func == (lhs: RenameBackupInfo, rhs: RenameBackupInfo) -> Bool {
        lhs.csvURL == rhs.csvURL &&
        lhs.timestamp == rhs.timestamp &&
        lhs.fileCount == rhs.fileCount &&
        lhs.sourceFolder == rhs.sourceFolder
    }
}

struct RevertOperation: Identifiable, Equatable {
    let id = UUID()
    let currentURL: URL
    let originalURL: URL
    let currentName: String
    let originalName: String
    let status: RevertStatus
    
    enum RevertStatus: Equatable {
        case pending
        case notFound
        case conflictAtDestination
        case ready
    }
    
    var canRevert: Bool {
        status == .ready
    }
    
    static func == (lhs: RevertOperation, rhs: RevertOperation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Issue Flag Models
enum IssueFlag: String, CaseIterable, Identifiable {
    case dismiss = "dismiss"
    case addressOutside = "address_outside"
    case addressInCSV = "address_in_csv"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .dismiss:
            return "Dismiss Issue"
        case .addressOutside:
            return "Address Outside App"
        case .addressInCSV:
            return "Address in CSV"
        }
    }
    
    var description: String {
        switch self {
        case .dismiss:
            return "Hide this issue from future reviews"
        case .addressOutside:
            return "I will fix this outside the app"
        case .addressInCSV:
            return "I will edit the CSV to fix this"
        }
    }
}

@MainActor
class IssueFlagStore: ObservableObject {
    @Published private var dismissedIssues: Set<UUID> = []
    @Published private var flaggedIssues: [UUID: IssueFlag] = [:]
    
    private var flagFileURL: URL?
    
    init() {
        // We'll store flags in memory for now
        // Could be extended to persist to disk if needed
    }
    
    func isDismissed(_ issueId: UUID) -> Bool {
        return dismissedIssues.contains(issueId) || flaggedIssues[issueId] != nil
    }
    
    func flagIssue(_ issue: ValidationIssue, flag: IssueFlag, jobFolderPath: String) {
        switch flag {
        case .dismiss:
            dismissedIssues.insert(issue.id)
        case .addressOutside, .addressInCSV:
            flaggedIssues[issue.id] = flag
        }
        
        // Trigger UI update
        objectWillChange.send()
    }
    
    func clearFlags() {
        dismissedIssues.removeAll()
        flaggedIssues.removeAll()
    }
    
    func getFlaggedIssues() -> [UUID: IssueFlag] {
        return flaggedIssues
    }
}
