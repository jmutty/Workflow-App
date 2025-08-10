import Foundation
import SwiftUI
import Combine

// MARK: - Job Manager
@MainActor
class JobManager: ObservableObject {
    // MARK: - Published Properties
    @Published var jobFolderURL: URL?
    @Published var operationStatus: [Operation: OperationStatus] = [:]
    @Published var statusMessage: String = "Select a job folder to begin"
    @Published var activeOperation: Operation?
    @Published var operationHistory: [OperationResult] = []
    
    // MARK: - Private Properties
    private var securityScopedBookmark: Data?
    private var fileManager: FileManager
    private var cancellables = Set<AnyCancellable>()
    
    // Store the scoped resource URL separately for cleanup (not Main actor-isolated)
    private var scopedResourceURL: URL?
    
    // MARK: - Computed Properties
    var hasJobFolder: Bool {
        jobFolderURL != nil
    }
    
    var statusColor: Color {
        if let activeOp = activeOperation,
           let status = operationStatus[activeOp] {
            return status.color
        }
        return jobFolderURL != nil ? Constants.Colors.successGreen : Constants.Colors.warningOrange
    }
    
    var isAnyOperationRunning: Bool {
        operationStatus.values.contains { $0.isActive }
    }
    
    // MARK: - Initialization
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        initializeOperationStatuses()
        loadSavedJobFolder()
    }
    
    deinit {
        // Clean up the security scoped resource using the non-isolated property
        scopedResourceURL?.stopAccessingSecurityScopedResource()
    }
    
    // MARK: - Public Methods
    func setJobFolder(_ url: URL) throws {
        // Stop accessing previous folder
        if let previousURL = scopedResourceURL {
            previousURL.stopAccessingSecurityScopedResource()
            scopedResourceURL = nil
        }
        
        // Start accessing new folder
        guard url.startAccessingSecurityScopedResource() else {
            throw PhotoWorkflowError.securityScopeError(path: url.path)
        }
        
        // Store for cleanup
        scopedResourceURL = url
        
        // Create bookmark for future access
        do {
            securityScopedBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            // Save bookmark to UserDefaults
            UserDefaults.standard.set(securityScopedBookmark, forKey: "JobFolderBookmark")
            
            jobFolderURL = url
            try validateJobFolder()
            
        } catch {
            url.stopAccessingSecurityScopedResource()
            scopedResourceURL = nil
            throw PhotoWorkflowError.securityScopeError(path: url.path)
        }
    }
    
    func canStartOperation(_ operation: Operation) -> Bool {
        guard hasJobFolder else { return false }
        guard !isAnyOperationRunning else { return false }
        
        if let status = operationStatus[operation] {
            return status.canStart
        }
        return false
    }
    
    func updateOperationStatus(_ operation: Operation, status: OperationStatus) {
        operationStatus[operation] = status
        
        // Update active operation
        if status.isActive {
            activeOperation = operation
        } else if activeOperation == operation {
            activeOperation = nil
        }
        
        // Update status message
        updateStatusMessage(for: operation, status: status)
        
        // Record completed operations
        if case .completed = status {
            recordOperationCompletion(operation)
        }
    }
    
    func resetOperation(_ operation: Operation) {
        operationStatus[operation] = .ready
        if activeOperation == operation {
            activeOperation = nil
        }
    }
    
    func resetAllOperations() {
        for operation in Operation.allCases {
            operationStatus[operation] = .ready
        }
        activeOperation = nil
        statusMessage = "All operations reset"
    }
    
    // MARK: - Validation
    func validateOperation(_ operation: Operation) throws {
        guard let jobFolder = jobFolderURL else {
            throw PhotoWorkflowError.noJobFolderSelected
        }
        
        // Check required folders
        for folderName in operation.requiredFolders {
            let folderURL = jobFolder.appendingPathComponent(folderName)
            var isDirectory: ObjCBool = false
            
            if !fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                throw PhotoWorkflowError.missingRequiredFolder(folderName: folderName)
            }
        }
        
        // Check if another operation is running
        if isAnyOperationRunning {
            throw PhotoWorkflowError.operationInProgress
        }
    }
    
    func createRequiredFolders(for operation: Operation) throws {
        guard let jobFolder = jobFolderURL else {
            throw PhotoWorkflowError.noJobFolderSelected
        }
        
        for folderName in operation.requiredFolders {
            let folderURL = jobFolder.appendingPathComponent(folderName)
            if !fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
        }
    }
    
    // MARK: - Private Methods
    private func initializeOperationStatuses() {
        for operation in Operation.allCases {
            operationStatus[operation] = .ready
        }
    }
    
    private func loadSavedJobFolder() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "JobFolderBookmark") else {
            return
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if !isStale {
                if url.startAccessingSecurityScopedResource() {
                    scopedResourceURL = url  // Store for cleanup
                    jobFolderURL = url
                    try? validateJobFolder()
                }
            } else {
                // Bookmark is stale, remove it
                UserDefaults.standard.removeObject(forKey: "JobFolderBookmark")
            }
        } catch {
            // Failed to resolve bookmark, remove it
            UserDefaults.standard.removeObject(forKey: "JobFolderBookmark")
        }
    }
    
    private func validateJobFolder() throws {
        guard let jobFolder = jobFolderURL else {
            throw PhotoWorkflowError.noJobFolderSelected
        }
        
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: jobFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PhotoWorkflowError.invalidJobFolder(reason: "Selected path is not a valid folder")
        }
        
        // Check for required folders
        var foundFolders: [String] = []
        for folder in Constants.Folders.requiredFolders {
            let folderURL = jobFolder.appendingPathComponent(folder)
            if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                foundFolders.append(folder)
            }
        }
        
        // Update status message
        if foundFolders.isEmpty {
            statusMessage = "Job folder ready (subfolders will be created as needed)"
        } else {
            statusMessage = "Job folder ready - Found: \(foundFolders.joined(separator: ", "))"
        }
        
        // Reset operation statuses
        for operation in Operation.allCases {
            operationStatus[operation] = .ready
        }
    }
    
    private func updateStatusMessage(for operation: Operation, status: OperationStatus) {
        switch status {
        case .running:
            statusMessage = "\(operation.rawValue) in progress..."
        case .completed:
            statusMessage = "\(operation.rawValue) completed successfully"
        case .error(let message):
            statusMessage = "\(operation.rawValue) failed: \(message)"
        case .cancelled:
            statusMessage = "\(operation.rawValue) cancelled"
        case .ready:
            statusMessage = "Ready for operations"
        }
    }
    
    private func recordOperationCompletion(_ operation: Operation) {
        let result = OperationResult(
            operation: operation,
            status: operationStatus[operation] ?? .ready,
            startTime: Date().addingTimeInterval(-60), // Placeholder
            endTime: Date(),
            filesProcessed: 0, // To be updated by actual operation
            errors: [],
            warnings: []
        )
        operationHistory.append(result)
        
        // Keep only last 50 operations
        if operationHistory.count > 50 {
            operationHistory.removeFirst()
        }
    }
    
    // MARK: - Folder Analysis
    func analyzeJobFolder() -> FileAnalysisResult? {
        guard let jobFolder = jobFolderURL else { return nil }
        
        var totalFiles = 0
        var imageFiles = 0
        var csvFiles = 0
        var otherFiles = 0
        var teams = Set<String>()
        var errors: [Error] = []
        
        // Analyze Output folder
        let outputURL = jobFolder.appendingPathComponent(Constants.Folders.output)
        if let outputAnalysis = analyzeFolder(outputURL) {
            totalFiles += outputAnalysis.totalFiles
            imageFiles += outputAnalysis.imageFiles
            csvFiles += outputAnalysis.csvFiles
            otherFiles += outputAnalysis.otherFiles
            teams.formUnion(outputAnalysis.teams)
            errors.append(contentsOf: outputAnalysis.errors)
        }
        
        // Analyze Extracted folder
        let extractedURL = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        if let extractedAnalysis = analyzeFolder(extractedURL) {
            totalFiles += extractedAnalysis.totalFiles
            imageFiles += extractedAnalysis.imageFiles
            csvFiles += extractedAnalysis.csvFiles
            otherFiles += extractedAnalysis.otherFiles
            teams.formUnion(extractedAnalysis.teams)
            errors.append(contentsOf: extractedAnalysis.errors)
        }
        
        // Check for CSV in root
        do {
            let rootContents = try fileManager.contentsOfDirectory(at: jobFolder, includingPropertiesForKeys: nil)
            let rootCSVs = rootContents.filter { $0.pathExtension.lowercased() == Constants.FileExtensions.csv }
            csvFiles += rootCSVs.count
        } catch {
            errors.append(error)
        }
        
        return FileAnalysisResult(
            totalFiles: totalFiles,
            imageFiles: imageFiles,
            csvFiles: csvFiles,
            otherFiles: otherFiles,
            teams: teams,
            errors: errors
        )
    }
    
    private func analyzeFolder(_ url: URL) -> FileAnalysisResult? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let images = contents.filter { Constants.FileExtensions.isImageFile($0) }
            let csvs = contents.filter { $0.pathExtension.lowercased() == Constants.FileExtensions.csv }
            let others = contents.count - images.count - csvs.count
            
            // Extract team names from file names
            var teams = Set<String>()
            for imageURL in images {
                let fileName = imageURL.deletingPathExtension().lastPathComponent
                let parts = fileName.components(separatedBy: "_")
                if !parts.isEmpty {
                    teams.insert(parts[0])
                }
            }
            
            return FileAnalysisResult(
                totalFiles: contents.count,
                imageFiles: images.count,
                csvFiles: csvs.count,
                otherFiles: others,
                teams: teams,
                errors: []
            )
        } catch {
            return FileAnalysisResult(
                totalFiles: 0,
                imageFiles: 0,
                csvFiles: 0,
                otherFiles: 0,
                teams: [],
                errors: [error]
            )
        }
    }
}
