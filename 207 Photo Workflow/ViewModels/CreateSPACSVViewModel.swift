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
    enum TemplateMode { case sameForAll, perTeam }

    // Config
    @Published var templateMode: TemplateMode = .sameForAll
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

    init(jobFolder: URL, fileManager: FileManagerProtocol = FileManager.default) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
    }
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
        switch templateMode {
        case .sameForAll:
            let multiTemplates = globalIndividualTemplates.filter { $0.isMultiPose }
            guard !multiTemplates.isEmpty else { preflightIssues = []; return }
            for rec in regularPhotos {
                for tmpl in multiTemplates {
                    if let second = tmpl.secondPose {
                        let key = "\(rec.teamName)_\(rec.playerName)"
                        if map[key]?[second] == nil {
                            issues.append(MultiPoseIssue(teamName: rec.teamName, playerName: rec.playerName, requiredPose: second, templateFile: tmpl.fileName))
                        }
                    }
                }
            }
        case .perTeam:
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
                    for case let u as URL in en { all.append(u) }
                }
                urls = all
            } else {
                urls = try fileManager.contentsOfDirectory(at: extractedURL, includingPropertiesForKeys: [.contentTypeKey], options: [])
            }

            let imageFiles = urls.filter { Constants.FileExtensions.isImageFile($0) }
            totalFiles = imageFiles.count
            var teams = Set<String>()
            var regular: [CSVPhotoRecord] = []
            var manual: [CSVPhotoRecord] = []

            for (i, url) in imageFiles.enumerated() {
                let fileName = url.lastPathComponent
                if let p = parse(fileName) {
                    if p.isCoach || p.isGroup || p.isTeamPhoto { continue }
                    if p.playerName.isEmpty || p.pose.isEmpty {
                        manual.append(CSVPhotoRecord(fileName: fileName, teamName: "MANUAL", playerName: "", firstName: "", lastName: "", poseNumber: "", sourceURL: url, isManual: true))
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
        switch templateMode {
        case .sameForAll:
            return !globalIndividualTemplates.isEmpty || !globalSportsMateTemplates.isEmpty
        case .perTeam:
            return !detectedTeams.isEmpty && detectedTeams.allSatisfy { team in
                if let cfg = teamTemplates[team] { return !cfg.individual.isEmpty || !cfg.sportsMate.isEmpty }
                return false
            }
        }
    }

    func generateCSV() async {
        isProcessing = true
        defer { isProcessing = false }
        missingSecondPoseCount = 0
        operationProgress = 0
        filesCompleted = 0
        totalFiles = 0
        currentOperation = "Generating CSV..."

        let headerLine = Constants.CSV.header
        let headers = headerLine.split(separator: ",").map { String($0) }
        var idx: [String: Int] = [:]
        for (i, h) in headers.enumerated() { idx[h] = i }
        var rows: [[String]] = [headers]
        let playerPoseMap = buildPlayerPoseMap()

        func addRow(for photo: CSVPhotoRecord, template: CSVBTemplateInfo, appendSuffix: String) {
            var fields = Array(repeating: "", count: headers.count)
            fields[idx["SPA"] ?? 0] = photo.fileName
            if photo.isManual {
                fields[idx["NAME"] ?? 0] = "***NEEDS_NAME***"
                fields[idx["FIRSTNAME"] ?? 0] = "***CHANGE***"
                fields[idx["LASTNAME"] ?? 0] = "***CHANGE***"
                fields[idx["TEAMNAME"] ?? 0] = "***ASSIGN_TEAM***"
            } else {
                fields[idx["NAME"] ?? 0] = photo.playerName
                fields[idx["FIRSTNAME"] ?? 0] = photo.firstName
                fields[idx["LASTNAME"] ?? 0] = photo.lastName
                fields[idx["TEAMNAME"] ?? 0] = photo.teamName
            }
            fields[idx["APPEND FILE NAME"] ?? 0] = appendSuffix
            fields[idx["SUB FOLDER"] ?? 0] = photo.isManual ? "***ASSIGN_TEAM***" : photo.teamName
            fields[idx["TEAM FILE"] ?? 0] = photo.isManual ? "***ASSIGN_TEAM***.jpg" : "\(photo.teamName).jpg"
            fields[idx["TEMPLATE FILE"] ?? 0] = template.fileName

            if let secondPose = template.secondPose, !secondPose.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = normalizedKey(team: photo.teamName, player: photo.playerName)
                let sp = sanitizePose(secondPose)
                let secondFile = playerPoseMap[key]?[sp] ?? playerPoseMap[key]?[secondPose]
                if let second = secondFile, second != photo.fileName {
                    fields[idx["PLAYER 2 FILE"] ?? 0] = second
                } else if secondFile == nil {
                    fields[idx["PLAYER 2 FILE"] ?? 0] = "***MISSING_SECOND_POSE***"
                    missingSecondPoseCount += 1
                }
            }
            rows.append(fields)
        }

        // Sort photos by team, player, pose number (ascending) for grouping
        let sortedRegular = regularPhotos.sorted { a, b in
            if a.teamName != b.teamName { return a.teamName < b.teamName }
            if a.playerName != b.playerName { return a.playerName < b.playerName }
            let ap = Int(a.poseNumber) ?? 0
            let bp = Int(b.poseNumber) ?? 0
            return ap < bp
        }

        func incrementProgress(_ hint: String) {
            filesCompleted += 1
            currentOperation = hint
            operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
        }
        
        let regularCount = regularPhotos.count
        let manualCount = manualPhotos.count
        switch templateMode {
        case .sameForAll:
            totalFiles = (globalIndividualTemplates.count * (regularCount + manualCount)) + (globalSportsMateTemplates.count * (regularCount + manualCount))
            for template in globalIndividualTemplates {
                for p in sortedRegular {
                    if let sp = template.secondPose, !sp.trimmingCharacters(in: .whitespaces).isEmpty,
                       sanitizePose(p.poseNumber) == sanitizePose(sp) {
                        // Skip the secondary pose row in SPA column
                        continue
                    }
                    addRow(for: p, template: template, appendSuffix: ""); incrementProgress(p.fileName)
                }
                for p in manualPhotos { addRow(for: p, template: template, appendSuffix: ""); incrementProgress(p.fileName) }
            }
            // spacer row
            rows.append(Array(repeating: "", count: headers.count))
            for template in globalSportsMateTemplates {
                for p in sortedRegular { addRow(for: p, template: template, appendSuffix: "_MM"); incrementProgress(p.fileName) }
                for p in manualPhotos { addRow(for: p, template: template, appendSuffix: "_MM"); incrementProgress(p.fileName) }
            }
        case .perTeam:
            for team in detectedTeams {
                if let cfg = teamTemplates[team] {
                    for template in cfg.individual {
                        let teamPhotos = sortedRegular.filter { $0.teamName == team }
                        for p in teamPhotos {
                            if let sp = template.secondPose, !sp.trimmingCharacters(in: .whitespaces).isEmpty,
                               sanitizePose(p.poseNumber) == sanitizePose(sp) {
                                continue
                            }
                            addRow(for: p, template: template, appendSuffix: ""); incrementProgress(p.fileName)
                        }
                    }
                    // spacer
                    rows.append(Array(repeating: "", count: headers.count))
                    for template in cfg.sportsMate {
                        let teamPhotos = sortedRegular.filter { $0.teamName == team }
                        for p in teamPhotos { addRow(for: p, template: template, appendSuffix: "_MM"); incrementProgress(p.fileName) }
                    }
                }
            }
            if !manualPhotos.isEmpty && !globalIndividualTemplates.isEmpty {
                for template in globalIndividualTemplates { for p in manualPhotos { addRow(for: p, template: template, appendSuffix: ""); incrementProgress(p.fileName) } }
            }
        }

        // Convert to CSV string with BOM, ensuring unique lines
        var content = Constants.CSV.bomPrefix
        var seen = Set<String>()
        for r in rows {
            let line = r.map { escape($0) }.joined(separator: ",")
            if seen.insert(line).inserted {
                content += line + "\n"
            }
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
            if !fm.fileExists(atPath: forUpload.path) {
                try fm.createDirectory(at: forUpload, withIntermediateDirectories: true)
            }
            for team in detectedTeams {
                let teamFolder = forUpload.appendingPathComponent(team)
                if !fm.fileExists(atPath: teamFolder.path) {
                    try fm.createDirectory(at: teamFolder, withIntermediateDirectories: true)
                }
            }
            let csvURL = jobFolder.appendingPathComponent(Constants.CSV.spaReadyFileName)
            try generatedCSV.write(to: csvURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            lastError = "Failed to save CSV: \(error.localizedDescription)"
            return false
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

    private func parse(_ fileName: String) -> (team: String, playerName: String, pose: String, isCoach: Bool, isGroup: Bool, isTeamPhoto: Bool)? {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let tokens = Set(parts.map { $0.uppercased() })
        let isCoach = tokens.contains("COACH")
        let isGroup = tokens.contains("GROUP")
        let isTeam = tokens.contains("TEAM")
        let team = parts[0]
        if isTeam { return (team, "", "", false, false, true) }
        if isCoach { return (team, "", "", true, false, false) }
        if isGroup { return (team, "", "", false, true, false) }
        guard let last = parts.last, Int(last) != nil else { return nil }
        let pose = String(last)
        let player = parts.dropFirst().dropLast().joined(separator: " ")
        return (team, player, pose, false, false, false)
    }

    private func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}


