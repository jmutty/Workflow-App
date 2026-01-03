import Foundation
import Combine

struct CSVBTemplateInfo: Hashable {
    let fileName: String
    let isMultiPose: Bool
    let mainPose: String?
    let secondPose: String?
}

struct CSVPhotoRecord: Hashable {
    let fileName: String
    let teamName: String
    let playerName: String
    let firstName: String
    let lastName: String
    let poseNumber: String
    let sourceURL: URL
    let isManual: Bool
}

@MainActor
class CreateSPACSVViewModel: ObservableObject {
    enum TemplateMode { case perTeam }

    // Config
    @Published var templateMode: TemplateMode = .perTeam
    @Published var includeSubfolders: Bool = false

    // State
    @Published var isAnalyzing: Bool = false
    @Published var isProcessing: Bool = false
    @Published var hasAnalyzedData: Bool = false
    @Published var templatesConfigured: Bool = false
    @Published var csvGenerated: Bool = false
    @Published var lastError: String?

    // Data
    @Published var regularPhotos: [CSVPhotoRecord] = []
    @Published var manualPhotos: [CSVPhotoRecord] = []
    @Published var detectedTeams: [String] = []
    @Published var totalPhotoCount: Int = 0
    @Published var generatedCSV: String = ""
    @Published var missingSecondPoseCount: Int = 0
    
    // Progress
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var filesCompleted: Int = 0
    @Published var totalFiles: Int = 0

    // Templates
    @Published var globalIndividualTemplates: [CSVBTemplateInfo] = []
    @Published var globalSportsMateTemplates: [CSVBTemplateInfo] = []
    @Published var teamTemplates: [String: (individual: [CSVBTemplateInfo], sportsMate: [CSVBTemplateInfo])] = [:]

    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    private let history: OperationHistoryProtocol
    
    // Undo support
    @Published var lastCSVOperationId: UUID?

