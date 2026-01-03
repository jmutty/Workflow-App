import Foundation
import AppKit

// MARK: - Validation Service Implementation
class ValidationService: ValidationServiceProtocol {
    private let fileManager: FileManagerProtocol
    
    init(fileManager: FileManagerProtocol = FileManager.default) {
        self.fileManager = fileManager
    }
    
    @MainActor
    func preflightValidationForRename(jobFolder: URL,
                                      files: [URL],
                                      config: OperationConfig.RenameConfig,
                                      csvService: CSVServiceProtocol,
                                      imageService: ImageServiceProtocol,
                                      flagStore: IssueFlagStore? = nil) async -> ValidationReport {
        var issues: [ValidationIssue] = []
        var requiredDiskSpace: Int64? = nil
        var availableDiskSpace: Int64? = nil
        
        // 1) Required folders
        for folder in Operation.renameFiles.requiredFolders {
            let folderURL = jobFolder.appendingPathComponent(folder)
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                issues.append(ValidationIssue(severity: .error, message: "Missing required folder: \(folder)", suggestion: "Create the \(folder) folder in the job directory.", affectedFiles: []))
            }
        }
        
        // 2) Permissions: attempt to create temp file in the actual selected source directory
        let sourceURL = config.sourceFolder.url(in: jobFolder, customPath: config.customSourcePath)
        let testURL = sourceURL.appendingPathComponent(".perm_test_\(UUID().uuidString)")
        do {
            try "test".write(to: testURL, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testURL)
        } catch {
            let folderLabel = config.sourceFolder.folderName
            issues.append(ValidationIssue(
                severity: .error,
                message: "Write permission denied in \(folderLabel)",
                suggestion: "Grant access to the selected folder when prompted or choose another folder.",
                affectedFiles: []
            ))
        }
        
