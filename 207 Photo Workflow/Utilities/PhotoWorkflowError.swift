import Foundation

// MARK: - Main Error Type
enum PhotoWorkflowError: LocalizedError {
    // File System Errors
    case fileNotFound(path: String)
    case folderNotFound(name: String)
    case accessDenied(path: String)
    case unableToCreateFolder(path: String, underlyingError: Error?)
    case unableToReadFile(path: String, underlyingError: Error?)
    case unableToWriteFile(path: String, underlyingError: Error?)
    case insufficientDiskSpace(required: Int64, available: Int64)
    
    // Operation Errors
    case renameConflict(fileName: String, count: Int)
    case fileAlreadyExists(path: String)
    case noFilesToProcess
    case operationCancelled
    case operationInProgress
    
    // CSV Errors
    case invalidCSVFormat(details: String)
    case csvParsingError(line: Int, reason: String)
    case missingCSVHeaders
    case csvEncodingError(encoding: String)
    case noCSVDataFound
    
    // Image Errors
    case invalidImageFormat(fileName: String)
    case corruptedImage(fileName: String)
    case unsupportedImageType(type: String)
    
    // Template Errors
    case templateNotFound(templateName: String)
    case invalidTemplateConfiguration(reason: String)
    case noTemplatesConfigured
    
    // Validation Errors
    case missingRequiredFolder(folderName: String)
    case invalidTeamName(name: String)
    case invalidPlayerName(name: String)
    case invalidPoseNumber(number: String)
    case poseCountMismatch(player: String, expected: Int, actual: Int)
    
    // Job Folder Errors
    case noJobFolderSelected
    case invalidJobFolder(reason: String)
    case securityScopeError(path: String)
    
    // Network Errors (for future cloud features)
    case networkError(underlyingError: Error?)
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        // File System Errors
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .folderNotFound(let name):
            return "Folder not found: \(name)"
        case .accessDenied(let path):
            return "Access denied to: \(path)"
        case .unableToCreateFolder(let path, _):
            return "Unable to create folder at: \(path)"
        case .unableToReadFile(let path, _):
            return "Unable to read file: \(path)"
        case .unableToWriteFile(let path, _):
            return "Unable to write file: \(path)"
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space. Required: \(formatBytes(required)), Available: \(formatBytes(available))"
            
        // Operation Errors
        case .renameConflict(let fileName, let count):
            return "Naming conflict: \(count) files would be renamed to '\(fileName)'"
        case .fileAlreadyExists(let path):
            return "File already exists: \(path)"
        case .noFilesToProcess:
            return "No files found to process"
        case .operationCancelled:
            return "Operation was cancelled"
        case .operationInProgress:
            return "Another operation is currently in progress"
            
        // CSV Errors
        case .invalidCSVFormat(let details):
            return "Invalid CSV format: \(details)"
        case .csvParsingError(let line, let reason):
            return "CSV parsing error at line \(line): \(reason)"
        case .missingCSVHeaders:
            return "CSV file is missing required headers"
        case .csvEncodingError(let encoding):
            return "Unable to read CSV with encoding: \(encoding)"
        case .noCSVDataFound:
            return "No CSV data file found in job folder"
            
        // Image Errors
        case .invalidImageFormat(let fileName):
            return "Invalid image format: \(fileName)"
        case .corruptedImage(let fileName):
            return "Corrupted image file: \(fileName)"
        case .unsupportedImageType(let type):
            return "Unsupported image type: \(type)"
            
        // Template Errors
        case .templateNotFound(let templateName):
            return "Template not found: \(templateName)"
        case .invalidTemplateConfiguration(let reason):
            return "Invalid template configuration: \(reason)"
        case .noTemplatesConfigured:
            return "No templates have been configured"
            
        // Validation Errors
        case .missingRequiredFolder(let folderName):
            return "Required folder missing: \(folderName)"
        case .invalidTeamName(let name):
            return "Invalid team name: \(name)"
        case .invalidPlayerName(let name):
            return "Invalid player name: \(name)"
        case .invalidPoseNumber(let number):
            return "Invalid pose number: \(number)"
        case .poseCountMismatch(let player, let expected, let actual):
            return "Pose count mismatch for \(player): expected \(expected), found \(actual)"
            
