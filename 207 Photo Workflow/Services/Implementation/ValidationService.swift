import Foundation
import AppKit

// MARK: - Validation Service Implementation
class ValidationService: ValidationServiceProtocol {
    private let fileManager: FileManagerProtocol
    
    init(fileManager: FileManagerProtocol = FileManager.default) {
        self.fileManager = fileManager
    }
    
    func preflightValidationForRename(jobFolder: URL,
                                      files: [URL],
                                      config: OperationConfig.RenameConfig,
                                      csvService: CSVServiceProtocol,
                                      imageService: ImageServiceProtocol) async -> ValidationReport {
        var issues: [ValidationIssue] = []
        var requiredDiskSpace: Int64? = nil
        var availableDiskSpace: Int64? = nil
        
        // 1) Required folders
        for folder in Operation.renameFiles.requiredFolders {
            let folderURL = jobFolder.appendingPathComponent(folder)
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                issues.append(ValidationIssue(severity: .error, message: "Missing required folder: \(folder)", suggestion: "Create the \(folder) folder in the job directory."))
            }
        }
        
        // 2) Permissions: attempt to create temp file in source directory
        let sourceURL = jobFolder.appendingPathComponent(config.sourceFolder.folderName)
        let testURL = sourceURL.appendingPathComponent(".perm_test_\(UUID().uuidString)")
        do {
            try "test".write(to: testURL, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testURL)
        } catch {
            issues.append(ValidationIssue(severity: .error, message: "Write permission denied in \(config.sourceFolder.folderName)", suggestion: "Grant folder access when prompted or choose another job folder."))
        }
        
        // 3) CSV validation (and cross-check) if needed
        var csvOriginals: Set<String> = []
        if config.dataSource == .csv {
            do {
                let rootContents = try fileManager.contentsOfDirectory(at: jobFolder, includingPropertiesForKeys: nil, options: [])
                if let csvURL = rootContents.first(where: { $0.pathExtension.lowercased() == Constants.FileExtensions.csv }) {
                    let result = try await csvService.validateCSVFormat(csvURL)
                    if !result.isValid {
                        for error in result.errors.prefix(5) {
                            issues.append(ValidationIssue(severity: .error, message: error.localizedDescription, suggestion: "Fix CSV format and retry."))
                        }
                        if result.errors.count > 5 {
                            issues.append(ValidationIssue(severity: .info, message: "Additional CSV issues not shown", suggestion: nil))
                        }
                    } else {
                        // Parse quickly to build originals set for cross-check
                        let parsed = try await csvService.parseCSV(from: csvURL)
                        for row in parsed.rows {
                            if row.count >= Constants.CSV.minFieldCount {
                                csvOriginals.insert(row[0])
                            }
                        }
                    }
                } else {
                    issues.append(ValidationIssue(severity: .warning, message: "No CSV file found in job root", suggestion: "Switch data source to Filenames or add a CSV."))
                }
            } catch {
                issues.append(ValidationIssue(severity: .error, message: "CSV validation failed: \(error.localizedDescription)", suggestion: "Verify encoding and delimiter."))
            }
        }
        
        // 4) Image integrity quick check + filename validity + CSV cross-check
        do {
            let results = try await imageService.validateImages(at: files)
            let invalid = results.filter { !$0.1 }
            if !invalid.isEmpty {
                issues.append(ValidationIssue(severity: .warning, message: "\(invalid.count) invalid image(s) will be skipped", suggestion: "Re-export corrupted files."))
            }
            
            // Check for invalid filename characters and CSV misses
            let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
            var csvMisses: [String] = []
            var badNames: [String] = []
            for url in files {
                let name = url.lastPathComponent
                if name.rangeOfCharacter(from: invalidChars) != nil {
                    badNames.append(name)
                }
                if config.dataSource == .csv && !csvOriginals.isEmpty && !csvOriginals.contains(name) {
                    csvMisses.append(name)
                }
            }
            if !badNames.isEmpty {
                issues.append(ValidationIssue(severity: .warning, message: "\(badNames.count) file(s) have invalid characters in filename", suggestion: "Rename files to remove characters: / \\ : * ? \" < > |"))
            }
            if !csvMisses.isEmpty {
                issues.append(ValidationIssue(severity: .warning, message: "\(csvMisses.count) image(s) not found in CSV", suggestion: "Add these originals to the CSV or switch to Filename mode."))
            }
        } catch {
            issues.append(ValidationIssue(severity: .warning, message: "Image validation skipped due to error", suggestion: error.localizedDescription))
        }
        
        // 5) Disk space estimate (for backups)
        var totalSize: Int64 = 0
        for f in files {
            if let attrs = try? fileManager.attributesOfItem(atPath: f.path),
               let size = attrs[.size] as? Int64 { totalSize += size }
        }
        requiredDiskSpace = totalSize
        if let fsInfo = try? fileSystemFreeSpace(at: jobFolder) {
            availableDiskSpace = fsInfo
            if totalSize > fsInfo {
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                let needed = fmt.string(fromByteCount: totalSize)
                issues.append(ValidationIssue(severity: .error, message: "Insufficient disk space for backup (needs \(needed))", suggestion: "Free up space."))
            }
        }
        
        return ValidationReport(operation: .renameFiles, issues: issues, requiredDiskSpace: requiredDiskSpace, availableDiskSpace: availableDiskSpace)
    }
    
    private func fileSystemFreeSpace(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}