        // 3) CSV validation (and cross-check) if needed
        var csvOriginals: Set<String> = []
        var csvBarcodes: Set<String> = []
        if config.dataSource == .csv {
            do {
                let rootContents = try fileManager.contentsOfDirectory(
                    at: jobFolder,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                
                let csvFiles = rootContents.filter { $0.pathExtension.lowercased() == Constants.FileExtensions.csv }
                
                if csvFiles.isEmpty {
                    issues.append(
                        ValidationIssue(
                            severity: .warning,
                            message: "No CSV file found in job root",
                            suggestion: "Switch data source to Filenames or add a CSV.",
                            affectedFiles: []
                        )
                    )
                    // Nothing more to do for CSV-based checks
                    return ValidationReport(operation: .renameFiles, issues: issues, requiredDiskSpace: nil, availableDiskSpace: nil)
                }
                
                // Prefer the same style of CSV that the rename flow uses:
                // score by structural consistency, presence of expected headers,
                // and strongly favor any CSV that contains a barcode column.
                var bestURL: URL?
                var bestParse: CSVParseResult?
                var bestScore: Double = -1
                
                for url in csvFiles {
                    do {
                        let parsed = try await csvService.parseCSV(from: url)
                        let columnCount = max(1, parsed.columnCount)
                        let totalRows = max(1, parsed.rows.count)
                        let consistentRows = parsed.rows.filter { $0.count == columnCount }.count
                        var score = Double(consistentRows) / Double(totalRows)
                        
                        let headers = parsed.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        let normalizedHeaders = Set(
                            headers.map {
                                $0.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
                            }
                        )
                        let expectedHeaders = ["photo", "firstname", "lastname", "group", "barcode"]
                        let headerMatches = expectedHeaders.filter { normalizedHeaders.contains($0) }.count
                        score += Double(headerMatches) * 0.1
                        
                        let hasBarcodeColumn =
                            normalizedHeaders.contains("barcode") ||
                            normalizedHeaders.contains("barcode1") ||
                            normalizedHeaders.contains("barcode(1)") ||
                            normalizedHeaders.contains(where: { $0.hasPrefix("barcode") })
                        if hasBarcodeColumn {
                            score += 10.0
                        }
                        
                        if score > bestScore {
                            bestScore = score
                            bestURL = url
                            bestParse = parsed
                        }
                    } catch {
                        // Skip CSVs that fail to parse here; they will be reported
                        // if they are the only available CSV.
                        continue
                    }
                }
                
                guard let csvURL = bestURL, let parsed = bestParse else {
                    issues.append(
                        ValidationIssue(
                            severity: .error,
                            message: "Unable to read CSV file in job root",
                            suggestion: "Verify the CSV encoding and delimiter, or regenerate the CSV.",
                            affectedFiles: []
                        )
                    )
                    return ValidationReport(operation: .renameFiles, issues: issues, requiredDiskSpace: nil, availableDiskSpace: nil)
                }
                
                let validationResult = try await csvService.validateCSVFormat(csvURL)
                if !validationResult.isValid {
                    for error in validationResult.errors.prefix(5) {
                        issues.append(
                            ValidationIssue(
                                severity: .error,
                                message: error.localizedDescription,
                                suggestion: "Fix CSV format and retry.",
                                affectedFiles: []
                            )
                        )
                    }
                    if validationResult.errors.count > 5 {
                        issues.append(
                            ValidationIssue(
                                severity: .info,
                                message: "Additional CSV issues not shown",
                                suggestion: nil,
                                affectedFiles: []
                            )
                        )
                    }
                } else {
                    // Use the parsed result from above to build identity sets
                    let headers = parsed.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    var nameToIndex: [String: Int] = [:]
                    for (i, h) in headers.enumerated() {
                        let key = h.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
                        nameToIndex[key] = i
                    }
                    func findIndex(_ keys: [String]) -> Int? {
                        for k in keys {
                            let norm = k.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression).lowercased()
                            if let i = nameToIndex[norm] { return i }
                        }
                        return nil
                    }
                    
                    let originalIdx = findIndex(["SPA", "Photo", "NEW FILE NAME", "FILENAME"]) ?? 0
                    let barcodeIdx = findIndex(["BARCODE (1)", "BARCODE(1)", "BARCODE1", "BARCODE"]) ?? findIndex(["IDENTIFIER"]) ?? nil
                    
                    for row in parsed.rows {
                        if row.count >= Constants.CSV.minFieldCount {
                            if originalIdx < row.count {
                                csvOriginals.insert(row[originalIdx])
                            }
                            if let bIdx = barcodeIdx, bIdx < row.count {
                                let val = row[bIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty {
                                    csvBarcodes.insert(val)
                                }
                            }
                        }
                    }
                }
            } catch {
                issues.append(ValidationIssue(severity: .error, message: "CSV validation failed: \(error.localizedDescription)", suggestion: "Verify encoding and delimiter.", affectedFiles: []))
            }
        }
        
        // 4) Image integrity quick check + filename validity + CSV cross-check
        do {
            let results = try await imageService.validateImages(at: files)
            let invalid = results.filter { !$0.1 }
            if !invalid.isEmpty {
                issues.append(ValidationIssue(severity: .warning, message: "\(invalid.count) invalid image(s) will be skipped", suggestion: "Re-export corrupted files.", affectedFiles: invalid.map { $0.0 }))
            }
            
            // Check for invalid filename characters and CSV misses
            let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
            var csvMisses: [String] = []
            var badNames: [String] = []
            var fileBarcodeMap: [URL: String] = [:]
            // Helper: detect Buddy/Coach files by naming token conventions
            func isBuddyOrCoach(_ fileName: String) -> Bool {
                let base = (fileName as NSString).deletingPathExtension
                let parts = base.split(separator: "_").map(String.init)
                guard parts.count >= 2 else { return false }
                let token = parts[1].uppercased()
                if token.hasPrefix("BUDDY") {
                    let suffix = token.dropFirst("BUDDY".count)
                    return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
                }
                if token.hasPrefix("COACH") {
                    let suffix = token.dropFirst("COACH".count)
                    return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
                }
                return false
            }
            if !csvBarcodes.isEmpty {
                // Build barcode map for files (IPTC Copyright Notice)
                await withTaskGroup(of: (URL, String?).self) { group in
                    for url in files {
                        group.addTask {
                            let meta = try? await imageService.getImageMetadata(from: url)
                            return (url, meta?.copyrightNotice)
                        }
                    }
                    for await (u, val) in group {
                        if let v = val?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                            fileBarcodeMap[u] = v
                        }
                    }
                }
            }
            for url in files {
                let name = url.lastPathComponent
                if name.rangeOfCharacter(from: invalidChars) != nil {
                    badNames.append(name)
                }
                if config.dataSource == .csv {
                    if !csvBarcodes.isEmpty {
                        let barcode = fileBarcodeMap[url] ?? ""
                        if barcode.isEmpty || !csvBarcodes.contains(barcode) { csvMisses.append(name) }
                    } else if !csvOriginals.isEmpty && !csvOriginals.contains(name) {
                        csvMisses.append(name)
                    }
                }
            }
            // Create individual issues for each file with invalid characters
            for url in files {
                let name = url.lastPathComponent
                if name.rangeOfCharacter(from: invalidChars) != nil {
                    let issue = ValidationIssue(
                        severity: .warning, 
                        message: "File '\(name)' has invalid characters in filename", 
                        suggestion: "Rename file to remove characters: / \\ : * ? \" < > |", 
                        affectedFiles: [url]
                    )
                    if flagStore?.isDismissed(issue.id) != true {
                        issues.append(issue)
                    }
                }
            }
            
            // Create individual issues for each file not found in CSV
            if config.dataSource == .csv {
                let hint = !csvBarcodes.isEmpty ? "by barcode (IPTC/TIFF/XMP rights)" : "by original filename"
                for url in files {
                    let name = url.lastPathComponent
                    let isMatched: Bool
                    if !csvBarcodes.isEmpty {
                        let barcode = fileBarcodeMap[url] ?? ""
                        isMatched = !barcode.isEmpty && csvBarcodes.contains(barcode)
                    } else {
                        isMatched = !csvOriginals.isEmpty && csvOriginals.contains(name)
                    }
                    
                    // Skip Buddy/Coach files from CSV-miss issues
                    if !isMatched && !isBuddyOrCoach(name) {
                        let issue = ValidationIssue(
                            severity: .warning, 
                            message: "Image '\(name)' not found in CSV (matched \(hint))", 
                            suggestion: "Ensure the image has the correct barcode in metadata, or add a row to the CSV.", 
                            affectedFiles: [url]
                        )
                        if flagStore?.isDismissed(issue.id) != true {
                            issues.append(issue)
                        }
                    }
                }
            }
        } catch {
            issues.append(ValidationIssue(severity: .warning, message: "Image validation skipped due to error", suggestion: error.localizedDescription, affectedFiles: []))
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
                issues.append(ValidationIssue(severity: .error, message: "Insufficient disk space for backup (needs \(needed))", suggestion: "Free up space.", affectedFiles: []))
            }
        }
        
        return ValidationReport(operation: .renameFiles, issues: issues, requiredDiskSpace: requiredDiskSpace, availableDiskSpace: availableDiskSpace)
    }
    
    private func fileSystemFreeSpace(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}


