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
    @Published var lastRenameOperationId: UUID? = nil {
        didSet {
            print("📋 🔄 lastRenameOperationId changed: \(String(describing: oldValue)) → \(String(describing: lastRenameOperationId))")
        }
    }
    
    // Issue flagging
    @Published var flagStore = IssueFlagStore()
    
    // Revert functionality
    @Published var availableBackups: [RenameBackupInfo] = []
    @Published var selectedBackup: RenameBackupInfo? = nil
    @Published var revertOperations: [RevertOperation] = []
    @Published var isReverting: Bool = false
    
    // Public accessor for CSV URL
    var currentCSVURL: URL? { csvURL }
    
    // Expose a quick lookup set of CSV originals (if loaded)
    private var csvOriginals: Set<String> = []
    private var csvURL: URL? = nil
    // Remember a user-selected CSV to override auto-detection
    private var userSelectedCSVURL: URL? = nil
    private var skippedURLs: Set<URL> = []
    private var unparseableFilenameURLs: [URL] = []
    
    // MARK: - Computed Properties
    var hasConflicts: Bool {
        filesToRename.contains { $0.hasConflict }
    }
    
    var conflictCount: Int {
        filesToRename.filter { $0.hasConflict }.count
    }
    
    // MARK: - Private Properties
    let jobFolder: URL  // Made public for view access
    private let fileManager: FileManagerProtocol
    private let csvService: CSVServiceProtocol
    private let imageService: ImageServiceProtocol
    private let fileProcessor: FileProcessingService
    private let validationService: ValidationServiceProtocol
    private let history: OperationHistoryProtocol
    
    private var csvData: [CSVRow] = []
    private var barcodeToCSVRow: [String: CSVRow] = [:]
    private var fileBarcodeMap: [URL: String] = [:]
    private var subjectCounters: [String: Int] = [:]
    private var buddySubjectCounters: [String: Int] = [:]
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
        print("🔄 FileRenamerViewModel.initialize() starting...")
        print("🔄 Job folder: \(jobFolder.path)")
        await detectCSV()
        await analyzeFiles()
        await checkForExistingBackups()
        print("🔄 About to call detectAvailableBackups()...")
        await detectAvailableBackups()
        print("🔄 detectAvailableBackups() returned, found \(availableBackups.count) backups")
        print("🔄 FileRenamerViewModel.initialize() completed")
    }
    
    func reloadCSVAndReanalyze() async {
        await detectCSV()
        await analyzeFiles()
    }

    /// Allow user to manually select which CSV to use for rename operations.
    func useCSV(from url: URL) async {
        print("📄 [CSV] User selected CSV: \(url.path)")
        userSelectedCSVURL = url
        csvURL = url
        hasCSV = true
        await loadCSVData(from: url)
        // Ensure we're in CSV mode when a CSV is explicitly chosen
        config.dataSource = .csv
        await analyzeFiles()
    }

    func analyzeFiles() async {
        isAnalyzing = true
        filesToRename = []
        subjectCounters = [:]
        poseCountValidation = nil
        unparseableFilenameURLs = []
        operationProgress = 0
        currentOperation = "Analyzing files..."
        
        defer {
            isAnalyzing = false
            operationProgress = 0
            currentOperation = ""
        }
        
        do {
            let sourceURL = config.sourceFolder.url(in: jobFolder, customPath: config.customSourcePath)
            print("🔍 [Analyze] Using source folder: \(sourceURL.path)")
            print("🔍 [Analyze] Source config = \(config.sourceFolder) customPath = \(String(describing: config.customSourcePath?.path))")
            
            // Validate source folder exists
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
            print("🔍 [Analyze] Source exists? \(exists), isDirectory? \(isDirectory.boolValue)")
            guard exists,
                  isDirectory.boolValue else {
                print("⚠️ [Analyze] Source folder not found for config.sourceFolder=\(config.sourceFolder) at path: \(sourceURL.path)")
                throw PhotoWorkflowError.folderNotFound(name: config.sourceFolder.rawValue)
            }
            
            // Get image files
            let files = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            print("🔍 [Analyze] Found \(files.count) items in source folder")
            
            var imageFiles = files.filter { Constants.FileExtensions.isImageFile($0) }
            if !imageFiles.isEmpty {
                let sample = imageFiles.prefix(10).map { $0.lastPathComponent }
                print("🔍 [Analyze] Image files detected (\(imageFiles.count)). Sample: \(sample)")
            } else {
                print("⚠️ [Analyze] No image files detected in source folder: \(sourceURL.path)")
            }
            
            // If using CSV, skip coach files entirely (never move to Skipped)
            if config.dataSource == .csv {
                imageFiles.removeAll { url in
                    let name = url.deletingPathExtension().lastPathComponent
                    // Match Teamname_CoachN_random.jpg (Coach literal, N digits, underscores between segments)
                    let parts = name.split(separator: "_")
                    guard parts.count >= 3 else { return false }
                    // parts[1] must start with "Coach" and may have trailing digits (case-insensitive)
                    let token = String(parts[1]).uppercased()
                    if token.hasPrefix("COACH") {
                        let suffix = token.dropFirst(5)
                        // Allow no digits (Coach) or digits (Coach1, Coach2, ...)
                        if suffix.isEmpty || suffix.allSatisfy({ $0.isNumber }) {
                            return true
                        }
                    }
                    return false
                }
            }
            
            guard !imageFiles.isEmpty else {
                print("⚠️ [Analyze] imageFiles is empty after CSV/coach filtering — throwing noFilesToProcess")
                throw PhotoWorkflowError.noFilesToProcess
            }
            
            currentOperation = "Validating \(imageFiles.count) images..."
            
            // Validate images in parallel
            let validationResults = try await imageService.validateImages(at: imageFiles)
            let filtered = validationResults.compactMap { $0.1 ? $0.0 : nil }
            let validImages = config.bypassPreflightErrors ? imageFiles : filtered
            
            if !config.bypassPreflightErrors && filtered.count < imageFiles.count {
                print("Warning: \(imageFiles.count - filtered.count) invalid images found and skipped")
            }
            
            // Sort files appropriately
            currentOperation = "Sorting files..."
            let sortedFiles = sortFiles(validImages)
            
            // Filter out skipped files for rename plan
            let candidateFiles = sortedFiles.filter { !skippedURLs.contains($0) }
            
            // Pre-read metadata barcodes for matching
            currentOperation = "Reading image metadata..."
            await buildBarcodeMap(for: candidateFiles)
            
            // If using CSV, further group files by matched CSV player key to ensure pose ordering
            var filesForOps = candidateFiles
            if config.dataSource == .csv && !barcodeToCSVRow.isEmpty {
                func playerKey(for url: URL) -> String {
                    if let bc = fileBarcodeMap[url], let row = barcodeToCSVRow[bc] {
                        return "\(row.groupName)_\(row.fullName)"
                    }
                    // Unmatched go last by using a high-sorting prefix
                    return "~~~_\(url.lastPathComponent)"
                }
                filesForOps = candidateFiles.sorted { a, b in
                    let ka = playerKey(for: a)
                    let kb = playerKey(for: b)
                    if ka != kb { return ka < kb }
                    return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
                }
            }
            
            // Generate rename operations
            currentOperation = "Generating rename operations..."
            let operations = try await generateRenameOperations(for: filesForOps)
            
            filesToRename = operations
            
            // Run pose validation
            currentOperation = "Validating pose counts..."
            await runPoseValidation(using: candidateFiles)
            
            // Auto-run preflight validation and publish (over all images in source)
            await runPreflightValidation()
            // If bypass is enabled, ensure warnings/errors don't block subsequent UI
            // We leave the report visible, but we continue to show analysis results below.
            
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
        let allImages = allImageURLsInSource()
        let invalidFiles = allImages.filter { url in
            url.lastPathComponent.rangeOfCharacter(from: invalidChars) != nil
        }
        print("🔍 Found \(invalidFiles.count) files with invalid characters out of \(allImages.count) total images")
        for url in invalidFiles {
            print("  - Invalid: \(url.lastPathComponent)")
        }
        return invalidFiles
    }
    
    func findUnmatchedCSVImageURLs() -> [URL] {
        guard config.dataSource == .csv, !csvOriginals.isEmpty else { return [] }
        return allImageURLsInSource().filter { url in
            let name = url.lastPathComponent
            // Exempt Buddy and Coach files from unmatched CSV list (only when handling buddy separately)
            if config.handleBuddySeparately && isBuddyPhoto(name) { return false }
            if isCoachPhoto(name) { return false }
            return !csvOriginals.contains(name)
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
        
        print("🔍 Running preflight validation for \(allImages.count) images")
        
        var baseReport = await validationService.preflightValidationForRename(
            jobFolder: jobFolder,
            files: allImages,
            config: config,
            csvService: csvService,
            imageService: imageService,
            flagStore: flagStore
        )
        
        print("📊 Base validation report: \(baseReport.errorCount) errors, \(baseReport.warningCount) warnings")
        
        // Add pose count issues to the validation report
        if let poseValidation = poseCountValidation, poseValidation.hasIssues {
            let poseIssues = createPoseCountIssues(from: poseValidation)
            let filteredPoseIssues = poseIssues.filter { !flagStore.isDismissed($0.id) }
            print("🏃‍♂️ Adding \(filteredPoseIssues.count) pose count issues")
            baseReport = ValidationReport(
                operation: baseReport.operation,
                issues: baseReport.issues + filteredPoseIssues,
                requiredDiskSpace: baseReport.requiredDiskSpace,
                availableDiskSpace: baseReport.availableDiskSpace
            )
        }
        
        print("📋 Final validation report: \(baseReport.errorCount) errors, \(baseReport.warningCount) warnings")
        for issue in baseReport.issues {
            print("  - [\(issue.severity.rawValue.uppercased())] \(issue.message)")
        }
        
        // Add unparseable filename warnings if in filename mode
        if config.dataSource == .filenames && !unparseableFilenameURLs.isEmpty {
            let unparseableIssues = createUnparseableFilenameIssues()
            print("📋 Adding \(unparseableIssues.count) unparseable filename warnings")
            baseReport = ValidationReport(
                operation: baseReport.operation,
                issues: baseReport.issues + unparseableIssues,
                requiredDiskSpace: baseReport.requiredDiskSpace,
                availableDiskSpace: baseReport.availableDiskSpace
            )
        }
        
        validationReport = baseReport
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
        
        // Start security scoped access for job folder
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
            imageService: imageService,
            flagStore: flagStore
        )
        if report.hasErrors && !config.bypassPreflightErrors {
            isRenaming = false
            throw PhotoWorkflowError.invalidJobFolder(reason: "Preflight validation failed with \(report.errorCount) error(s)")
        }

        // No file-copy backups; we'll write a mapping CSV after successful renames
        let backupFolder: URL? = nil

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
                    // Mirror destination logic from performRename
                    let destBase: URL = {
                        if config.handleBuddySeparately && isBuddyPhoto(op.originalName) {
                            let selectedBase = config.sourceFolder.url(in: jobFolder, customPath: config.customSourcePath)
                            return selectedBase.appendingPathComponent(Constants.Folders.buddyPhotos)
                        } else {
                            return op.sourceURL.deletingLastPathComponent()
                        }
                    }()
                    let finalURL = destBase.appendingPathComponent(op.finalName)
                    return OperationHistory.FileChange(originalURL: op.sourceURL, newURL: finalURL, mode: .move)
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
            // Write mapping CSV with original->new (with full paths for revert)
            do {
                let backupsRoot = jobFolder.appendingPathComponent("Backups")
                if !fileManager.fileExists(atPath: backupsRoot.path, isDirectory: nil) {
                    try? fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true, attributes: nil)
                }
                let ts = Int(Date().timeIntervalSince1970)
                let mappingURL = backupsRoot.appendingPathComponent("Rename_\(ts)_mapping.csv")
                
                // Enhanced format: original_path, original_name, new_path, new_name
                var rows: [[String]] = [["original_path","original_name","new_path","new_name"]]
                for ch in changes {
                    // Get relative paths from job folder
                    let originalRelPath = ch.originalURL.path.replacingOccurrences(of: jobFolder.path + "/", with: "")
                    let newRelPath = ch.newURL.path.replacingOccurrences(of: jobFolder.path + "/", with: "")
                    
                    rows.append([
                        originalRelPath,
                        ch.originalURL.lastPathComponent,
                        newRelPath,
                        ch.newURL.lastPathComponent
                    ])
                }
                try await csvService.writeCSV(rows, to: mappingURL, encoding: .utf8)
            } catch {
                // Best-effort; ignore mapping write errors
            }
            filesToRename = []
            // Clear preflight UI post-rename to avoid confusing CSV-unmatched results
            validationReport = nil
        } else if errors.count == filesToRename.count {
            throw errors.first ?? PhotoWorkflowError.operationCancelled
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
    
    // MARK: - Revert Functionality
    
    func detectAvailableBackups() async {
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        print("🔄 Detecting available backups in: \(backupsRoot.path)")
        
        guard fileManager.fileExists(atPath: backupsRoot.path, isDirectory: nil) else {
            print("🔄 No Backups folder found at: \(backupsRoot.path)")
            availableBackups = []
            return
        }
        
        do {
            let backupFiles = try fileManager.contentsOfDirectory(
                at: backupsRoot,
                includingPropertiesForKeys: [.creationDateKey],
                options: []
            )
            
            print("🔄 Total files in Backups folder: \(backupFiles.count)")
            for file in backupFiles {
                print("   - \(file.lastPathComponent)")
            }
            
            let mappingFiles = backupFiles.filter {
                let isRenameFile = $0.lastPathComponent.hasPrefix("Rename_")
                let isCSV = $0.pathExtension == "csv"
                let notInArchive = !$0.path.contains("/Archive/")
                
                print("   Checking \($0.lastPathComponent): isRename=\(isRenameFile), isCSV=\(isCSV), notInArchive=\(notInArchive)")
                
                return isRenameFile && isCSV && notInArchive
            }
            
            print("🔄 Found \(mappingFiles.count) backup CSV files matching criteria")
            
            var backups: [RenameBackupInfo] = []
            for csvURL in mappingFiles {
                do {
                    print("   📄 Parsing: \(csvURL.lastPathComponent)")
                    
                    // Parse the CSV to get file count and source folder
                    let result = try await csvService.parseCSV(from: csvURL)
                    let fileCount = max(0, result.rows.count - 1) // Subtract header
                    
                    print("      Columns: \(result.columnCount), Rows: \(result.rows.count)")
                    if result.rows.count > 0 {
                        print("      Header: \(result.rows[0])")
                    }
                    if result.rows.count > 1 {
                        print("      First data row: \(result.rows[1])")
                    }
                    
                    // Extract timestamp from filename: Rename_TIMESTAMP_mapping.csv
                    let filename = csvURL.deletingPathExtension().lastPathComponent
                    let parts = filename.split(separator: "_")
                    let timestamp: Date
                    if parts.count >= 2, let ts = TimeInterval(parts[1]) {
                        timestamp = Date(timeIntervalSince1970: ts)
                    } else {
                        // Fallback to file creation date
                        let attrs = try? csvURL.resourceValues(forKeys: [.creationDateKey])
                        timestamp = attrs?.creationDate ?? Date()
                    }
                    
                    // Determine source folder from first row
                    var sourceFolder = "Extracted" // Default
                    if result.rows.count > 1 && result.rows[1].count >= 1 {
                        let firstPath = result.rows[1][0]
                        if firstPath.hasPrefix("Extracted") {
                            sourceFolder = "Extracted"
                        } else if firstPath.hasPrefix("Output") {
                            sourceFolder = "Output"
                        } else if firstPath.contains("/") {
                            sourceFolder = firstPath.components(separatedBy: "/").first ?? "Extracted"
                        } else {
                            // Old format CSV with just filenames - default to Extracted
                            sourceFolder = "Extracted"
                        }
                    }
                    
                    print("      ✅ Parsed successfully: \(fileCount) files from \(sourceFolder)")
                    
                    let backupInfo = RenameBackupInfo(
                        csvURL: csvURL,
                        timestamp: timestamp,
                        fileCount: fileCount,
                        sourceFolder: sourceFolder
                    )
                    backups.append(backupInfo)
                    
                } catch {
                    print("      ⚠️ Failed to parse backup CSV \(csvURL.lastPathComponent): \(error)")
                }
            }
            
            // Sort by timestamp, most recent first
            availableBackups = backups.sorted { $0.timestamp > $1.timestamp }
            print("🔄 ✅ Loaded \(availableBackups.count) valid backups")
            for backup in availableBackups {
                print("   • \(backup.csvURL.lastPathComponent): \(backup.fileCount) files, \(backup.sourceFolder)")
            }
            
        } catch {
            print("⚠️ Error detecting backups: \(error)")
            availableBackups = []
        }
    }
    
    func loadRevertPreview(from backup: RenameBackupInfo) async throws {
        print("🔄 Loading revert preview from: \(backup.csvURL.lastPathComponent)")
        revertOperations = []
        selectedBackup = backup
        
        // Start security scoped access
        guard jobFolder.startAccessingSecurityScopedResource() else {
            throw PhotoWorkflowError.securityScopeError(path: jobFolder.path)
        }
        defer { jobFolder.stopAccessingSecurityScopedResource() }
        
        // Parse the CSV
        let result = try await csvService.parseCSV(from: backup.csvURL)
        
        // Check format: should have 4 columns (original_path, original_name, new_path, new_name)
        guard result.columnCount >= 4 || result.columnCount == 2 else {
            throw PhotoWorkflowError.invalidJobFolder(reason: "Backup CSV has invalid format")
        }
        
        var operations: [RevertOperation] = []
        
        for row in result.rows.dropFirst() { // Skip header
            guard row.count >= 2 else { continue }
            
            let originalPath: String
            let originalName: String
            let newPath: String
            let newName: String
            
            // Support both old format (2 columns) and new format (4 columns)
            if row.count >= 4 {
                originalPath = row[0]
                originalName = row[1]
                newPath = row[2]
                newName = row[3]
            } else {
                // Old format: just filenames, assume Extracted folder
                originalName = row[0]
                newName = row[1]
                originalPath = "Extracted/\(originalName)"
                newPath = "Extracted/\(newName)"
            }
            
            // Construct full URLs
            let originalURL = jobFolder.appendingPathComponent(originalPath)
            let currentURL = jobFolder.appendingPathComponent(newPath)
            
            // Determine status
            var status: RevertOperation.RevertStatus = .pending
            
            // Check if renamed file exists at expected location
            if fileManager.fileExists(atPath: currentURL.path, isDirectory: nil) {
                // Check if destination (original location) is available
                if fileManager.fileExists(atPath: originalURL.path, isDirectory: nil) {
                    status = .conflictAtDestination
                } else {
                    status = .ready
                }
            } else {
                // Try to find the file in common locations
                let searchLocations = [
                    jobFolder.appendingPathComponent("Extracted").appendingPathComponent(newName),
                    jobFolder.appendingPathComponent("Output").appendingPathComponent(newName),
                    jobFolder.appendingPathComponent("Extracted").appendingPathComponent(Constants.Folders.buddyPhotos).appendingPathComponent(newName),
                    jobFolder.appendingPathComponent("Output").appendingPathComponent(Constants.Folders.buddyPhotos).appendingPathComponent(newName),
                    jobFolder.appendingPathComponent("Finished Teams").appendingPathComponent(newName)
                ]
                
                var found = false
                for searchURL in searchLocations {
                    if fileManager.fileExists(atPath: searchURL.path, isDirectory: nil) {
                        let altOriginalURL = originalURL
                        if fileManager.fileExists(atPath: altOriginalURL.path, isDirectory: nil) {
                            status = .conflictAtDestination
                        } else {
                            status = .ready
                        }
                        found = true
                        break
                    }
                }
                
                if !found {
                    status = .notFound
                }
            }
            
            let operation = RevertOperation(
                currentURL: currentURL,
                originalURL: originalURL,
                currentName: newName,
                originalName: originalName,
                status: status
            )
            operations.append(operation)
        }
        
        revertOperations = operations
        print("🔄 ✅ Loaded \(operations.count) revert operations, \(operations.filter { $0.canRevert }.count) ready to revert")
    }
    
    func executeRevert() async throws {
        guard !revertOperations.isEmpty else {
            throw PhotoWorkflowError.noFilesToProcess
        }
        
        guard let backup = selectedBackup else {
            throw PhotoWorkflowError.invalidJobFolder(reason: "No backup selected")
        }
        
        isReverting = true
        operationProgress = 0
        currentOperation = "Reverting files to original names..."
        
        defer {
            isReverting = false
            operationProgress = 0
            currentOperation = ""
        }
        
        // Start security scoped access
        guard jobFolder.startAccessingSecurityScopedResource() else {
            throw PhotoWorkflowError.securityScopeError(path: jobFolder.path)
        }
        defer { jobFolder.stopAccessingSecurityScopedResource() }
        
        // Only process operations that are ready to revert
        let revertableOps = revertOperations.filter { $0.canRevert }
        
        guard !revertableOps.isEmpty else {
            throw PhotoWorkflowError.noFilesToProcess
        }
        
        currentOperation = "Reverting \(revertableOps.count) files..."
        
        // Process reverts
        let results = try await fileProcessor.processFiles(
            revertableOps.map { $0.currentURL },
            operation: { [weak self] url in
                guard let self = self,
                      let operation = revertableOps.first(where: { $0.currentURL == url }) else {
                    throw PhotoWorkflowError.fileNotFound(path: url.path)
                }
                
                try await self.performRevert(operation)
                return url
            },
            progress: { [weak self] progress in
                self?.operationProgress = progress
            }
        )
        
        // Process results
        var errors: [Error] = []
        var successCount = 0
        
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let error):
                errors.append(error)
            }
        }
        
        currentOperation = "Successfully reverted \(successCount) files"
        
        if errors.isEmpty {
            // Archive the backup CSV
            try archiveBackupCSV(backup.csvURL)
            
            // Refresh backups list
            await detectAvailableBackups()
            
            // Clear selection and operations
            selectedBackup = nil
            revertOperations = []
            
            print("✅ Revert completed successfully: \(successCount) files")
        } else if errors.count == revertableOps.count {
            throw errors.first ?? PhotoWorkflowError.operationCancelled
        } else {
            currentOperation = "Reverted \(successCount) files with \(errors.count) errors"
            print("⚠️ Revert completed with errors: \(successCount) success, \(errors.count) failed")
        }
    }
    
    private func performRevert(_ operation: RevertOperation) async throws {
        // Ensure destination directory exists
        let destinationDir = operation.originalURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDir.path, isDirectory: nil) {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Move file back to original location
        try fileManager.moveItem(at: operation.currentURL, to: operation.originalURL)
    }
    
    func archiveBackupCSV(_ csvURL: URL) throws {
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        let archiveFolder = backupsRoot.appendingPathComponent("Archive")
        
        // Create Archive folder if it doesn't exist
        if !fileManager.fileExists(atPath: archiveFolder.path, isDirectory: nil) {
            try fileManager.createDirectory(at: archiveFolder, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Move CSV to archive
        let archiveURL = archiveFolder.appendingPathComponent(csvURL.lastPathComponent)
        
        // If file already exists in archive, add a suffix
        var finalArchiveURL = archiveURL
        var counter = 1
        while fileManager.fileExists(atPath: finalArchiveURL.path, isDirectory: nil) {
            let baseName = csvURL.deletingPathExtension().lastPathComponent
            let ext = csvURL.pathExtension
            finalArchiveURL = archiveFolder.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }
        
        try fileManager.moveItem(at: csvURL, to: finalArchiveURL)
        print("📦 Archived backup CSV to: \(finalArchiveURL.lastPathComponent)")
    }
    
    // MARK: - Backup Detection and Recovery
    
    func checkForExistingBackups() async {
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        print("📋 Checking for backups in: \(backupsRoot.path)")
        
        guard fileManager.fileExists(atPath: backupsRoot.path, isDirectory: nil) else { 
            print("📋 No Backups folder found")
            return 
        }
        
        do {
            let backupFiles = try fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: [.creationDateKey], options: [])
            print("📋 Found \(backupFiles.count) files in Backups folder")
            
            let renameMappings = backupFiles.filter { $0.lastPathComponent.hasPrefix("Rename_") && $0.pathExtension == "csv" }
            print("📋 Found \(renameMappings.count) rename mapping files: \(renameMappings.map { $0.lastPathComponent })")
            
            // Find the most recent rename mapping
            guard let latestMapping = renameMappings.max(by: { (url1, url2) in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }) else { 
                print("📋 No rename mapping files found")
                return 
            }
            
            print("📋 Using latest rename backup: \(latestMapping.lastPathComponent)")
            
            // Check if the renamed files still exist and can be undone
            if await canUndoFromMapping(latestMapping) {
                // Create a synthetic operation record for undo capability
                await restoreUndoCapabilityFromMapping(latestMapping)
                print("📋 ✅ Restored undo capability from existing backup")
            } else {
                print("📋 ⚠️ Backup found but files cannot be undone (may have been moved or deleted)")
            }
            
        } catch {
            print("📋 Error checking for existing backups: \(error.localizedDescription)")
        }
    }
    
    private func canUndoFromMapping(_ mappingURL: URL) async -> Bool {
        do {
            let csvResult = try await csvService.parseCSV(from: mappingURL)
            let rows = csvResult.rows
            print("📋 Checking \(max(0, rows.count - 1)) rename operations for undo capability")
            
            // Helper to normalize header names
            func norm(_ s: String) -> String {
                return s.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
            }
            
            // Build header index map, try result.headers first, then first row
            var headerIndex: [String: Int] = [:]
            if !csvResult.headers.isEmpty {
                for (i, h) in csvResult.headers.enumerated() {
                    headerIndex[norm(h)] = i
                }
            } else if let headerRow = rows.first {
                for (i, h) in headerRow.enumerated() {
                    headerIndex[norm(h)] = i
                }
            }
            
            let hasPathColumns = headerIndex["originalpath"] != nil && headerIndex["newpath"] != nil
            
            var foundCount = 0
            var totalCount = 0
            
            // Common search locations for legacy (2-col) mappings or fallbacks
            let extractedFolder = jobFolder.appendingPathComponent(Constants.Folders.extracted)
            let outputFolder = jobFolder.appendingPathComponent(Constants.Folders.output)
            let searchFolders = [
                extractedFolder,
                outputFolder,
                extractedFolder.appendingPathComponent(Constants.Folders.buddyPhotos),
                outputFolder.appendingPathComponent(Constants.Folders.buddyPhotos),
                jobFolder,
                jobFolder.appendingPathComponent("Finished Teams"),
                jobFolder.appendingPathComponent("Issues"), // Legacy location
                extractedFolder.appendingPathComponent("Issues"), // New correct location
                outputFolder.appendingPathComponent("Issues") // New correct location
            ]
            
            // Check if we can find the renamed files to undo
            for row in rows.dropFirst() { // Skip header row
                // Skip empty/short rows
                guard row.count >= 2 else { continue }
                totalCount += 1
                
                if hasPathColumns || row.count >= 4 {
                    // Prefer using explicit paths when available
                    let opIdx = headerIndex["originalpath"] ?? 0
                    let npIdx = headerIndex["newpath"] ?? (row.count >= 4 ? 2 : 1)
                    let originalPath = row.indices.contains(opIdx) ? row[opIdx] : ""
                    let newPath = row.indices.contains(npIdx) ? row[npIdx] : ""
                    
                    let currentURL = jobFolder.appendingPathComponent(newPath)
                    if fileManager.fileExists(atPath: currentURL.path, isDirectory: nil) {
                        foundCount += 1
                        continue
                    }
                    
                    // Fallback: try by new file name across common locations
                    let newName = (newPath as NSString).lastPathComponent
                    var located = false
                    for folder in searchFolders {
                        let test = folder.appendingPathComponent(newName)
                        if fileManager.fileExists(atPath: test.path, isDirectory: nil) {
                            foundCount += 1
                            located = true
                            break
                        }
                    }
                    if located { continue }
                    
                    // Last resort: if original still exists somewhere
                    let originalName = (originalPath as NSString).lastPathComponent
                    for folder in searchFolders {
                        let test = folder.appendingPathComponent(originalName)
                        if fileManager.fileExists(atPath: test.path, isDirectory: nil) {
                            foundCount += 1
                            break
                        }
                    }
                } else {
                    // Legacy 2-column format: [original_name, new_name]
                    let originalName = row[0]
                    let newName = row[1]
                    var located = false
                    for folder in searchFolders {
                        // Check for renamed file
                        let renamedFileURL = folder.appendingPathComponent(newName)
                        if fileManager.fileExists(atPath: renamedFileURL.path, isDirectory: nil) {
                            foundCount += 1
                            located = true
                            break
                        }
                        // Also check for original file (might not have been renamed)
                        let originalFileURL = folder.appendingPathComponent(originalName)
                        if fileManager.fileExists(atPath: originalFileURL.path, isDirectory: nil) {
                            foundCount += 1
                            located = true
                            break
                        }
                    }
                    if located { continue }
                }
            }
            
            print("📋 Found \(foundCount) out of \(totalCount) files that can be undone")
            // Allow undo if we found at least some files (don't require 100%)
            return foundCount > 0
            
        } catch {
            print("📋 Error reading mapping file: \(error.localizedDescription)")
            return false
        }
    }
    
    private func restoreUndoCapabilityFromMapping(_ mappingURL: URL) async {
        do {
            let csvResult = try await csvService.parseCSV(from: mappingURL)
            let rows = csvResult.rows
            
            // Helper to normalize header names
            func norm(_ s: String) -> String {
                return s.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
            }
            
            // Build header index map
            var headerIndex: [String: Int] = [:]
            if !csvResult.headers.isEmpty {
                for (i, h) in csvResult.headers.enumerated() {
                    headerIndex[norm(h)] = i
                }
            } else if let headerRow = rows.first {
                for (i, h) in headerRow.enumerated() {
                    headerIndex[norm(h)] = i
                }
            }
            let hasPathColumns = headerIndex["originalpath"] != nil && headerIndex["newpath"] != nil
            
            var changes: [OperationHistory.FileChange] = []
            let extractedFolder = jobFolder.appendingPathComponent(Constants.Folders.extracted)
            let outputFolder = jobFolder.appendingPathComponent(Constants.Folders.output)
            let searchFolders = [
                extractedFolder,
                outputFolder,
                extractedFolder.appendingPathComponent(Constants.Folders.buddyPhotos),
                outputFolder.appendingPathComponent(Constants.Folders.buddyPhotos),
                jobFolder,
                jobFolder.appendingPathComponent("Finished Teams"),
                jobFolder.appendingPathComponent("Issues"), // Legacy location
                extractedFolder.appendingPathComponent("Issues"), // New correct location
                outputFolder.appendingPathComponent("Issues") // New correct location
            ]
            
            for row in rows.dropFirst() { // Skip header row
                guard row.count >= 2 else { continue }
                
                if hasPathColumns || row.count >= 4 {
                    // Prefer using explicit relative paths
                    let opIdx = headerIndex["originalpath"] ?? 0
                    let onIdx = headerIndex["originalname"] ?? 1
                    let npIdx = headerIndex["newpath"] ?? (row.count >= 4 ? 2 : 1)
                    let nnIdx = headerIndex["newname"] ?? (row.count >= 4 ? 3 : 1)
                    
                    let originalPath = row.indices.contains(opIdx) ? row[opIdx] : ""
                    let originalName = row.indices.contains(onIdx) ? row[onIdx] : (originalPath as NSString).lastPathComponent
                    let newPath = row.indices.contains(npIdx) ? row[npIdx] : ""
                    let newName = row.indices.contains(nnIdx) ? row[nnIdx] : (newPath as NSString).lastPathComponent
                    
                    var finalOriginalURL = jobFolder.appendingPathComponent(originalPath)
                    var finalNewURL = jobFolder.appendingPathComponent(newPath)
                    
                    // If exact path doesn't exist, try to locate by name in common folders
                    if !fileManager.fileExists(atPath: finalOriginalURL.path, isDirectory: nil) {
                        for folder in searchFolders {
                            let test = folder.appendingPathComponent(originalName)
                            if fileManager.fileExists(atPath: test.path, isDirectory: nil) { finalOriginalURL = test; break }
                        }
                    }
                    if !fileManager.fileExists(atPath: finalNewURL.path, isDirectory: nil) {
                        for folder in searchFolders {
                            let test = folder.appendingPathComponent(newName)
                            if fileManager.fileExists(atPath: test.path, isDirectory: nil) { finalNewURL = test; break }
                        }
                    }
                    
                    changes.append(OperationHistory.FileChange(originalURL: finalOriginalURL, newURL: finalNewURL, mode: .move))
                } else {
                    // Legacy 2-column format: [original_name, new_name]
                    let originalName = row[0]
                    let newName = row[1]
                    
                    // Find where the files actually are
                    var originalURL: URL?
                    var newURL: URL?
                    
                    for folder in searchFolders {
                        if originalURL == nil {
                            let testOriginal = folder.appendingPathComponent(originalName)
                            if fileManager.fileExists(atPath: testOriginal.path, isDirectory: nil) {
                                originalURL = testOriginal
                            }
                        }
                        if newURL == nil {
                            let testNew = folder.appendingPathComponent(newName)
                            if fileManager.fileExists(atPath: testNew.path, isDirectory: nil) {
                                newURL = testNew
                            }
                        }
                    }
                    
                    // Use the found locations, or default to Extracted folder
                    let finalOriginalURL = originalURL ?? jobFolder.appendingPathComponent(Constants.Folders.extracted).appendingPathComponent(originalName)
                    let finalNewURL = newURL ?? jobFolder.appendingPathComponent(Constants.Folders.extracted).appendingPathComponent(newName)
                    changes.append(OperationHistory.FileChange(originalURL: finalOriginalURL, newURL: finalNewURL, mode: .move))
                }
            }
            
            // Create a synthetic operation record
            let operationId = UUID()
            let record = OperationHistory.OperationRecord(
                id: operationId,
                type: .renameFiles,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: true,
                backupFolder: mappingURL.deletingLastPathComponent()
            )
            
            history.record(record)
            lastRenameOperationId = operationId
            
            print("📋 ✅ Updated UI with operation ID: \(operationId)")
            print("📋 Created synthetic operation record with \(changes.count) file changes")
            
        } catch {
            print("📋 Error restoring undo capability: \(error.localizedDescription)")
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
        fileProcessor.cancel()
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
            
            if hasCSV {
                // If user explicitly chose a CSV and it still exists, honor that choice
                if let preferred = userSelectedCSVURL,
                   csvFiles.contains(where: { $0 == preferred }) {
                    print("📄 [CSV] Using user-selected CSV: \(preferred.lastPathComponent)")
                    self.csvURL = preferred
                    await loadCSVData(from: preferred)
                    return
                }
                
                // Evaluate all CSVs and pick the best candidate by structure
                var bestURL: URL?
                var bestResult: CSVParseResult?
                var bestScore: Double = -1
                
                for url in csvFiles {
                    do {
                        let result = try await csvService.parseCSV(from: url)
                        // Score based on column count validity and row consistency
                        let columnCount = max(1, result.columnCount)
                        let totalRows = max(1, result.rows.count)
                        let consistentRows = result.rows.filter { $0.count == columnCount }.count
                        var score = Double(consistentRows) / Double(totalRows)
                        
                        // Bonus if headers look like expected export
                        let headers = result.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        let normalizedHeaders = Set(headers.map { normalizeHeader($0) })
                        let expected = ["photo", "firstname", "lastname", "group", "barcode"]
                        let headerMatches = expected.filter { normalizedHeaders.contains(normalizeHeader($0)) }.count
                        score += Double(headerMatches) * 0.1
                        
                        // Strong preference for CSVs that contain a barcode column.
                        // Handle variations like "Barcode", "Barcode 1", "Barcode (1)", etc.
                        let hasBarcodeColumn = normalizedHeaders.contains("barcode") ||
                                               normalizedHeaders.contains("barcode1") ||
                                               normalizedHeaders.contains("barcode(1)") ||
                                               normalizedHeaders.contains(where: { $0.hasPrefix("barcode") })
                        if hasBarcodeColumn {
                            score += 10.0
                            print("📄 [CSV] \(url.lastPathComponent) has barcode column; boosted score to \(score)")
                        }
                        
                        if score > bestScore {
                            bestScore = score
                            bestURL = url
                            bestResult = result
                        }
                    } catch {
                        // Skip invalid CSV
                        continue
                    }
                }
                
                if let chosenURL = bestURL, let chosenResult = bestResult {
                    self.csvURL = chosenURL
                    await loadCSVData(from: chosenURL, preParsed: chosenResult)
                }
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
    
    private func loadCSVData(from url: URL, preParsed: CSVParseResult? = nil) async {
        do {
            let parseResult: CSVParseResult
            if let pre = preParsed {
                parseResult = pre
            } else {
                parseResult = try await csvService.parseCSV(from: url)
            }
            
            print("🔍 [CSV] Loaded CSV from \(url.lastPathComponent)")
            print("🔍 [CSV] Detected delimiter: \(parseResult.delimiter), columns: \(parseResult.columnCount), rows (incl. header): \(parseResult.rows.count)")
            
            // Map columns by header names for flexibility across CSV exports
            let headers = parseResult.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !headers.isEmpty {
                print("🔍 [CSV] Headers: \(headers)")
            } else if let firstRow = parseResult.rows.first {
                print("🔍 [CSV] No explicit headers; first row sample: \(firstRow)")
            }
            let normalizedToIndex: [String: Int] = {
                var map: [String: Int] = [:]
                for (i, h) in headers.enumerated() { map[normalizeHeader(h)] = i }
                return map
            }()

            func idx(_ keys: [String]) -> Int? {
                for k in keys {
                    if let i = normalizedToIndex[normalizeHeader(k)] { return i }
                }
                return nil
            }

            // In the new flow, we will match by barcode, but we still store 'original' for legacy
            let originalIdx = idx(["SPA", "Photo", "NEW FILE NAME", "FILENAME"]) ?? 0
            let firstIdx = idx(["FIRSTNAME", "FIRST NAME"]) ?? 1
            let lastIdx = idx(["LASTNAME", "LAST NAME"]) ?? 2
            let groupIdx = idx(["GROUP", "TEAMNAME", "TEAM NAME"]) ?? 7
            // Book2_xlsx_csv format uses headers like "Barcode (1)"; include variants
            let barcodeIdx = idx(["BARCODE (1)", "BARCODE(1)", "BARCODE1", "BARCODE"]) ?? idx(["IDENTIFIER"]) ?? nil
            
            print("🔍 [CSV] Column indices → original=\(originalIdx), first=\(firstIdx), last=\(lastIdx), group=\(groupIdx), barcode=\(String(describing: barcodeIdx))")

            // Convert to our CSVRow format
            csvData = parseResult.rows.compactMap { row in
                func field(_ i: Int) -> String { i < row.count ? row[i] : "" }
                let original = field(originalIdx)
                let first = field(firstIdx)
                let last = field(lastIdx)
                let group = field(groupIdx)
                let barcode = barcodeIdx.flatMap { field($0) }
                // Accept rows if they have either a non-empty original OR a non-empty barcode
                if original.isEmpty && (barcode == nil || barcode == "") { return nil }
                return CSVRow(
                    original: original,
                    firstName: first,
                    lastName: last,
                    groupName: group,
                    barcode: barcode?.isEmpty == true ? nil : barcode
                )
            }
            // Build barcode index and prefer it for cross-checks
            barcodeToCSVRow.removeAll()
            for row in csvData {
                if let bc = row.barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !bc.isEmpty, barcodeToCSVRow[bc] == nil {
                    barcodeToCSVRow[bc] = row
                }
            }
            print("🔍 [CSV] Parsed \(csvData.count) usable data rows")
            print("🔍 [CSV] Unique barcodes indexed: \(barcodeToCSVRow.count)")
            if !barcodeToCSVRow.isEmpty {
                let sampleKeys = Array(barcodeToCSVRow.keys.prefix(10))
                print("🔍 [CSV] Sample barcode keys: \(sampleKeys)")
            }
            if !barcodeToCSVRow.isEmpty {
                csvOriginals = Set(barcodeToCSVRow.keys)
            } else {
                csvOriginals = Set(csvData.map { $0.original })
            }
            self.csvURL = url
            
            if !parseResult.warnings.isEmpty {
                print("CSV parsing warnings:")
                parseResult.warnings.forEach { print("  - \($0)") }
                print("Detected delimiter: \(parseResult.delimiter), columns: \(parseResult.columnCount)")
            }
            
        } catch {
            print("Error loading CSV: \(error)")
            csvData = []
            csvOriginals = []
        }
    }

    private func normalizeHeader(_ s: String) -> String {
        return s.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
    }
    
    private func sortFiles(_ files: [URL]) -> [URL] {
        switch config.dataSource {
        case .csv:
            // Natural sort by filename to maintain stable order
            return files.sorted { a, b in
                let n1 = a.lastPathComponent
                let n2 = b.lastPathComponent
                return n1.localizedStandardCompare(n2) == .orderedAscending
            }
            
        case .filenames:
            // Sort by team -> player -> pose number for proper sequential renumbering
            return files.sorted { url1, url2 in
                let parsed1 = parseFilenameComponents(url1.lastPathComponent)
                let parsed2 = parseFilenameComponents(url2.lastPathComponent)
                
                // Compare team names first
                if parsed1.team != parsed2.team {
                    return parsed1.team.localizedStandardCompare(parsed2.team) == .orderedAscending
                }
                
                // Then compare player names
                if parsed1.player != parsed2.player {
                    return parsed1.player.localizedStandardCompare(parsed2.player) == .orderedAscending
                }
                
                // Finally compare pose numbers (numerically if both are numbers)
                if let pose1 = parsed1.poseNumber, let pose2 = parsed2.poseNumber {
                    if let num1 = Int(pose1), let num2 = Int(pose2) {
                        return num1 < num2
                    }
                }
                
                // Fallback to filename comparison
                return url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent) == .orderedAscending
            }
        }
    }
    
    // Helper to parse filename components for sorting
    private func parseFilenameComponents(_ fileName: String) -> (team: String, player: String, poseNumber: String?) {
        if let parsed = parseFilenameMetadata(fileName) {
            return (team: parsed.team, player: parsed.player, poseNumber: parsed.poseNumber)
        }
        return (team: fileName, player: "", poseNumber: nil)
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
        print("🔍 [Ops] Generating rename operations for \(files.count) files")
        
        // Reset counters
        subjectCounters = [:]
        
        // Generate new names
        for file in files {
            let originalName = file.lastPathComponent
            let newName = generateNewName(for: originalName, url: file)

            let isBuddy = isBuddyPhoto(originalName)
            print("🔍 [Ops] \(originalName) proposed → \(newName); buddy=\(isBuddy)")
            // For buddy photos, we still need an operation even if the name does not change
            if originalName != newName || isBuddy {
                let hasConflict = existingNames.contains(newName) && newName != originalName
                if hasConflict {
                    print("⚠️ [Ops] Name conflict detected for \(newName) in directory \(file.deletingLastPathComponent().path)")
                }
                operations.append(RenameOperation(
                    originalName: originalName,
                    newName: newName,
                    hasConflict: hasConflict,
                    sourceURL: file
                ))
            } else if config.dataSource == .filenames && !isBuddy {
                // In filename mode, if name didn't change, it means parsing failed
                unparseableFilenameURLs.append(file)
                print("⚠️ [Ops] In filename mode, unable to parse name for \(originalName); marking as unparseable")
            }
        }
        
        print("✅ [Ops] Prepared \(operations.count) rename operations")
        
        return operations
    }
    
    private func generateNewName(for originalName: String, url: URL) -> String {
        switch config.dataSource {
        case .csv:
            return generateNameFromCSV(originalName, url: url)
        case .filenames:
            return generateNameFromFilename(originalName)
        }
    }
    
    private func generateNameFromCSV(_ originalName: String, url: URL) -> String {
        // Prefer metadata barcode match (precomputed); fallback to original filename match
        var matchedRow: CSVRow? = nil
        let barcodeInImage = fileBarcodeMap[url]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("🔍 [CSV] Resolving name for \(originalName) at \(url.lastPathComponent); barcodeInImage='\(barcodeInImage)'")
        if !barcodeInImage.isEmpty {
            matchedRow = barcodeToCSVRow[barcodeInImage]
            print("   [CSV] Match by barcode? \(matchedRow != nil)")
        } else {
            print("   [CSV] No barcode found in file metadata")
        }
        if matchedRow == nil {
            matchedRow = csvData.first(where: { $0.original == originalName })
            print("   [CSV] Match by original filename? \(matchedRow != nil)")
        }
        guard let row = matchedRow else {
            print("⚠️ [CSV] No CSV row found for \(originalName); returning original name unchanged")
            return originalName
        }
        print("✅ [CSV] Using CSV row for group='\(row.groupName)', fullName='\(row.fullName)'")
        
        let ext = (originalName as NSString).pathExtension
        let key = "\(row.groupName)_\(row.fullName)"
        let count: Int
        if config.handleBuddySeparately && isBuddyPhoto(originalName) {
            count = getAndIncrementBuddyCounter(for: key)
        } else {
            count = getAndIncrementCounter(for: key)
        }
        
        return "\(row.groupName)_\(row.fullName)_\(count).\(ext)"
    }
    
    private func generateNameFromFilename(_ originalName: String) -> String {
        let ext = (originalName as NSString).pathExtension
        
        guard let parsed = parseFilenameMetadata(originalName) else {
            print("   ⚠️ Unable to parse filename '\(originalName)' after normalization. Returning unchanged.")
            return originalName
        }
        
        let key = "\(parsed.team)_\(parsed.player)"
        let count = getAndIncrementCounter(for: key)
        
        let newName = "\(parsed.team)_\(parsed.player)_\(count).\(ext)"
        print("   ✅ Filename parsed — Team: '\(parsed.team)', Player: '\(parsed.player)', Pose token: \(parsed.poseNumber ?? "none"), Assigned pose: \(count)")
        print("   Result: \(originalName) → \(newName)")
        
        return newName
    }
    
    private func getAndIncrementCounter(for key: String) -> Int {
        let current = subjectCounters[key, default: 0] + 1
        subjectCounters[key] = current
        return current
    }
    
    private func getAndIncrementBuddyCounter(for key: String) -> Int {
        let start = Constants.FileNaming.buddyPoseStart
        let current = buddySubjectCounters[key, default: start - 1] + 1
        buddySubjectCounters[key] = current
        return current
    }
    
    private func performRename(_ operation: RenameOperation) async throws {
        // Buddy photos go to Buddy Photos under the selected base folder (Output/Extracted/Custom)
        var baseDir = operation.sourceURL.deletingLastPathComponent()
        if config.handleBuddySeparately && isBuddyPhoto(operation.originalName) {
            let selectedBase = config.sourceFolder.url(in: jobFolder, customPath: config.customSourcePath)
            let buddyDir = selectedBase.appendingPathComponent(Constants.Folders.buddyPhotos)
            if !fileManager.fileExists(atPath: buddyDir.path, isDirectory: nil) {
                try? fileManager.createDirectory(at: buddyDir, withIntermediateDirectories: true, attributes: nil)
            }
            baseDir = buddyDir
            // If CSV does not provide a new name, keep original name when moving buddy photo
            if operation.newName == operation.originalName {
                let dest = baseDir.appendingPathComponent(operation.originalName)
                if fileManager.fileExists(atPath: dest.path, isDirectory: nil) {
                    // resolve conflict by adding suffix
                    let unique = generateUniqueFileName(baseName: operation.originalName, in: baseDir)
                    try fileManager.moveItem(at: operation.sourceURL, to: baseDir.appendingPathComponent(unique))
                    return
                } else {
                    try fileManager.moveItem(at: operation.sourceURL, to: dest)
                    return
                }
            }
        }
        let destinationURL = baseDir.appendingPathComponent(operation.finalName)
        
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
    
    private func isBuddyPhoto(_ fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
        return base.range(of: "buddy", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    
    private struct ParsedFilenameMetadata {
        let team: String
        let player: String
        let poseNumber: String?
    }
    
    private func parseFilenameMetadata(_ originalName: String) -> ParsedFilenameMetadata? {
        let baseName = (originalName as NSString).deletingPathExtension
        let segments = baseName
            .split(separator: "_", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        
        guard !segments.isEmpty else { return nil }
        
        let teamRaw = segments[0]
        let team = normalizeWhitespace(in: teamRaw)
        guard !team.isEmpty else { return nil }
        
        let remainderSegments = segments.dropFirst()
        guard !remainderSegments.isEmpty else { return nil }
        
        let remainderJoined = remainderSegments.joined(separator: " ")
        var normalizedRemainder = normalizeWhitespace(in: remainderJoined)
        guard !normalizedRemainder.isEmpty else { return nil }
        
        var poseNumber: String? = nil
        if let digitsRange = normalizedRemainder.range(of: "\\d+$", options: .regularExpression) {
            poseNumber = String(normalizedRemainder[digitsRange])
            normalizedRemainder = String(normalizedRemainder[..<digitsRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let playerSource = normalizedRemainder.isEmpty ? remainderJoined : normalizedRemainder
        let player = normalizeWhitespace(in: playerSource)
        guard !player.isEmpty else { return nil }
        
        return ParsedFilenameMetadata(team: team, player: player, poseNumber: poseNumber)
    }
    
    private func normalizeWhitespace(in input: String) -> String {
        guard !input.isEmpty else { return input }
        let replaced = input.replacingOccurrences(of: "_", with: " ")
        let components = replaced.split { $0.isWhitespace }
        return components.joined(separator: " ")
    }
    
    private func runPoseValidation(using files: [URL]) async {
        var playerPoseCounts: [String: Int] = [:]
        
        // Count poses per player
        for operation in filesToRename {
            // Exclude Coach, Manager and Buddy files from pose count validation
            if isCoachPhoto(operation.newName) || isManagerPhoto(operation.newName) || isBuddyPhoto(operation.originalName) {
                continue
            }
            let parts = operation.newName.components(separatedBy: "_")
            if parts.count >= 3,
               Int(parts.last?.components(separatedBy: ".").first ?? "") != nil {
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
    
    private func isCoachPhoto(_ fileName: String) -> Bool {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return false }
        let token = parts[1].uppercased()
        if token.hasPrefix("COACH") {
            let suffix = token.dropFirst("COACH".count)
            return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
        }
        return false
    }

    private func isManagerPhoto(_ fileName: String) -> Bool {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return false }
        let token = parts[1].uppercased()
        if token.hasPrefix("MANAGER") {
            let suffix = token.dropFirst("MANAGER".count)
            return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
        }
        return false
    }

    private func buildBarcodeMap(for urls: [URL]) async {
        fileBarcodeMap.removeAll(keepingCapacity: true)
        print("🔍 [Meta] Building barcode map for \(urls.count) files")
        await withTaskGroup(of: (URL, String?).self) { group in
            for url in urls {
                group.addTask { [imageService] in
                    let meta = try? await imageService.getImageMetadata(from: url)
                    return (url, meta?.copyrightNotice)
                }
            }
            for await (url, value) in group {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    fileBarcodeMap[url] = trimmed
                    print("✅ [Meta] \(url.lastPathComponent) → barcode='\(trimmed)'")
                } else {
                    print("⚠️ [Meta] \(url.lastPathComponent) → no barcode found in metadata")
                }
            }
        }
        print("🔍 [Meta] Barcode map built with \(fileBarcodeMap.count) entries")
    }
    
    private func createPoseCountIssues(from validation: PoseCountValidation) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        
        for playerIssue in validation.playersWithIssues {
            // Find all files for this player
            let playerFiles = filesToRename
                .filter { operation in
                    let parts = operation.newName.components(separatedBy: "_")
                    if parts.count >= 3,
                       Int(parts.last?.components(separatedBy: ".").first ?? "") != nil {
                        let playerKey = parts.dropLast().joined(separator: "_")
                        return playerKey == playerIssue.player
                    }
                    return false
                }
                .map { $0.sourceURL }
            
            let issueType = validation.issueType(for: playerIssue.count)
            let message = "Player '\(playerIssue.player)' has \(playerIssue.count) poses (\(issueType.description))"
            let suggestion = validation.expectedCount > playerIssue.count ? 
                "Add missing pose photos for this player" : 
                "Remove extra pose photos or verify player assignment"
            
            // Create one issue per player with all their files
            let issue = ValidationIssue(
                severity: .warning,
                message: message,
                suggestion: suggestion,
                affectedFiles: playerFiles
            )
            issues.append(issue)
        }
        
        return issues
    }
    
    private func createUnparseableFilenameIssues() -> [ValidationIssue] {
        guard !unparseableFilenameURLs.isEmpty else { return [] }
        
        let message = "Found \(unparseableFilenameURLs.count) file(s) that don't match the expected filename format"
        let suggestion = "Filenames must be in format: Team_PlayerName_PoseNumber.ext (e.g., 'Eagles_John Smith_1.jpg'). Files need at least 3 parts separated by underscores, with the last part before the extension being a number."
        
        let issue = ValidationIssue(
            severity: .warning,
            message: message,
            suggestion: suggestion,
            affectedFiles: unparseableFilenameURLs
        )
        
        return [issue]
    }
}
