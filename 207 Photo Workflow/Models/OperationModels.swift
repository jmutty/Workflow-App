import Foundation
import SwiftUI

// MARK: - Operation Type
enum Operation: String, CaseIterable, Identifiable, Codable {
    case renameFiles = "Rename Files"
    case sortIntoTeams = "Sort Into Teams"
    case createSPACSV = "Create SPA-Ready CSV"
    case sortTeamPhotos = "Sort Team Photos"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .renameFiles:
            return "pencil.and.outline"
        case .sortIntoTeams:
            return "folder.badge.plus"
        case .createSPACSV:
            return "doc.text"
        case .sortTeamPhotos:
            return "photo.stack"
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
        case .sortTeamPhotos:
            return "Move team photos to upload folders"
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
        case .sortTeamPhotos:
            return [Constants.Folders.finishedTeams]
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
            return Constants.Colors.primaryGradientStart
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
    
    var folderName: String {
        rawValue
    }
    
    func url(in jobFolder: URL) -> URL {
        jobFolder.appendingPathComponent(folderName)
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
        var dataSource: DataSource = .csv
        var handleConflicts: ConflictHandling = .skip
        var dryRun: Bool = true
        var createBackupBeforeRename: Bool = true
        var exportDryRunReport: Bool = true
        
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

struct ValidationIssue: Identifiable {
    let id = UUID()
    let severity: ValidationSeverity
    let message: String
    let suggestion: String?
}

struct ValidationReport {
    let operation: Operation
    let issues: [ValidationIssue]
    let requiredDiskSpace: Int64?
    let availableDiskSpace: Int64?
    
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
