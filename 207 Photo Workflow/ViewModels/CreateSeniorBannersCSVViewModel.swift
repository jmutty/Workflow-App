import Foundation

struct SeniorBannerOrderRecord: Identifiable, Hashable {
    let id = UUID()
    let originalFileName: String
    let pngFileName: String
    let teamName: String
    let album: String
    let firstName: String
    let lastName: String
    let gradYear: String
    
    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class CreateSeniorBannersCSVViewModel: ObservableObject {
    // Input
    @Published var pastedOrderData: String = ""
    
    // Output / state
    @Published var records: [SeniorBannerOrderRecord] = []
    @Published var generatedCSV: String = ""
    @Published var lastError: String?
    @Published var missingPNGs: [String] = []
    
    // Template selection (per Team)
    @Published var templateByTeam: [String: CSVBTemplateInfo] = [:]
    
    // Progress
    @Published var isProcessing: Bool = false
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var filesCompleted: Int = 0
    @Published var totalFiles: Int = 0
    
    // Completion flags
    @Published var hasParsed: Bool = false
    @Published var didCopyPNGs: Bool = false
    @Published var csvGenerated: Bool = false
    
    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    
    init(jobFolder: URL, fileManager: FileManagerProtocol = FileManager.default) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
    }
    
    func existingCSVURL() -> URL {
        jobFolder.appendingPathComponent(Constants.CSV.seniorBannersFileName)
    }
    
