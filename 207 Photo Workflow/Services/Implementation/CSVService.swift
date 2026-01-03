import Foundation

// MARK: - CSV Service Implementation
class CSVService: CSVServiceProtocol {
    
    // MARK: - Properties
    private let maxFileSize: Int64 = 100_000_000 // 100MB limit
    private let maxColumns = 100
    private let chunkSize = 65536 // 64KB chunks for streaming
    
    // Common delimiters to try (restricted to comma and semicolon per app needs)
    private let possibleDelimiters = [",", ";"]
    
    // MARK: - Public Methods
    
    func parseCSV(from url: URL) async throws -> CSVParseResult {
        // Check file exists and size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw PhotoWorkflowError.unableToReadFile(path: url.path, underlyingError: nil)
        }
        
        if fileSize > maxFileSize {
            // Use streaming for large files
            return try await parseCSVStreaming(from: url)
        } else {
            // Load entire file for small files
            let encoding = try detectEncoding(for: url)
            let content = try String(contentsOf: url, encoding: encoding)
            return try parseCSV(from: content, encoding: encoding)
        }
    }
    
    func parseCSV(from content: String, encoding: String.Encoding) throws -> CSVParseResult {
        guard !content.isEmpty else {
            throw PhotoWorkflowError.csvParsingError(line: 0, reason: "Empty file")
        }
        
        let delimiter = detectDelimiter(in: content)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !lines.isEmpty else {
            throw PhotoWorkflowError.csvParsingError(line: 0, reason: "No data found")
        }
        
        // Parse headers
        let headers = parseCSVLine(lines[0], delimiter: delimiter)
        guard !headers.isEmpty else {
            throw PhotoWorkflowError.missingCSVHeaders
        }
        
        // Parse rows
        var rows: [[String]] = []
        var warnings: [String] = []
        
        for (index, line) in lines.dropFirst().enumerated() {
            let row = parseCSVLine(line, delimiter: delimiter)
            
            // Check column count consistency
            if row.count != headers.count {
                warnings.append("Line \(index + 2): Expected \(headers.count) columns, found \(row.count)")
                
                // Pad or truncate row to match header count
                let adjustedRow = adjustRow(row, to: headers.count)
                rows.append(adjustedRow)
            } else {
                rows.append(row)
            }
        }
        
        return CSVParseResult(
            headers: headers,
            rows: rows,
            encoding: encoding,
            delimiter: delimiter,
            lineCount: lines.count,
            warnings: warnings
        )
    }
    
    func writeCSV(_ rows: [[String]], to url: URL, encoding: String.Encoding = .utf8) async throws {
        var csvContent = ""
        
        // Add BOM for UTF-8 if needed
        if encoding == .utf8 {
            csvContent = Constants.CSV.bomPrefix
        }
        
        // Write rows
        for row in rows {
            let escapedRow = row.map { escapeCSVField($0) }
            csvContent += escapedRow.joined(separator: ",") + "\n"
        }
        
        // Write to file
        do {
            try csvContent.write(to: url, atomically: true, encoding: encoding)
        } catch {
            throw PhotoWorkflowError.unableToWriteFile(path: url.path, underlyingError: error)
        }
    }
    
    func validateCSVFormat(_ url: URL) async throws -> CSVValidationResult {
        var errors: [CSVValidationResult.CSVValidationError] = []
        var warnings: [String] = []
        
        // Try to detect encoding
        let encoding: String.Encoding
        do {
            encoding = try detectEncoding(for: url)
        } catch {
            errors.append(.invalidEncoding)
            return CSVValidationResult(
                isValid: false,
                errors: errors,
                warnings: warnings,
                encoding: nil,
                delimiter: nil,
                expectedColumns: nil,
                actualColumns: nil
            )
        }
        
        // Try to read file
        let content: String
        do {
            content = try String(contentsOf: url, encoding: encoding)
        } catch {
            errors.append(.invalidEncoding)
            return CSVValidationResult(
                isValid: false,
                errors: errors,
                warnings: warnings,
                encoding: encoding,
                delimiter: nil,
                expectedColumns: nil,
                actualColumns: nil
            )
        }
        
        // Check if empty
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyFile)
            return CSVValidationResult(
                isValid: false,
                errors: errors,
                warnings: warnings,
                encoding: encoding,
                delimiter: nil,
                expectedColumns: nil,
                actualColumns: nil
            )
        }
        
        // Detect delimiter
        let delimiter = detectDelimiter(in: content)
        
        // Parse and validate
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !lines.isEmpty else {
            errors.append(.emptyFile)
            return CSVValidationResult(
                isValid: false,
                errors: errors,
                warnings: warnings,
                encoding: encoding,
                delimiter: delimiter,
                expectedColumns: nil,
                actualColumns: nil
            )
        }
        
        // Check headers
        let headers = parseCSVLine(lines[0], delimiter: delimiter)
        if headers.isEmpty {
            errors.append(.missingHeaders)
        }
        
        let expectedColumns = headers.count
        
        // Check if too many columns
        if expectedColumns > maxColumns {
            errors.append(.tooManyColumns(count: expectedColumns, max: maxColumns))
        }
        
        // Check row consistency
        for (index, line) in lines.dropFirst().enumerated() {
            let row = parseCSVLine(line, delimiter: delimiter)
            if row.count != expectedColumns {
                errors.append(.inconsistentColumns(
                    expected: expectedColumns,
                    row: index + 2,
                    actual: row.count
                ))
                
                // Only report first 10 inconsistencies
                if errors.count >= 10 {
                    warnings.append("Additional row inconsistencies not shown")
                    break
                }
            }
        }
        
        return CSVValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings,
            encoding: encoding,
            delimiter: delimiter,
            expectedColumns: expectedColumns,
            actualColumns: headers.count
        )
    }
    
    func detectEncoding(for url: URL) throws -> String.Encoding {
        let data = try Data(contentsOf: url)
        
        // Check for BOM markers
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        } else if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        } else if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return .utf32LittleEndian
        } else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return .utf32BigEndian
        }
        
        // Try common encodings
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .windowsCP1252,
            .isoLatin1,
            .macOSRoman
        ]
        
        for encoding in encodings {
            if let _ = String(data: data, encoding: encoding) {
                return encoding
            }
        }
        
        throw PhotoWorkflowError.csvEncodingError(encoding: "Unknown")
    }
    
    func detectDelimiter(in content: String) -> String {
        // Take first few lines for analysis
        let sampleLines = content.components(separatedBy: .newlines)
            .prefix(10)
            .filter { !$0.isEmpty }

        guard !sampleLines.isEmpty else {
            return ","
        }

        // Evaluate three candidates: comma only, semicolon only, both
        enum Candidate: String, CaseIterable { case comma = ",", semicolon = ";", both = ",;" }

        struct CandidateScore { let candidate: Candidate; let headerCols: Int; let matchRatio: Double }

        var scores: [CandidateScore] = []
        for candidate in Candidate.allCases {
            guard let header = sampleLines.first else { continue }

            let headerCols: Int = {
                switch candidate {
                case .comma:
                    return parseCSVLine(header, delimiters: [","]).count
                case .semicolon:
                    return parseCSVLine(header, delimiters: [";"]).count
                case .both:
                    return parseCSVLine(header, delimiters: [",", ";"]).count
                }
            }()

            if headerCols == 0 { continue }

            let rows = Array(sampleLines.dropFirst())
            if rows.isEmpty {
                scores.append(CandidateScore(candidate: candidate, headerCols: headerCols, matchRatio: headerCols >= Constants.CSV.minFieldCount ? 1.0 : 0.0))
                continue
            }

            let matches: Int = rows.reduce(0) { acc, line in
                let cols: Int
                switch candidate {
                case .comma:
                    cols = parseCSVLine(line, delimiters: [","]).count
                case .semicolon:
                    cols = parseCSVLine(line, delimiters: [";"]).count
                case .both:
                    cols = parseCSVLine(line, delimiters: [",", ";"]).count
                }
                return acc + (cols == headerCols ? 1 : 0)
            }

            let ratio = Double(matches) / Double(rows.count)
            scores.append(CandidateScore(candidate: candidate, headerCols: headerCols, matchRatio: ratio))
        }

        // Choose the candidate with highest match ratio; tie-breaker prefers 'both', then higher headerCols
        guard let best = scores.sorted(by: { (a, b) -> Bool in
            if a.matchRatio != b.matchRatio { return a.matchRatio > b.matchRatio }
            if a.candidate == .both && b.candidate != .both { return true }
            if b.candidate == .both && a.candidate != .both { return false }
            return a.headerCols > b.headerCols
        }).first else {
            return ","
        }

        return best.candidate.rawValue
    }
    
    // MARK: - Private Methods
    
    private func parseCSVLine(_ line: String, delimiter: String) -> [String] {
        // Map special ",;" token to both delimiters
        let delimiters: Set<Character>
        if delimiter == ",;" {
            delimiters = [",", ";"]
        } else if let first = delimiter.first {
            delimiters = [first]
        } else {
            delimiters = [","]
        }
        return parseCSVLine(line, delimiters: delimiters)
    }

    private func parseCSVLine(_ line: String, delimiters: Set<Character>) -> [String] {
        var result: [String] = []
        var currentField = ""
        var inQuotes = false

        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let char = characters[index]

            if char == "\"" {
                if inQuotes {
                    // If next char is also a quote, it's an escaped quote
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        currentField.append("\"")
                        index += 1 // Skip the escaped quote
                    } else {
                        // End of quoted field
                        inQuotes = false
                    }
                } else {
                    // Start of quoted field
                    inQuotes = true
                }
            } else if !inQuotes && delimiters.contains(char) {
                // End of field
                result.append(cleanField(currentField))
                currentField = ""
            } else {
                // Regular character
                currentField.append(char)
            }

            index += 1
        }

        // Append the last field
        result.append(cleanField(currentField))

        return result
    }
    
    private func cleanField(_ field: String) -> String {
        var cleaned = field.trimmingCharacters(in: .whitespaces)
        // Strip UTF-8 BOM if present at start of first field/line
        if cleaned.hasPrefix(Constants.CSV.bomPrefix) {
            cleaned = String(cleaned.dropFirst(Constants.CSV.bomPrefix.count))
        }
        
        // Remove surrounding quotes if present
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
            // Unescape double quotes
            cleaned = cleaned.replacingOccurrences(of: "\"\"", with: "\"")
        }
        
        return cleaned
    }
    
    private func escapeCSVField(_ field: String) -> String {
        // Check if field needs escaping
        let needsEscaping = field.contains(",") ||
                          field.contains("\"") ||
                          field.contains("\n") ||
                          field.contains("\r")
        
        if needsEscaping {
            // Escape quotes by doubling them
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        
        return field
    }
    
    private func adjustRow(_ row: [String], to columnCount: Int) -> [String] {
        if row.count == columnCount {
            return row
        } else if row.count < columnCount {
            // Pad with empty strings
            return row + Array(repeating: "", count: columnCount - row.count)
        } else {
            // Truncate
            return Array(row.prefix(columnCount))
        }
    }
    
    private func parseCSVStreaming(from url: URL) async throws -> CSVParseResult {
        // Implementation for streaming large CSV files
        // This is a simplified version - full implementation would use FileHandle
        
        let encoding = try detectEncoding(for: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        
        var headers: [String] = []
        var rows: [[String]] = []
        var warnings: [String] = []
        var lineNumber = 0
        var delimiter = ","
        var buffer = ""
        
        while true {
            let data = fileHandle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { break }
            
            guard let chunk = String(data: data, encoding: encoding) else {
                throw PhotoWorkflowError.csvEncodingError(encoding: "\(encoding)")
            }
            
            buffer += chunk
            
            // Process complete lines
            let lines = buffer.components(separatedBy: .newlines)
            
            // Keep last incomplete line in buffer
            if lines.count > 1 {
                buffer = lines.last ?? ""
                
                for line in lines.dropLast() {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        continue
                    }
                    
                    lineNumber += 1
                    
                    if lineNumber == 1 {
                        // First line is headers
                        delimiter = detectDelimiter(in: line)
                        headers = parseCSVLine(line, delimiter: delimiter)
                    } else {
                        // Parse data row
                        let row = parseCSVLine(line, delimiter: delimiter)
                        
                        if row.count != headers.count {
                            warnings.append("Line \(lineNumber): Expected \(headers.count) columns, found \(row.count)")
                        }
                        
                        rows.append(adjustRow(row, to: headers.count))
                        
                        // Limit memory usage for very large files
                        if rows.count > 100000 {
                            warnings.append("File truncated at 100,000 rows due to size limits")
                            break
                        }
                    }
                }
            }
            
            if rows.count > 100000 {
                break
            }
        }
        
        // Process any remaining data in buffer
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            lineNumber += 1
            if headers.isEmpty {
                headers = parseCSVLine(buffer, delimiter: delimiter)
            } else {
                let row = parseCSVLine(buffer, delimiter: delimiter)
                rows.append(adjustRow(row, to: headers.count))
            }
        }
        
        return CSVParseResult(
            headers: headers,
            rows: rows,
            encoding: encoding,
            delimiter: delimiter,
            lineCount: lineNumber,
            warnings: warnings
        )
    }
}
