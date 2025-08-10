import Foundation
import Combine

// MARK: - File Renamer View Model with Dependency Injection
@MainActor
class FileRenamerViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var config = OperationConfig.RenameConfig()
    @Published var hasCSV: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var isRenaming: Bool = false
    @Published var filesToRename: [RenameOperation] = []
    @Published var poseCountValidation: PoseCountValidation?
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var validationReport: ValidationReport?
    @Published var lastRenameOperationId: UUID? = nil
    
    // Public accessor for CSV URL
    var currentCSVURL: URL? { csvURL }
    
    // Expose a quick lookup set of CSV originals (if loaded)
    private var csvOriginals: Set<String> = []
    private var csvURL: URL? = nil
    private var skippedURLs: Set<URL> = []
    
    // MARK: - Computed Properties
    var hasConflicts: Bool {
        filesToRename.contains { $0.hasConflict }
    }
    
    var conflictCount: Int {
        filesToRename.filter { $0.hasConflict }.count
    }
    
    // MARK: - Private Properties
    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    private let csvService: CSVServiceProtocol
    private let imageService: ImageServiceProtocol
    private let fileProcessor: FileProcessingService
    private let validationService: ValidationServiceProtocol
    private let history: OperationHistoryProtocol
    
    private var csvData: [CSVRow] = []
    private var subjectCounters: [String: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization with Dependency Injection
    init(jobFolder: URL,
         fileManager: FileManagerProtocol = FileManager.default,
         csvService: CSVServiceProtocol = CSVService(),
         imageService: ImageServiceProtocol = ImageService(),
         fileProcessor: FileProcessingService = FileProcessingService(),
         validationService: ValidationServiceProtocol = ValidationService(),
         history: OperationHistoryProtocol = OperationHistory()) {
        
        self.jobFolder = jobFolder
        self.fileManager = fileManager
        self.csvService = csvService
        self.imageService = imageService
        self.fileProcessor = fileProcessor
        self.validationService = validationService
        self.history = history
        
        // Always create backups; no dry run by default
        self.config.createBackupBeforeRename = true
        self.config.dryRun = false
        self.config.exportDryRunReport = false
    }
    
    // MARK: - Public Methods
    
    func initialize() async {
        await detectCSV()
        await analyzeFiles()
    }
    
    func reloadCSVAndReanalyze() async {
        await detectCSV()
        await analyzeFiles()
    }

    func analyzeFiles() async {
        isAnalyzing = true
        filesToRename = []
        subjectCounters = [:]
        poseCountValidation = nil
        operationProgress = 0
        currentOperation = "Analyzing files..."
        
        defer {
            isAnalyzing = false
            operationProgress = 0
            currentOperation = ""
        }
        
        do {
            let sourceURL = config.sourceFolder.url(in: jobFolder)
            
            // Validate source folder exists
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw PhotoWorkflowError.folderNotFound(name: config.sourceFolder.rawValue)
            }
            
            // Get image files
            let files = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            
            let imageFiles = files.filter { Constants.FileExtensions.isImageFile($0) }
            
            guard !imageFiles.isEmpty else {
                throw PhotoWorkflowError.noFilesToProcess
            }
            
            currentOperation = "Validating \(imageFiles.count) images..."
            
            // Validate images in parallel
            let validationResults = try await imageService.validateImages(at: imageFiles)
            let validImages = validationResults.compactMap { $0.1 ? $0.0 : nil }
            
            if validImages.count < imageFiles.count {
                print("Warning: \(imageFiles.count - validImages.count) invalid images found and skipped")
            }
            
            // Sort files appropriately
            currentOperation = "Sorting files..."
            let sortedFiles = sortFiles(validImages)
            
            // Filter out skipped files for rename plan
            let candidateFiles = sortedFiles.filter { !skippedURLs.contains($0) }
            
            // Generate rename operations
            currentOperation = "Generating rename operations..."
            let operations = try await generateRenameOperations(for: candidateFiles)
            
            filesToRename = operations
            
            // Run pose validation
            currentOperation = "Validating pose counts..."
            await runPoseValidation(using: candidateFiles)
            
            // Auto-run preflight validation and publish (over all images in source)
            await runPreflightValidation()
            
        } catch let error as PhotoWorkflowError {
            print("Analysis error: \(error.localizedDescription)")
        } catch {
            print("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Preflight Issue Helpers
    func allImageURLsInSource() -> [URL] {
        let sourceURL = config.sourceFolder.url(in: jobFolder)
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            return contents.filter { Constants.FileExtensions.isImageFile($0) }
        } catch {
            return []
        }
    }
    
    func findInvalidFilenameURLs() -> [URL] {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return allImageURLsInSource().filter { url in
            url.lastPathComponent.rangeOfCharacter(from: invalidChars) != nil
        }
    }
    
    func findUnmatchedCSVImageURLs() -> [URL] {
        guard config.dataSource == .csv, !csvOriginals.isEmpty else { return [] }
        return allImageURLsInSource().filter { url in
            !csvOriginals.contains(url.lastPathComponent)
        }
    }
    
    func sanitizedName(for originalName: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let components = originalName.components(separatedBy: invalidChars)
        // Join removed invalid characters with underscore and collapse multiple underscores
        var cleaned = components.joined(separator: "_")
        while cleaned.contains("__") { cleaned = cleaned.replacingOccurrences(of: "__", with: "_") }
        // Trim underscores and spaces
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " _"))
        return cleaned.isEmpty ? originalName.replacingOccurrences(of: " ", with: "_") : cleaned
    }
    
    func renameOnDisk(url: URL, to newName: String) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(newName)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDir) {
            throw PhotoWorkflowError.fileAlreadyExists(path: destination.path)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
    
    func skipFileOnDisk(_ url: URL) throws -> URL {
        let sourceDir = url.deletingLastPathComponent()
        let skippedDir = sourceDir.appendingPathComponent("Skipped")
        if !fileManager.fileExists(atPath: skippedDir.path, isDirectory: nil) {
            try fileManager.createDirectory(at: skippedDir, withIntermediateDirectories: true, attributes: nil)
        }
        let destination = skippedDir.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path, isDirectory: nil) {
            let unique = generateUniqueFileName(baseName: url.lastPathComponent, in: skippedDir)
            let uniqueURL = skippedDir.appendingPathComponent(unique)
            try fileManager.moveItem(at: url, to: uniqueURL)
            return uniqueURL
        } else {
            try fileManager.moveItem(at: url, to: destination)
            return destination
        }
    }
    
    func skipURLInMemory(_ url: URL) {
        skippedURLs.insert(url)
    }
    
    func appendToCSV(original: String, firstName: String, lastName: String, groupName: String) async throws {
        // Ensure CSV URL
        if csvURL == nil {
            let newCSV = jobFolder.appendingPathComponent("roster.csv")
            csvURL = newCSV
        }
        guard let csvURL else { return }
        
        // Load existing
        var headers: [String] = ["original", "first", "last", "col4", "col5", "col6", "team", "group"]
        var rows: [[String]] = []
        do {
            let parsed = try await csvService.parseCSV(from: csvURL)
            if !parsed.headers.isEmpty { headers = parsed.headers }
            rows = parsed.rows
        } catch {
            // If reading fails, we'll create a new file with default header
            rows = []
        }
        
        // Construct new row with at least 8 columns; put team and group
        let newRow = [original, firstName, lastName, "", "", "", groupName, groupName]
        rows.append(newRow)
        
        // Write back (header + rows)
        let rowsToWrite = [headers] + rows
        try await csvService.writeCSV(rowsToWrite, to: csvURL, encoding: .utf8)
        
        hasCSV = true
        await loadCSVData(from: csvURL)
    }
    
    // MARK: - Validation
    func runPreflightValidation() async {
        // Validate ALL image files in the selected source folder to catch
        // unmatched CSV entries or invalid filenames even if they won't be renamed
        let sourceURL = config.sourceFolder.url(in: jobFolder)
        let allImages: [URL]
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            allImages = contents.filter { Constants.FileExtensions.isImageFile($0) }
        } catch {
            allImages = filesToRename.map { $0.sourceURL }
        }
        
        validationReport = await validationService.preflightValidationForRename(
            jobFolder: jobFolder,
            files: allImages,
            config: config,
            csvService: csvService,
            imageService: imageService
        )
    }

    func executeRenames() async throws {
        isRenaming = true
        operationProgress = 0
        currentOperation = "Preparing to rename files..."
        
        defer {
            isRenaming = false
            operationProgress = 0
            currentOperation = ""
        }
        
        guard !filesToRename.isEmpty else {
            throw PhotoWorkflowError.noFilesToProcess
        }
        
        // Start security scoped access
        guard jobFolder.startAccessingSecurityScopedResource() else {
            throw PhotoWorkflowError.securityScopeError(path: jobFolder.path)
        }
        defer { jobFolder.stopAccessingSecurityScopedResource() }
        
        // Preflight validation
        let sourceFiles = filesToRename.map { $0.sourceURL }
        let report = await validationService.preflightValidationForRename(
            jobFolder: jobFolder,
            files: sourceFiles,
            config: config,
            csvService: csvService,
            imageService: imageService
        )
        if report.hasErrors {
            isRenaming = false
            throw PhotoWorkflowError.invalidJobFolder(reason: "Preflight validation failed with \(report.errorCount) error(s)")
        }

        // Always create backup
        var backupFolder: URL? = nil
        backupFolder = jobFolder.appendingPathComponent("Backups/Rename_\(Int(Date().timeIntervalSince1970))")
        try? fileManager.createDirectory(at: backupFolder!, withIntermediateDirectories: true, attributes: nil)
        for op in filesToRename {
            let backupURL = backupFolder!.appendingPathComponent(op.originalName)
            try? fileManager.copyItem(at: op.sourceURL, to: backupURL)
        }

        currentOperation = "Renaming \(filesToRename.count) files..."
        
        // Process renames concurrently
        let results = try await fileProcessor.processFiles(
            filesToRename.map { $0.sourceURL },
            operation: { [weak self] url in
                guard let self = self,
                      let operation = self.filesToRename.first(where: { $0.sourceURL == url }) else {
                    throw PhotoWorkflowError.fileNotFound(path: url.path)
                }
                
                try await self.performRename(operation)
                return url
            },
            progress: { [weak self] progress in
                self?.operationProgress = progress
            }
        )
        
        // Process results
        var errors: [Error] = []
        var successCount = 0
        var successfulURLs = Set<URL>()
        
        for result in results {
            switch result {
            case .success:
                successCount += 1
                if case .success(let url) = result { successfulURLs.insert(url) }
            case .failure(let error):
                errors.append(error)
            }
        }
        
        // Handle results
        if errors.isEmpty {
            currentOperation = "Successfully renamed \(successCount) files"
            // Record history for undo (only successful files)
            let changes: [OperationHistory.FileChange] = filesToRename
                .filter { successfulURLs.contains($0.sourceURL) }
                .map { op in
                    let finalURL = op.sourceURL.deletingLastPathComponent().appendingPathComponent(op.finalName)
                    return OperationHistory.FileChange(originalURL: op.sourceURL, newURL: finalURL)
                }
            let record = OperationHistory.OperationRecord(
                id: UUID(),
                type: .renameFiles,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: true,
                backupFolder: backupFolder
            )
            history.record(record)
            lastRenameOperationId = record.id
            filesToRename = []
            // Clear preflight UI post-rename to avoid confusing CSV-unmatched results
            validationReport = nil
        } else if errors.count == filesToRename.count {
            throw errors.first!
        } else {
            currentOperation = "Renamed \(successCount) files with \(errors.count) errors"
            let failedURLs = Set(errors.compactMap { error -> URL? in
                if case PhotoWorkflowError.fileNotFound(let path) = error {
                    return URL(fileURLWithPath: path)
                }
                return nil
            })
            filesToRename = filesToRename.filter { failedURLs.contains($0.sourceURL) }
        }
        
        print("Renamed \(successCount) files successfully")
    }

    func undoLastRename() async {
        guard let id = lastRenameOperationId else { return }
        do {
            try await history.undo(operationId: id)
            lastRenameOperationId = nil
        } catch {
            print("Undo failed: \(error)")
        }
    }

    // MARK: - Utilities for Conflicts and Manual Fixes
    func existingFileURL(for operation: RenameOperation) -> URL? {
        let destinationURL = operation.sourceURL.deletingLastPathComponent()
            .appendingPathComponent(operation.newName)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDir) {
            return destinationURL
        }
        return nil
    }
    
    func updateNewName(for sourceURL: URL, to newName: String) {
        // Sanitize whitespace
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Build a new array with updated operation
        var updated: [RenameOperation] = []
        updated.reserveCapacity(filesToRename.count)
        for op in filesToRename {
            if op.sourceURL == sourceURL {
                // Recompute conflict status for this new name
                let dir = sourceURL.deletingLastPathComponent()
                var isDir: ObjCBool = false
                let fileExists = fileManager.fileExists(atPath: dir.appendingPathComponent(trimmed).path, isDirectory: &isDir)
                let nameClashInOps = filesToRename.contains { $0.sourceURL != sourceURL && $0.newName == trimmed }
                let newOp = RenameOperation(
                    originalName: op.originalName,
                    newName: trimmed,
                    hasConflict: fileExists || nameClashInOps,
                    sourceURL: op.sourceURL
                )
                updated.append(newOp)
            } else {
                updated.append(op)
            }
        }
        filesToRename = updated
    }
    
    func isValidFileName(_ name: String) -> Bool {
        // Disallow characters commonly problematic in file systems
        let invalidChars: CharacterSet = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.rangeOfCharacter(from: invalidChars) == nil && !name.isEmpty
    }
    
    // MARK: - Helpers
    private func exportDryRunReport() async {
        let rows: [[String]] = [["Original", "New", "Conflict"]] + filesToRename.map { op in
            [op.originalName, op.newName, op.hasConflict ? "Yes" : "No"]
        }
        let reportsFolder = jobFolder.appendingPathComponent("Reports")
        do {
            if !fileManager.fileExists(atPath: reportsFolder.path, isDirectory: nil) {
                try fileManager.createDirectory(at: reportsFolder, withIntermediateDirectories: true, attributes: nil)
            }
            let filename = "DryRun_Rename_\(Int(Date().timeIntervalSince1970)).csv"
            let url = reportsFolder.appendingPathComponent(filename)
            try await csvService.writeCSV(rows, to: url, encoding: .utf8)
        } catch {
            print("Failed to export dry run report: \(error)")
        }
    }
    
    func cancelOperation() async {
        await fileProcessor.cancel()
    }
    
    // MARK: - Private Methods
    
    private func detectCSV() async {
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: jobFolder,
                includingPropertiesForKeys: nil,
                options: []
            )
            
            let csvFiles = contents.filter { $0.pathExtension.lowercased() == Constants.FileExtensions.csv }
            hasCSV = !csvFiles.isEmpty
            
            if hasCSV, let firstCSV = csvFiles.first {
                self.csvURL = firstCSV
                await loadCSVData(from: firstCSV)
            }
        } catch {
            hasCSV = false
            csvURL = nil
            print("Error detecting CSV: \(error)")
        }
        
        // If no CSV, switch to filename mode
        if !hasCSV {
            config.dataSource = .filenames
        }
    }
    
    private func loadCSVData(from url: URL) async {
        do {
            let parseResult = try await csvService.parseCSV(from: url)
            
            // Convert to our CSVRow format
            csvData = parseResult.rows.compactMap { row in
                guard row.count >= Constants.CSV.minFieldCount else { return nil }
                
                return CSVRow(
                    original: row[0],
                    firstName: row[1],
                    lastName: row[2],
                    groupName: row[7]
                )
            }
            csvOriginals = Set(csvData.map { $0.original })
            self.csvURL = url
            
            if !parseResult.warnings.isEmpty {
                print("CSV parsing warnings:")
                parseResult.warnings.forEach { print("  - \($0)") }
            }
            
        } catch {
            print("Error loading CSV: \(error)")
            csvData = []
            csvOriginals = []
        }
    }
    
    private func sortFiles(_ files: [URL]) -> [URL] {
        switch config.dataSource {
        case .csv:
            // Sort by numeric prefix for CSV mode
            return files.sorted { url1, url2 in
                let name1 = url1.deletingPathExtension().lastPathComponent
                let name2 = url2.deletingPathExtension().lastPathComponent
                
                let num1 = extractLeadingNumber(from: name1) ?? 0
                let num2 = extractLeadingNumber(from: name2) ?? 0
                
                return num1 < num2
            }
            
        case .filenames:
            // Sort by team and player name for filename mode
            return files.sorted { url1, url2 in
                let name1 = url1.deletingPathExtension().lastPathComponent
                let name2 = url2.deletingPathExtension().lastPathComponent
                return name1.localizedStandardCompare(name2) == .orderedAscending
            }
        }
    }
    
    private func extractLeadingNumber(from string: String) -> Int? {
        let scanner = Scanner(string: string)
        var number: Int = 0
        if scanner.scanInt(&number) {
            return number
        }
        return nil
    }
    
    private func generateRenameOperations(for files: [URL]) async throws -> [RenameOperation] {
        var operations: [RenameOperation] = []
        var existingNames = Set<String>()
        
        // Collect all existing names
        for file in files {
            existingNames.insert(file.lastPathComponent)
        }
        
        // Reset counters
        subjectCounters = [:]
        
        // Generate new names
        for file in files {
            let originalName = file.lastPathComponent
            let newName = generateNewName(for: originalName)
            
            if originalName != newName {
                let hasConflict = existingNames.contains(newName) && newName != originalName
                
                operations.append(RenameOperation(
                    originalName: originalName,
                    newName: newName,
                    hasConflict: hasConflict,
                    sourceURL: file
                ))
            }
        }
        
        return operations
    }
    
    private func generateNewName(for originalName: String) -> String {
        switch config.dataSource {
        case .csv:
            return generateNameFromCSV(originalName)
        case .filenames:
            return generateNameFromFilename(originalName)
        }
    }
    
    private func generateNameFromCSV(_ originalName: String) -> String {
        guard let row = csvData.first(where: { $0.original == originalName }) else {
            return originalName
        }
        
        let ext = (originalName as NSString).pathExtension
        let key = "\(row.groupName)_\(row.fullName)"
        let count = getAndIncrementCounter(for: key)
        
        return "\(row.groupName)_\(row.fullName)_\(count).\(ext)"
    }
    
    private func generateNameFromFilename(_ originalName: String) -> String {
        let ext = (originalName as NSString).pathExtension
        let name = (originalName as NSString).deletingPathExtension
        let parts = name.components(separatedBy: "_")
        
        guard parts.count >= 3 else {
            return originalName
        }
        
        let team = parts[0]
        var playerParts: [String] = []
        
        // Extract player name parts (everything between team and pose number)
        for i in 1..<parts.count {
            if Int(parts[i]) != nil {
                break
            }
            playerParts.append(parts[i])
        }
        
        guard !playerParts.isEmpty else {
            return originalName
        }
        
        let player = playerParts.joined(separator: " ")
        let key = "\(team)_\(player)"
        let count = getAndIncrementCounter(for: key)
        
        return "\(team)_\(player)_\(count).\(ext)"
    }
    
    private func getAndIncrementCounter(for key: String) -> Int {
        let current = subjectCounters[key, default: 0] + 1
        subjectCounters[key] = current
        return current
    }
    
    private func performRename(_ operation: RenameOperation) async throws {
        let destinationURL = operation.sourceURL.deletingLastPathComponent()
            .appendingPathComponent(operation.finalName)
        
        // Check for conflicts
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: nil) {
            switch config.handleConflicts {
            case .skip:
                return
            case .overwrite:
                try fileManager.removeItem(at: destinationURL)
            case .addSuffix:
                let uniqueName = generateUniqueFileName(
                    baseName: operation.newName,
                    in: operation.sourceURL.deletingLastPathComponent()
                )
                let uniqueURL = operation.sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(uniqueName)
                try fileManager.moveItem(at: operation.sourceURL, to: uniqueURL)
                return
            }
        }
        
        try fileManager.moveItem(at: operation.sourceURL, to: destinationURL)
    }
    
    private func generateUniqueFileName(baseName: String, in directory: URL) -> String {
        let ext = (baseName as NSString).pathExtension
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        
        var counter = 1
        var uniqueName = baseName
        
        while fileManager.fileExists(atPath: directory.appendingPathComponent(uniqueName).path, isDirectory: nil) {
            uniqueName = ext.isEmpty ?
                "\(nameWithoutExt) (\(counter))" :
                "\(nameWithoutExt) (\(counter)).\(ext)"
            counter += 1
        }
        
        return uniqueName
    }
    
    private func runPoseValidation(using files: [URL]) async {
        var playerPoseCounts: [String: Int] = [:]
        
        // Count poses per player
        for operation in filesToRename {
            let parts = operation.newName.components(separatedBy: "_")
            if parts.count >= 3,
               let poseNumber = Int(parts.last?.components(separatedBy: ".").first ?? "") {
                let playerKey = parts.dropLast().joined(separator: "_")
                playerPoseCounts[playerKey, default: 0] += 1
            }
        }
        
        guard !playerPoseCounts.isEmpty else {
            return
        }
        
        // Find most common count
        let counts = Array(playerPoseCounts.values)
        let countFrequency = Dictionary(grouping: counts, by: { $0 })
            .mapValues { $0.count }
        let expectedCount = countFrequency.max(by: { $0.value < $1.value })?.key ?? 0
        
        // Find issues
        let issues = playerPoseCounts
            .filter { $0.value != expectedCount }
            .map { (player: $0.key, count: $0.value) }
            .sorted { $0.player < $1.player }
        
        poseCountValidation = PoseCountValidation(
            expectedCount: expectedCount,
            playersWithIssues: issues,
            totalPlayers: playerPoseCounts.count
        )
    }
}