    func parseOrderData() {
        lastError = nil
        generatedCSV = ""
        csvGenerated = false
        didCopyPNGs = false
        missingPNGs = []
        templateByTeam = [:]
        records = []
        hasParsed = false
        
        let rawLines = pastedOrderData
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        func isFilenameLine(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
        }
        
        func normalizeToPNG(_ fileName: String) -> String {
            let base = (fileName as NSString).deletingPathExtension
            return base + ".png"
        }

        func teamFromFileName(_ fileName: String) -> String {
            let base = (fileName as NSString).deletingPathExtension
            let parts = base.split(separator: "_", maxSplits: 1).map(String.init)
            return (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        struct Working {
            var originalFileName: String = ""
            var album: String = ""
            var firstName: String = ""
            var lastName: String = ""
            var gradYear: String = ""
        }
        
        var current: Working? = nil
        var out: [SeniorBannerOrderRecord] = []
        var i = 0
        
        func finalizeIfPossible(_ w: Working) -> String? {
            let missing: [String] = [
                w.originalFileName.isEmpty ? "filename" : nil,
                w.album.isEmpty ? "album" : nil,
                w.firstName.isEmpty ? "first name" : nil,
                w.lastName.isEmpty ? "last name" : nil,
                w.gradYear.isEmpty ? "grad year" : nil
            ].compactMap { $0 }
            if !missing.isEmpty {
                return "Incomplete subject (\(missing.joined(separator: ", "))). Last filename: \(w.originalFileName.isEmpty ? "(none)" : w.originalFileName)"
            }
            out.append(SeniorBannerOrderRecord(
                originalFileName: w.originalFileName,
                pngFileName: normalizeToPNG(w.originalFileName),
                teamName: teamFromFileName(w.originalFileName),
                album: w.album,
                firstName: w.firstName,
                lastName: w.lastName,
                gradYear: w.gradYear
            ))
            return nil
        }
        
        while i < rawLines.count {
            let line = rawLines[i]
            
            if isFilenameLine(line) {
                // If same filename repeats twice, ignore duplicate.
                if current?.originalFileName == line {
                    i += 1
                    continue
                }
                
                // If we encounter a new filename before finishing the previous record, keep going,
                // but remember we might need to warn later if it's incomplete.
                if current == nil {
                    current = Working(originalFileName: line)
                } else if current?.originalFileName.isEmpty ?? true {
                    current?.originalFileName = line
                } else {
                    // Start a new subject; keep the old one around as-is for now (will error if incomplete).
                    if let old = current {
                        if let err = finalizeIfPossible(old) {
                            lastError = err
                        }
                    }
                    current = Working(originalFileName: line)
                }
                
                i += 1
                continue
            }
            
            if line == "Album" {
                if i + 1 < rawLines.count {
                    current?.album = rawLines[i + 1]
                    i += 2
                    continue
                }
            }
            
            if line == "FIRST NAME::" {
                if i + 1 < rawLines.count {
                    current?.firstName = rawLines[i + 1]
                    i += 2
                    continue
                }
            }
            
            if line == "LAST NAME::" {
                if i + 1 < rawLines.count {
                    current?.lastName = rawLines[i + 1]
                    i += 2
                    continue
                }
            }
            
            if line == "YEAR OF GRADUATION::" {
                if i + 1 < rawLines.count {
                    current?.gradYear = rawLines[i + 1]
                    if let done = current {
                        if let err = finalizeIfPossible(done) {
                            lastError = err
                        }
                    }
                    current = nil
                    i += 2
                    continue
                }
            }
            
            i += 1
        }
        
        // If paste ended without a final YEAR marker, attempt to finalize and flag error if incomplete.
        if let tail = current {
            if let err = finalizeIfPossible(tail) {
                lastError = err
            }
        }
        
        // Deduplicate by png filename (keep first)
        var seen = Set<String>()
        let deduped = out.filter { rec in
            let key = rec.pngFileName.lowercased()
            return seen.insert(key).inserted
        }
        
        records = deduped
        hasParsed = !deduped.isEmpty
        
        if records.isEmpty {
            lastError = lastError ?? "No subjects found. Make sure the paste includes filenames and YEAR OF GRADUATION:: blocks."
        }
    }
    
    func generateCSV() {
        lastError = nil
        csvGenerated = false
        generatedCSV = ""
        
        guard hasParsed, !records.isEmpty else {
            lastError = "Nothing parsed yet. Paste order data and click Parse."
            return
        }
        
        // Ensure each team has a template selected
        let teams = Array(Set(records.map { $0.teamName })).sorted()
        let missingTemplates = teams.filter { (templateByTeam[$0]?.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !missingTemplates.isEmpty {
            lastError = "Select a template for each team before generating CSV. Missing: \(missingTemplates.joined(separator: ", "))"
            return
        }
        
        let headerLine = Constants.CSV.header
        let headers = headerLine.split(separator: ",").map { String($0) }
        
        var idx: [String: Int] = [:]
        for (i, h) in headers.enumerated() { idx[h] = i }
        
        func escape(_ field: String) -> String {
            if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        
        var rows: [[String]] = []
        rows.append(headers)
        
        func sanitizePose(_ pose: String) -> String {
            let trimmed = pose.trimmingCharacters(in: .whitespacesAndNewlines)
            let noLeadingZeros = trimmed.drop { $0 == "0" }
            return noLeadingZeros.isEmpty ? "0" : String(noLeadingZeros)
        }
        
        func deriveSecondPoseFileName(primaryPNG: String, secondPose: String) -> String? {
            let name = (primaryPNG as NSString).deletingPathExtension
            let ext = (primaryPNG as NSString).pathExtension
            let parts = name.split(separator: "_").map(String.init)
            guard parts.count >= 2 else { return nil }
            guard let last = parts.last, Int(last) != nil else { return nil }
            let base = parts.dropLast().joined(separator: "_")
            let p2 = sanitizePose(secondPose)
            return "\(base)_\(p2).\(ext)"
        }
        
        for r in records {
            var fields = Array(repeating: "", count: headers.count)
            fields[idx["SPA"] ?? 0] = r.pngFileName
            fields[idx["NAME"] ?? 0] = r.fullName
            fields[idx["FIRSTNAME"] ?? 0] = r.firstName
            fields[idx["LASTNAME"] ?? 0] = r.lastName
            fields[idx["TEAMNAME"] ?? 0] = r.teamName
            fields[idx["YEAR"] ?? 0] = r.gradYear
            let tmpl = templateByTeam[r.teamName]
            fields[idx["TEMPLATE FILE"] ?? 0] = tmpl?.fileName ?? ""
            
            if let tmpl = tmpl, tmpl.isMultiPose, let second = tmpl.secondPose, !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let p2 = deriveSecondPoseFileName(primaryPNG: r.pngFileName, secondPose: second) {
                    // Avoid setting if it resolves to the same file
                    if p2.lowercased() != r.pngFileName.lowercased() {
                        fields[idx["PLAYER 2 FILE"] ?? 0] = p2
                    }
                } else {
                    lastError = "Template \(tmpl.fileName) requires a second pose, but filename doesn’t end with _<pose>. File: \(r.pngFileName)"
                    return
                }
            }
            rows.append(fields)
        }
        
        var content = Constants.CSV.bomPrefix
        for row in rows {
            content += row.map { escape($0) }.joined(separator: ",") + "\n"
        }
        generatedCSV = content
        csvGenerated = true
    }
    
    func findMissingPNGs() {
        missingPNGs = []
        guard hasParsed else { return }
        let extractedURL = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        let needed = requiredPNGFileNames()
        let missing = needed.filter { name in
            !FileManager.default.fileExists(atPath: extractedURL.appendingPathComponent(name).path)
        }
        missingPNGs = missing.sorted()
    }
    
    func copyPNGsToTimestampedFolder() async -> Bool {
        lastError = nil
        didCopyPNGs = false
        isProcessing = true
        operationProgress = 0
        filesCompleted = 0
        let needed = requiredPNGFileNames()
        totalFiles = needed.count
        currentOperation = "Checking for missing PNGs..."
        defer {
            isProcessing = false
            currentOperation = ""
        }
        
        guard hasParsed, !records.isEmpty else {
            lastError = "Nothing parsed yet."
            return false
        }
        
        findMissingPNGs()
        if !missingPNGs.isEmpty {
            lastError = "Missing \(missingPNGs.count) PNG(s) in Extracted. Fix missing files and try again."
            return false
        }
        
        let extractedURL = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        let root = jobFolder.appendingPathComponent(Constants.Folders.seniorBanners)
        
        func timestampString(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            // macOS file/folder names can't contain ":" so we use "h-mm a" instead of "h:mm a"
            // Example: "2025-12-14 1-23 PM"
            f.dateFormat = "yyyy-MM-dd h-mm a"
            return f.string(from: date)
        }
        
        let runFolder = root.appendingPathComponent(timestampString(Date()))
        
        do {
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: nil) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
            
            for (i, fileName) in needed.enumerated() {
                let src = extractedURL.appendingPathComponent(fileName)
                currentOperation = fileName
                
                let dest = uniqueDestinationURL(in: runFolder, fileName: fileName)
                try FileManager.default.copyItem(at: src, to: dest)
                
                filesCompleted = i + 1
                operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
            }
            
            didCopyPNGs = true
            return true
            
        } catch {
            lastError = "Copy failed: \(error.localizedDescription)"
            return false
        }
    }
    
    func saveCSVToJobRoot() async -> Bool {
        lastError = nil
        guard csvGenerated, !generatedCSV.isEmpty else {
            lastError = "No CSV generated yet."
            return false
        }
        
        do {
            try generatedCSV.write(to: existingCSVURL(), atomically: true, encoding: .utf8)
            return true
        } catch {
            lastError = "Failed to save CSV: \(error.localizedDescription)"
            return false
        }
    }
    
    private func uniqueDestinationURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var n = 2
        while true {
            let next = "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
    
    private func requiredPNGFileNames() -> [String] {
        var set = Set<String>()
        for r in records {
            set.insert(r.pngFileName)
            if let tmpl = templateByTeam[r.teamName], tmpl.isMultiPose, let second = tmpl.secondPose, !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let p2 = deriveSecondPoseFileNameForCopy(primaryPNG: r.pngFileName, secondPose: second) {
                    if p2.lowercased() != r.pngFileName.lowercased() {
                        set.insert(p2)
                    }
                }
            }
        }
        return Array(set).sorted()
    }
    
    private func deriveSecondPoseFileNameForCopy(primaryPNG: String, secondPose: String) -> String? {
        let name = (primaryPNG as NSString).deletingPathExtension
        let ext = (primaryPNG as NSString).pathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        guard let last = parts.last, Int(last) != nil else { return nil }
        let base = parts.dropLast().joined(separator: "_")
        let trimmed = secondPose.trimmingCharacters(in: .whitespacesAndNewlines)
        let noLeadingZeros = trimmed.drop { $0 == "0" }
        let p2 = noLeadingZeros.isEmpty ? "0" : String(noLeadingZeros)
        return "\(base)_\(p2).\(ext)"
    }
}