        // Job Folder Errors
        case .noJobFolderSelected:
            return "No job folder has been selected"
        case .invalidJobFolder(let reason):
            return "Invalid job folder: \(reason)"
        case .securityScopeError(let path):
            return "Unable to access folder due to security restrictions: \(path)"
            
        // Network Errors
        case .networkError:
            return "Network error occurred"
        case .authenticationRequired:
            return "Authentication required"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        // File System Errors
        case .fileNotFound:
            return "Check that the file exists and hasn't been moved or deleted."
        case .folderNotFound:
            return "Create the required folder or select a different job folder."
        case .accessDenied:
            return "Check file permissions or try running the app with appropriate privileges."
        case .unableToCreateFolder:
            return "Check that you have write permissions for the location."
        case .unableToReadFile:
            return "Ensure the file is not locked by another application."
        case .unableToWriteFile:
            return "Check disk space and write permissions."
        case .insufficientDiskSpace:
            return "Free up disk space or choose a different destination."
            
        // Operation Errors
        case .renameConflict:
            return "Review the naming pattern or enable conflict resolution options."
        case .fileAlreadyExists:
            return "Remove the existing file or enable overwrite option."
        case .noFilesToProcess:
            return "Ensure files are in the correct folder and match expected patterns."
        case .operationCancelled:
            return "Restart the operation if needed."
        case .operationInProgress:
            return "Wait for the current operation to complete."
            
        // CSV Errors
        case .invalidCSVFormat:
            return "Check that the CSV file follows the expected format."
        case .csvParsingError:
            return "Review the CSV file for formatting issues at the specified line."
        case .missingCSVHeaders:
            return "Ensure the CSV file has the required header row."
        case .csvEncodingError:
            return "Save the CSV file with UTF-8 encoding."
        case .noCSVDataFound:
            return "Place a CSV data file in the job folder root."
            
        // Image Errors
        case .invalidImageFormat:
            return "Use supported image formats: JPEG, PNG, or TIFF."
        case .corruptedImage:
            return "Try re-exporting or re-saving the image file."
        case .unsupportedImageType:
            return "Convert the image to a supported format."
            
        // Template Errors
        case .templateNotFound:
            return "Select a valid template file."
        case .invalidTemplateConfiguration:
            return "Review and correct the template settings."
        case .noTemplatesConfigured:
            return "Configure at least one template before proceeding."
            
        // Validation Errors
        case .missingRequiredFolder:
            return "Create the folder or let the app create it automatically."
        case .invalidTeamName:
            return "Use only letters, numbers, and basic punctuation in team names."
        case .invalidPlayerName:
            return "Check the player name format in the source data."
        case .invalidPoseNumber:
            return "Use numeric pose numbers (1, 2, 3, etc.)"
        case .poseCountMismatch:
            return "Check source files or adjust the expected pose count."
            
        // Job Folder Errors
        case .noJobFolderSelected:
            return "Select a job folder to begin."
        case .invalidJobFolder:
            return "Select a valid job folder with the correct structure."
        case .securityScopeError:
            return "Grant folder access when prompted or select a different folder."
            
        // Network Errors
        case .networkError:
            return "Check your internet connection and try again."
        case .authenticationRequired:
            return "Sign in to continue."
        }
    }
    
    var failureReason: String? {
        errorDescription
    }
    
    // Helper function for formatting bytes
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Error Result Type
typealias PhotoWorkflowResult<T> = Result<T, PhotoWorkflowError>

// MARK: - Error Recovery Actions
enum ErrorRecoveryAction {
    case retry
    case skip
    case cancel
    case useDefault
    case createMissing
    case overwrite
    case rename
}

// MARK: - Error Context
struct ErrorContext {
    let error: PhotoWorkflowError
    let operation: String
    let affectedFiles: [URL]
    let timestamp: Date
    let recoveryOptions: [ErrorRecoveryAction]
    
    init(error: PhotoWorkflowError,
         operation: String,
         affectedFiles: [URL] = [],
         recoveryOptions: [ErrorRecoveryAction] = [.retry, .cancel]) {
        self.error = error
        self.operation = operation
        self.affectedFiles = affectedFiles
        self.timestamp = Date()
        self.recoveryOptions = recoveryOptions
    }
}
