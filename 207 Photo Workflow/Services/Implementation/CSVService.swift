import Foundation

// MARK: - CSV Service Implementation
class CSVService: CSVServiceProtocol {
    
    // MARK: - Properties
    private let maxFileSize: Int64 = 100_000_000 // 100MB limit
    private let maxColumns = 100
    private let chunkSize = 65536 // 64KB chunks for streaming
    
    // Common delimiters to try
    private let possibleDelimiters = [",", "\t", ";", "|", ":"]
    
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
        
        // Count occurrences of each delimiter
        var delimiterCounts: [String: [Int]] = [:]
        
        for delimiter in possibleDelimiters {
            delimiterCounts[delimiter] = sampleLines.map { line in
                line.components(separatedBy: delimiter).count - 1
            }
        }
        
        // Find delimiter with most consistent count across lines
        var bestDelimiter = ","
        var bestScore = 0.0
        
        for (delimiter, counts) in delimiterCounts {
            guard !counts.isEmpty, counts.max() ?? 0 > 0 else { continue }
            
            // Calculate consistency score (lower variance is better)
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            let variance = counts.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(counts.count)
            
            // Score based on mean count and consistency
            let score = mean / (variance + 1.0)
            
            if score > bestScore {
                bestScore = score
                bestDelimiter = delimiter
            }
        }
        
        return bestDelimiter
    }
    
    // MARK: - Private Methods
    
    private func parseCSVLine(_ line: String, delimiter: String) -> [String] {
        var result: [String] = []
        var currentField = ""
        var inQuotes = false
        var previousChar: Character?
        
        for char in line {
            if char == "\"" {
                if inQuotes {
                    // Check if this is an escaped quote
                    if previousChar == "\"" {
                        currentField.append(char)
                        previousChar = nil
                        continue
                    } else {
                        // Could be end of quoted field
                        previousChar = char
                        continue
                    }
                } else {
                    // Start of quoted field
                    inQuotes = true
                }
            } else if String(char) == delimiter && !inQuotes {
                // End of field
                result.append(cleanField(currentField))
                currentField = ""
                previousChar = nil
            } else {
                // Regular character
                if previousChar == "\"" && !inQuotes {
                    // The previous quote was closing quote
                    inQuotes = false
                }
                currentField.append(char)
                previousChar = char
            }
        }
        
        // Don't forget the last field
        if previousChar == "\"" {
            inQuotes = false
        }
        result.append(cleanField(currentField))
        
        return result
    }
    
    private func cleanField(_ field: String) -> String {
        var cleaned = field.trimmingCharacters(in: .whitespaces)
        
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