    init(jobFolder: URL, fileManager: FileManagerProtocol = FileManager.default, history: OperationHistoryProtocol? = nil) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
        self.history = history ?? OperationHistory(fileManager: fileManager)
    }
    
    // Expose job root URL for views that need to scan template files
    func jobRootURL() -> URL { jobFolder }
    // MARK: - Preflight for Multi-Pose Templates
    struct MultiPoseIssue: Identifiable {
        let id = UUID()
        let teamName: String
        let playerName: String
        let requiredPose: String
        let templateFile: String
    }
    
    @Published var preflightIssues: [MultiPoseIssue] = []
    
    func runPreflight() {
        guard hasAnalyzedData else { preflightIssues = []; return }
        let map = buildPlayerPoseMap()
        var issues: [MultiPoseIssue] = []
        // Per-team only: ensure each team's multi-pose templates have required second poses
        for team in detectedTeams {
            guard let cfg = teamTemplates[team] else { continue }
            let multiTemplates = cfg.individual.filter { $0.isMultiPose }
            if multiTemplates.isEmpty { continue }
            let teamPhotos = regularPhotos.filter { $0.teamName == team }
            for rec in teamPhotos {
                for tmpl in multiTemplates {
                    if let second = tmpl.secondPose {
                        let key = "\(rec.teamName)_\(rec.playerName)"
                        if map[key]?[second] == nil {
                            issues.append(MultiPoseIssue(teamName: rec.teamName, playerName: rec.playerName, requiredPose: second, templateFile: tmpl.fileName))
                        }
                    }
                }
            }
        }
        preflightIssues = dedupeIssues(issues)
    }
    
    private func dedupeIssues(_ arr: [MultiPoseIssue]) -> [MultiPoseIssue] {
        var seen = Set<String>()
        var out: [MultiPoseIssue] = []
        for i in arr {
            let key = "\(i.teamName)|\(i.playerName)|\(i.requiredPose)|\(i.templateFile)"
            if !seen.contains(key) {
                seen.insert(key)
                out.append(i)
            }
        }
        return out.sorted { a, b in
            if a.teamName != b.teamName { return a.teamName < b.teamName }
            if a.playerName != b.playerName { return a.playerName < b.playerName }
            return (Int(a.requiredPose) ?? 0) < (Int(b.requiredPose) ?? 0)
        }
    }


    func existingCSVURL() -> URL {
        jobFolder.appendingPathComponent(Constants.CSV.spaReadyFileName)
    }

    func loadExistingCSVIfPresent() {
        let url = existingCSVURL()
        if FileManager.default.fileExists(atPath: url.path) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                generatedCSV = content
                csvGenerated = true
            }
        }
        
        // Also check for existing CSV backups to restore undo capability
        checkForExistingCSVBackups()
    }
    
    private func checkForExistingCSVBackups() {
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        guard FileManager.default.fileExists(atPath: backupsRoot.path, isDirectory: nil) else { return }
        
        do {
            let backupFiles = try FileManager.default.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: [.creationDateKey], options: [])
            let csvBackups = backupFiles.filter { $0.lastPathComponent.hasPrefix("SPA_Ready_backup_") && $0.pathExtension == "csv" }
            
            // Find the most recent CSV backup
            guard let latestBackup = csvBackups.max(by: { (url1, url2) in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }) else { return }
            
            print("📋 Found existing CSV backup: \(latestBackup.lastPathComponent)")
            
            // Check if current CSV exists and differs from backup (indicating a save operation occurred)
            let currentCSVURL = existingCSVURL()
            if FileManager.default.fileExists(atPath: currentCSVURL.path) {
                // Restore undo capability
                restoreCSVUndoCapabilityFromBackup(latestBackup, currentCSV: currentCSVURL)
                print("📋 ✅ Restored CSV undo capability from existing backup")
            }
            
        } catch {
            print("📋 Error checking for existing CSV backups: \(error.localizedDescription)")
        }
    }
    
    private func restoreCSVUndoCapabilityFromBackup(_ backupURL: URL, currentCSV: URL) {
        // Create a synthetic operation record for CSV undo capability
        let operationId = UUID()
        let changes = [OperationHistory.FileChange(originalURL: backupURL, newURL: currentCSV, mode: .move)]
        let record = OperationHistory.OperationRecord(
            id: operationId,
            type: .createSPACSV,
            timestamp: Date(),
            affectedFiles: changes,
            reversible: true,
            backupFolder: backupURL.deletingLastPathComponent()
        )
        
        history.record(record)
        lastCSVOperationId = operationId
    }

    func deleteExistingCSV() -> Bool {
        let url = existingCSVURL()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            // Reset state so user can start fresh
            generatedCSV = ""
            csvGenerated = false
            return true
        } catch {
            lastError = "Failed to delete existing CSV: \(error.localizedDescription)"
            return false
        }
    }

    func analyzePhotos() async {
        isAnalyzing = true
        lastError = nil
        regularPhotos = []
        manualPhotos = []
        detectedTeams = []
        totalPhotoCount = 0
        hasAnalyzedData = false
        missingSecondPoseCount = 0
        operationProgress = 0
        currentOperation = "Analyzing photos..."
        filesCompleted = 0
        totalFiles = 0
        defer { isAnalyzing = false }

        let extractedURL = jobFolder.appendingPathComponent("Extracted")
        do {
            let urls: [URL]
            if includeSubfolders {
                var all: [URL] = []
                if let en = FileManager.default.enumerator(at: extractedURL, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                    while let next = en.nextObject() as? URL { all.append(next) }
                }
                urls = all
            } else {
                urls = try fileManager.contentsOfDirectory(at: extractedURL, includingPropertiesForKeys: [.contentTypeKey], options: [])
            }

            var imageFiles = urls.filter { Constants.FileExtensions.isImageFile($0) }
            // Also include files inside Buddy Photos subfolder
            let buddyDir = extractedURL.appendingPathComponent(Constants.Folders.buddyPhotos)
            if FileManager.default.fileExists(atPath: buddyDir.path) {
                if let en = FileManager.default.enumerator(at: buddyDir, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                    while let next = en.nextObject() as? URL {
                        if Constants.FileExtensions.isImageFile(next) { imageFiles.append(next) }
                    }
                }
            }
            totalFiles = imageFiles.count
            var teams = Set<String>()
            var regular: [CSVPhotoRecord] = []
            var manual: [CSVPhotoRecord] = []

            for (i, url) in imageFiles.enumerated() {
                let fileName = url.lastPathComponent
                if let p = parse(fileName) {
                    if p.isCoach || p.isGroup || p.isTeamPhoto { continue }
                    // Buddy photos: treat as individual rows by team name only
                    if isBuddyPhoto(fileName) {
                        let team = p.team
                        let rec = CSVPhotoRecord(fileName: fileName, teamName: team, playerName: "", firstName: "", lastName: "", poseNumber: "", sourceURL: url, isManual: true)
                        manual.append(rec)
                        teams.insert(team)
                        continue
                    }
                    // Manager photos: include as manual rows keyed by team (blank names)
                    if p.isManager {
                        let team = p.team
                        let rec = CSVPhotoRecord(fileName: fileName, teamName: team, playerName: "", firstName: "", lastName: "", poseNumber: "", sourceURL: url, isManual: true)
                        manual.append(rec)
                        teams.insert(team)
                        continue
                    }
                    if p.playerName.isEmpty || p.pose.isEmpty {
                        // Preserve team for partially parsed files so manual rows can use per-team templates
                        manual.append(CSVPhotoRecord(fileName: fileName, teamName: p.team, playerName: "", firstName: "", lastName: "", poseNumber: "", sourceURL: url, isManual: true))
                        continue
                    }
                    let nameParts = p.playerName.split(separator: " ")
                    let first = nameParts.first.map(String.init) ?? ""
                    let last = nameParts.dropFirst().joined(separator: " ")
                    regular.append(CSVPhotoRecord(fileName: fileName, teamName: p.team, playerName: p.playerName, firstName: first, lastName: last, poseNumber: p.pose, sourceURL: url, isManual: false))
                    teams.insert(p.team)
                } else {
                    manual.append(CSVPhotoRecord(fileName: fileName, teamName: "MANUAL", playerName: "", firstName: "", lastName: "", poseNumber: "", sourceURL: url, isManual: true))
                }
                filesCompleted = i + 1
                operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
                currentOperation = fileName
            }
            regularPhotos = regular.sorted { $0.teamName < $1.teamName }
            manualPhotos = manual.sorted { $0.fileName < $1.fileName }
            detectedTeams = Array(teams).sorted()
            totalPhotoCount = regular.count + manual.count
            hasAnalyzedData = true
            currentOperation = ""
        } catch {
            lastError = "Error analyzing photos: \(error.localizedDescription)"
        }
    }

    func applyTemplateConfiguration() {
        templatesConfigured = hasValidTemplateConfiguration
    }

    var hasValidTemplateConfiguration: Bool {
        return !detectedTeams.isEmpty && detectedTeams.allSatisfy { team in
            if let cfg = teamTemplates[team] { return !cfg.individual.isEmpty || !cfg.sportsMate.isEmpty }
            return false
        }
    }

    func generateCSV() async {
        isProcessing = true
        defer { isProcessing = false }
        missingSecondPoseCount = 0
        operationProgress = 0
        filesCompleted = 0
        currentOperation = "Generating CSV..."
        let headerLine = Constants.CSV.header
        let headers = headerLine.split(separator: ",").map { String($0) }
        totalFiles = regularPhotos.count + manualPhotos.count
        
        let progressCallback: (String) -> Void = { hint in
            self.filesCompleted += 1
            self.currentOperation = hint
            self.operationProgress = self.totalFiles > 0 ? Double(self.filesCompleted) / Double(self.totalFiles) : 0
        }
        
        var missingSecond = 0
        let rows = CSVBuildEngine.buildRows(
            input: CSVBuildEngine.Input(
                headers: headers,
                templateMode: templateMode,
                detectedTeams: detectedTeams,
                regularPhotos: regularPhotos,
                manualPhotos: manualPhotos,
                teamTemplates: teamTemplates,
                globalIndividualTemplates: globalIndividualTemplates,
                globalSportsMateTemplates: globalSportsMateTemplates,
                includeTeams: nil,
                includeManualWithoutTeam: true,
                progressCallback: progressCallback
            ),
            missingSecondPoseCount: &missingSecond
        )
        missingSecondPoseCount = missingSecond
        
        var content = Constants.CSV.bomPrefix
        for r in rows {
            let line = r.map { escape($0) }.joined(separator: ",")
            content += line + "\n"
        }
        generatedCSV = content
        csvGenerated = true
        currentOperation = ""
    }

    func saveCSV() async -> Bool {
        guard !generatedCSV.isEmpty else { lastError = "No CSV content to save"; return false }
        do {
            let fm = FileManager.default
            let forUpload = jobFolder.appendingPathComponent("For Upload")
            let csvURL = jobFolder.appendingPathComponent(Constants.CSV.spaReadyFileName)
            
            // Track if CSV file already exists for undo purposes
            let existingCSV = fm.fileExists(atPath: csvURL.path)
            var backupURL: URL?
            
            // Create backup of existing CSV if it exists
            if existingCSV {
                let backupsRoot = jobFolder.appendingPathComponent("Backups")
                if !fm.fileExists(atPath: backupsRoot.path, isDirectory: nil) {
                    try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true, attributes: nil)
                }
                let timestamp = Int(Date().timeIntervalSince1970)
                backupURL = backupsRoot.appendingPathComponent("SPA_Ready_backup_\(timestamp).csv")
                try fm.copyItem(at: csvURL, to: backupURL!)
            }
            
            // Create For Upload folder structure
            if !fm.fileExists(atPath: forUpload.path) {
                try fm.createDirectory(at: forUpload, withIntermediateDirectories: true)
            }
            for team in detectedTeams {
                let teamFolder = forUpload.appendingPathComponent(team)
                if !fm.fileExists(atPath: teamFolder.path) {
                    try fm.createDirectory(at: teamFolder, withIntermediateDirectories: true)
                }
            }
            
            // Save the new CSV
            try generatedCSV.write(to: csvURL, atomically: true, encoding: .utf8)
            
            // Record operation for undo
            let operationId = UUID()
            let changes = [OperationHistory.FileChange(originalURL: backupURL ?? csvURL, newURL: csvURL, mode: .move)]
            let record = OperationHistory.OperationRecord(
                id: operationId,
                type: .createSPACSV,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: backupURL != nil, // Only reversible if we have a backup
                backupFolder: backupURL?.deletingLastPathComponent()
            )
            history.record(record)
            lastCSVOperationId = operationId
            
            return true
        } catch {
            lastError = "Failed to save CSV: \(error.localizedDescription)"
            return false
        }
    }
    
    func undoLastCSVOperation() async {
        guard let operationId = lastCSVOperationId else { 
            lastError = "No CSV operation to undo"
            return 
        }
        
        do {
            try await history.undo(operationId: operationId)
            lastCSVOperationId = nil
            
            // Reload the CSV content if it exists
            loadExistingCSVIfPresent()
            
            // If no CSV exists after undo, reset state
            if !csvGenerated {
                generatedCSV = ""
            }
            
        } catch {
            lastError = "Failed to undo CSV operation: \(error.localizedDescription)"
        }
    }

    private func buildPlayerPoseMap() -> [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for p in regularPhotos {
            let key = normalizedKey(team: p.teamName, player: p.playerName)
            if map[key] == nil { map[key] = [:] }
            let sp = sanitizePose(p.poseNumber)
            map[key]?[p.poseNumber] = p.fileName
            map[key]?[sp] = p.fileName
        }
        return map
    }

    private func sanitizePose(_ pose: String) -> String {
        // Trim spaces and drop leading zeros to normalize comparisons (e.g., "02" -> "2")
        let trimmed = pose.trimmingCharacters(in: .whitespacesAndNewlines)
        let noLeadingZeros = trimmed.drop { $0 == "0" }
        return noLeadingZeros.isEmpty ? "0" : String(noLeadingZeros)
    }

    private func normalizedKey(team: String, player: String) -> String {
        func norm(_ s: String) -> String {
            let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.precomposedStringWithCanonicalMapping
        }
        return "\(norm(team))_\(norm(player))"
    }

    private func parse(_ fileName: String) -> (team: String, playerName: String, pose: String, isCoach: Bool, isManager: Bool, isGroup: Bool, isTeamPhoto: Bool)? {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let tokens = Set(parts.map { $0.uppercased() })
        let isCoach = tokens.contains("COACH")
        let isManager = tokens.contains("MANAGER")
        let isGroup = tokens.contains("GROUP")
        let isTeam = tokens.contains("TEAM")
        let team = parts[0]
        if isTeam { return (team, "", "", false, false, false, true) }
        if isCoach { return (team, "", "", true, false, false, false) }
        if isManager { return (team, "", "", false, true, false, false) }
        if isGroup { return (team, "", "", false, false, true, false) }
        guard let last = parts.last, Int(last) != nil else { return nil }
        let pose = String(last)
        let player = parts.dropFirst().dropLast().joined(separator: " ")
        return (team, player, pose, false, false, false, false)
    }

    private func isBuddyPhoto(_ fileName: String) -> Bool {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return false }
        let token = parts[1]
        if token.hasPrefix("Buddy") {
            let suffix = token.dropFirst("Buddy".count)
            return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
        }
        return false
    }

    private func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}


