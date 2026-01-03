import Foundation

struct RebuildResult {
    let csvURL: URL
    let remakeRoot: URL
    let teamsProcessed: [String]
    let filesCopied: Int
    let filesMoved: Int
    let csvRowCount: Int
    let teamPhotosReplaced: Int
}

// Helper structure to hold representative CSV rows from the original CSV per team and type
private struct TeamCSVTemplateSet {
    var individualRows: [[String]] = []
    var smRows: [[String]] = []
}

class RebuildService {
    
    private let fileManager: FileManagerProtocol
    private let csvService: CSVServiceProtocol
    private let history: OperationHistoryProtocol?
    
    init(fileManager: FileManagerProtocol = FileManager.default,
         csvService: CSVServiceProtocol = CSVService(),
         history: OperationHistoryProtocol? = nil) {
        self.fileManager = fileManager
        self.csvService = csvService
        self.history = history
    }
    
    // MARK: - Public API
    
    func buildFullTeams(jobFolder: URL,
                        teams: [String],
                        source: URL?) async throws -> RebuildResult {
        // 1) Prepare timestamped remake root
        let (timestamp, remakeRoot) = try prepareRemakeRoot(jobFolder: jobFolder)
        
        // 2) Load and index original CSV
        let originalCSV = try await loadOriginalCSV(jobFolder: jobFolder)
        let headerIndex = headerIndexMap(originalCSV.headers)
        let perTeamTemplates = indexOriginalCSVByTeam(originalCSV, headerIndex: headerIndex)
        
        // 3) Determine source folder
        let extracted = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        let sourceRoot = source ?? extracted
        
        // 4) Copy individuals per team, collect files
        var teamToFiles: [String: [URL]] = [:]
        var copyChanges: [OperationHistory.FileChange] = []
        for team in teams {
            let files = try findIndividualImages(for: team, in: sourceRoot)
            if files.isEmpty { continue }
            var copied: [URL] = []
            for src in files {
                let dest = remakeRoot.appendingPathComponent(src.lastPathComponent)
                try safeCopy(from: src, to: dest, overwrite: true)
                copied.append(dest)
                copyChanges.append(OperationHistory.FileChange(originalURL: src, newURL: dest, mode: .copy))
            }
            teamToFiles[team] = copied
        }
        
        // 4b) Replace team photo in For Upload: remove any existing top-level team photo,
        //     copy only to group subfolder, and tag the team folder red
        let finishedTeams = jobFolder.appendingPathComponent(Constants.Folders.finishedTeams)
        let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
        let tagger = TaggingService()
        var teamPhotoChanges: [OperationHistory.FileChange] = []
        for team in teams {
            if let src = findTeamPhoto(in: finishedTeams, for: team) {
                // Ensure team folder
                let teamFolder = forUpload.appendingPathComponent(team)
                try createDirectoryIfNeeded(teamFolder)
                
                // Delete existing individual and SM files in team folder root (keep subfolders)
                try deleteIndividualAndSMFiles(in: teamFolder, team: team)
                
                // Delete any existing top-level <Team>.jpg (do not place a new one at root)
                let topLevel = teamFolder.appendingPathComponent("\(team).jpg")
                if FileManager.default.fileExists(atPath: topLevel.path) {
                    try? FileManager.default.removeItem(at: topLevel)
                }
                
                // Ensure group subfolder copy (only)
                let groupFolder = teamFolder.appendingPathComponent(Constants.Folders.group)
                try createDirectoryIfNeeded(groupFolder)
                let groupPhoto = groupFolder.appendingPathComponent("\(team).jpg")
                try safeCopy(from: src, to: groupPhoto, overwrite: true)
                teamPhotoChanges.append(OperationHistory.FileChange(originalURL: src, newURL: groupPhoto, mode: .copy))
                
                // Tag team folder red
                tagger.setRedTag(for: [teamFolder])
            }
        }
        
        // 5) Compose CSV rows
        let rows = try buildFullTeamsRows(
            original: originalCSV,
            headerIndex: headerIndex,
            perTeamTemplates: perTeamTemplates,
            teamToFiles: teamToFiles
        )
        let csvDataRowCount = rows.dropFirst().filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }.count
        
        // 6) Save CSV
        let csvURL = try await saveCSV(jobFolder: jobFolder,
                                       baseName: "SPA Ready CSV - Remake - \(timestamp).csv",
                                       rows: rows)
        
        // Record history (copy operations + CSV write)
        if let history = history {
            if !copyChanges.isEmpty {
                let record = OperationHistory.OperationRecord(
                    id: UUID(),
                    type: .sortIntoTeams,
                    timestamp: Date(),
                    affectedFiles: copyChanges,
                    reversible: false,
                    backupFolder: nil
                )
                history.record(record)
            }
            if !teamPhotoChanges.isEmpty {
                let record2 = OperationHistory.OperationRecord(
                    id: UUID(),
                    type: .sortTeamPhotos,
                    timestamp: Date(),
                    affectedFiles: teamPhotoChanges,
                    reversible: false,
                    backupFolder: nil
                )
                history.record(record2)
            }
            let csvRecord = OperationHistory.OperationRecord(
                id: UUID(),
                type: .createSPACSV,
                timestamp: Date(),
                affectedFiles: [OperationHistory.FileChange(originalURL: csvURL, newURL: csvURL, mode: .copy)],
                reversible: false,
                backupFolder: nil
            )
            history.record(csvRecord)
        }
        
        // Build counts
        let individualsCopied = teamToFiles.values.reduce(0) { $0 + $1.count }
        let teamPhotosReplacedCount = teamPhotoChanges.count // one group copy per team
        let totalCopied = individualsCopied + teamPhotoChanges.count
        
        return RebuildResult(
            csvURL: csvURL,
            remakeRoot: remakeRoot,
            teamsProcessed: Array(teamToFiles.keys).sorted(),
            filesCopied: totalCopied,
            filesMoved: 0,
            csvRowCount: csvDataRowCount,
            teamPhotosReplaced: teamPhotosReplacedCount
        )
    }
    
    func buildSMOnly(jobFolder: URL,
                     teams: [String],
                     globalSMFixTemplateName: String) async throws -> RebuildResult {
        // 1) Prepare timestamped remake root
        let (timestamp, remakeRoot) = try prepareRemakeRoot(jobFolder: jobFolder)
        
        // 2) Load and index original CSV
        let originalCSV = try await loadOriginalCSV(jobFolder: jobFolder)
        let headerIndex = headerIndexMap(originalCSV.headers)
        let perTeamTemplates = indexOriginalCSVByTeam(originalCSV, headerIndex: headerIndex)
        
        // 3) Copy SM files per team from For Upload/<Team>
        let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
        var teamToSMFiles: [String: [URL]] = [:]
        var copyChanges: [OperationHistory.FileChange] = []
        for team in teams {
            let teamFolder = forUpload.appendingPathComponent(team)
            guard FileManager.default.fileExists(atPath: teamFolder.path) else { continue }
            let urls = try fileManager.contentsOfDirectory(at: teamFolder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
            let smFiles = urls.filter { $0.lastPathComponent.contains(Constants.FileNaming.sportsMatesSuffix) }
            if smFiles.isEmpty { continue }
            var copied: [URL] = []
            for src in smFiles {
                let dest = remakeRoot.appendingPathComponent(src.lastPathComponent)
                try safeMove(from: src, to: dest, overwrite: true)
                copied.append(dest)
                copyChanges.append(OperationHistory.FileChange(originalURL: src, newURL: dest, mode: .move))
            }
            teamToSMFiles[team] = copied
        }
        
        // 3b) Replace the team photo in For Upload/<Team>/group with the Finished Teams copy
        let finishedTeams = jobFolder.appendingPathComponent(Constants.Folders.finishedTeams)
        var teamPhotoChanges: [OperationHistory.FileChange] = []
        for team in teams {
            if let src = findTeamPhoto(in: finishedTeams, for: team) {
                let teamFolder = forUpload.appendingPathComponent(team)
                try createDirectoryIfNeeded(teamFolder)
                
                // Delete existing individual and SM files in team folder root (keep subfolders)
                try deleteIndividualAndSMFiles(in: teamFolder, team: team)
                let groupFolder = teamFolder.appendingPathComponent(Constants.Folders.group)
                try createDirectoryIfNeeded(groupFolder)
                let groupPhoto = groupFolder.appendingPathComponent("\(team).jpg")
                try safeCopy(from: src, to: groupPhoto, overwrite: true)
                teamPhotoChanges.append(OperationHistory.FileChange(originalURL: src, newURL: groupPhoto, mode: .copy))
            }
        }
        
        // 4) Compose CSV rows for SM using global template
        let rows = try buildSMOnlyRows(
            original: originalCSV,
            headerIndex: headerIndex,
            perTeamTemplates: perTeamTemplates,
            teamToSMFiles: teamToSMFiles,
            globalTemplate: globalSMFixTemplateName
        )
        let csvDataRowCount = rows.dropFirst().filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }.count
        
        // 5) Save CSV
        let csvURL = try await saveCSV(jobFolder: jobFolder,
                                       baseName: "SPA Ready CSV - SM Remake - \(timestamp).csv",
                                       rows: rows)
        
        if let history = history {
            if !copyChanges.isEmpty {
                let record = OperationHistory.OperationRecord(
                    id: UUID(),
                    type: .sortIntoTeams,
                    timestamp: Date(),
                    affectedFiles: copyChanges,
                    reversible: false,
                    backupFolder: nil
                )
                history.record(record)
            }
            if !teamPhotoChanges.isEmpty {
                let record2 = OperationHistory.OperationRecord(
                    id: UUID(),
                    type: .sortTeamPhotos,
                    timestamp: Date(),
                    affectedFiles: teamPhotoChanges,
                    reversible: false,
                    backupFolder: nil
                )
                history.record(record2)
            }
            let csvRecord = OperationHistory.OperationRecord(
                id: UUID(),
                type: .createSPACSV,
                timestamp: Date(),
                affectedFiles: [OperationHistory.FileChange(originalURL: csvURL, newURL: csvURL, mode: .copy)],
                reversible: false,
                backupFolder: nil
            )
            history.record(csvRecord)
        }
        
        // Build counts
        let movedCount = teamToSMFiles.values.reduce(0) { $0 + $1.count }
        let copiedCount = teamPhotoChanges.count // group photo copies only
        let replacedTeams = teamPhotoChanges.count // 1 copy per team
        
        return RebuildResult(
            csvURL: csvURL,
            remakeRoot: remakeRoot,
            teamsProcessed: Array(teamToSMFiles.keys).sorted(),
            filesCopied: copiedCount,
            filesMoved: movedCount,
            csvRowCount: csvDataRowCount,
            teamPhotosReplaced: replacedTeams
        )
    }
    
    // MARK: - CSV Build Helpers
    
    private func buildFullTeamsRows(original: CSVParseResult,
                                    headerIndex: [String: Int],
                                    perTeamTemplates: [String: TeamCSVTemplateSet],
                                    teamToFiles: [String: [URL]]) throws -> [[String]] {
        var rows: [[String]] = []
        rows.append(original.headers)
        
        func fieldsFromOriginalRow(_ base: [String]) -> [String] {
            // Return a clean copy of base row shape
            var f = Array(repeating: "", count: original.headers.count)
            for (i, v) in base.enumerated() where i < f.count { f[i] = v }
            return f
        }
        
        for team in teamToFiles.keys.sorted() {
            guard let files = teamToFiles[team] else { continue }
            let templates = perTeamTemplates[team] ?? TeamCSVTemplateSet()
            
            // Build player pose map for this team's newly copied files
            let poseMap = buildPlayerPoseMap(for: files, team: team)
            // Infer per-template second pose requirement from original CSV rows
            let secondPoseByTemplate = inferSecondPoseByTemplate(rows: templates.individualRows, headerIndex: headerIndex)
            
            // Individual templates
            let baseIndRow = templates.individualRows.first
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Parse name/pose
                let parsed = parse(file.lastPathComponent)
                for tmplRow in templates.individualRows.isEmpty ? [Array(repeating: "", count: original.headers.count)] : templates.individualRows {
                    var fields = fieldsFromOriginalRow(baseIndRow ?? tmplRow)
                    setCommonFields(&fields,
                                    headerIndex: headerIndex,
                                    spaFile: file.lastPathComponent,
                                    teamName: team,
                                    parsed: parsed,
                                    appendSuffix: "")
                    // Ensure TEMPLATE FILE comes from tmplRow
                    var templateFileName: String?
                    if let ti = headerIndex["TEMPLATE FILE"], ti < fields.count, ti < tmplRow.count {
                        fields[ti] = tmplRow[ti]
                        templateFileName = tmplRow[ti]
                    }
                    // Multi-pose handling: compute PLAYER 2 FILE per player from pose map
                    if let tName = templateFileName,
                       let requiredSecondPose = secondPoseByTemplate[tName],
                       !requiredSecondPose.isEmpty {
                        let currentPose = sanitizePose(parsePoseFromFileName(file.lastPathComponent) ?? "")
                        let secondSan = sanitizePose(requiredSecondPose)
                        // Skip generating a row if current file is the second pose to avoid duplicates
                        if currentPose == secondSan {
                            continue
                        }
                        let key = normalizedKey(team: parsed?.team ?? team, player: parsed?.player ?? "")
                        let secondFile = poseMap[key]?[secondSan]
                        if let p2Idx = headerIndex["PLAYER 2 FILE"], p2Idx < fields.count {
                            if let s = secondFile, s != file.lastPathComponent {
                                fields[p2Idx] = s
                            } else {
                                fields[p2Idx] = "***MISSING_SECOND_POSE***"
                            }
                        }
                    } else {
                        // Clear any stale PLAYER 2 FILE if present
                        if let p2Idx = headerIndex["PLAYER 2 FILE"], p2Idx < fields.count {
                            fields[p2Idx] = ""
                        }
                    }
                    rows.append(fields)
                }
            }
            
            // spacer row between Ind and SM for readability
            rows.append(Array(repeating: "", count: original.headers.count))
            
            // SM templates
            let baseSMRow = templates.smRows.first
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let parsed = parse(file.lastPathComponent)
                for tmplRow in templates.smRows.isEmpty ? [Array(repeating: "", count: original.headers.count)] : templates.smRows {
                    var fields = fieldsFromOriginalRow(baseSMRow ?? tmplRow)
                    setCommonFields(&fields,
                                    headerIndex: headerIndex,
                                    spaFile: file.lastPathComponent,
                                    teamName: team,
                                    parsed: parsed,
                                    appendSuffix: Constants.FileNaming.sportsMatesSuffix)
                    if let ti = headerIndex["TEMPLATE FILE"], ti < fields.count, ti < tmplRow.count {
                        fields[ti] = tmplRow[ti]
                    }
                    // SM templates: ensure PLAYER 2 FILE is blank
                    if let p2Idx = headerIndex["PLAYER 2 FILE"], p2Idx < fields.count {
                        fields[p2Idx] = ""
                    }
                    rows.append(fields)
                }
            }
        }
        
        // Deduplicate identical lines (preserve header + structure)
        var seen = Set<String>()
        var out: [[String]] = []
        for r in rows {
            let line = r.joined(separator: ",")
            if seen.insert(line).inserted || r == rows.first {
                out.append(r)
            }
        }
        return out
    }
    
    private func buildSMOnlyRows(original: CSVParseResult,
                                 headerIndex: [String: Int],
                                 perTeamTemplates: [String: TeamCSVTemplateSet],
                                 teamToSMFiles: [String: [URL]],
                                 globalTemplate: String) throws -> [[String]] {
        var rows: [[String]] = []
        rows.append(original.headers)
        
        for team in teamToSMFiles.keys.sorted() {
            let files = teamToSMFiles[team] ?? []
            let templates = perTeamTemplates[team] ?? TeamCSVTemplateSet()
            let baseSMRow = templates.smRows.first // use actions/layers from original SM row if present
            
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let parsed = parse(file.lastPathComponent)
                var fields = Array(repeating: "", count: original.headers.count)
                if let base = baseSMRow {
                    for (i, v) in base.enumerated() where i < fields.count { fields[i] = v }
                }
                setCommonFields(&fields,
                                headerIndex: headerIndex,
                                spaFile: file.lastPathComponent,
                                teamName: team,
                                parsed: parsed,
                                appendSuffix: "")
                if let ti = headerIndex["TEMPLATE FILE"], ti < fields.count {
                    fields[ti] = globalTemplate
                }
                rows.append(fields)
            }
        }
        
        // Deduplicate identical lines
        var seen = Set<String>()
        var out: [[String]] = []
        for r in rows {
            let line = r.joined(separator: ",")
            if seen.insert(line).inserted || r == rows.first {
                out.append(r)
            }
        }
        return out
    }
    
    private func setCommonFields(_ fields: inout [String],
                                 headerIndex: [String: Int],
                                 spaFile: String,
                                 teamName: String,
                                 parsed: (team: String, player: String, first: String, last: String)?,
                                 appendSuffix: String) {
        if let i = headerIndex["SPA"], i < fields.count { fields[i] = spaFile }
        if let i = headerIndex["NAME"], i < fields.count { fields[i] = parsed?.player ?? "" }
        if let i = headerIndex["FIRSTNAME"], i < fields.count { fields[i] = parsed?.first ?? "" }
        if let i = headerIndex["LASTNAME"], i < fields.count { fields[i] = parsed?.last ?? "" }
        if let i = headerIndex["TEAMNAME"], i < fields.count { fields[i] = teamName }
        if let i = headerIndex["APPEND FILE NAME"], i < fields.count { fields[i] = appendSuffix }
        if let i = headerIndex["SUB FOLDER"], i < fields.count { fields[i] = teamName }
        if let i = headerIndex["TEAM FILE"], i < fields.count { fields[i] = "\(teamName).jpg" }
    }
    
    // MARK: - CSV/Index
    
    private func loadOriginalCSV(jobFolder: URL) async throws -> CSVParseResult {
        let csvURL = jobFolder.appendingPathComponent(Constants.CSV.spaReadyFileName)
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            // If missing, synthesize an empty CSV with headers for minimal mode
            let headerLine = Constants.CSV.header
            let headers = headerLine.split(separator: ",").map { String($0) }
            return CSVParseResult(headers: headers, rows: [], encoding: .utf8, delimiter: ",", lineCount: 1, warnings: [])
        }
        return try await csvService.parseCSV(from: csvURL)
    }
    
    private func headerIndexMap(_ headers: [String]) -> [String: Int] {
        var idx: [String: Int] = [:]
        for (i, h) in headers.enumerated() {
            idx[h] = i
        }
        return idx
    }
    
    private func indexOriginalCSVByTeam(_ csv: CSVParseResult, headerIndex: [String: Int]) -> [String: TeamCSVTemplateSet] {
        var out: [String: TeamCSVTemplateSet] = [:]
        let teamIdx = headerIndex["TEAMNAME"] ?? -1
        let appendIdx = headerIndex["APPEND FILE NAME"] ?? -1
        guard teamIdx >= 0, appendIdx >= 0 else { return out }
        
        for row in csv.rows {
            guard teamIdx < row.count else { continue }
            let team = row[teamIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !team.isEmpty else { continue }
            if out[team] == nil { out[team] = TeamCSVTemplateSet() }
            let suffix = appendIdx < row.count ? row[appendIdx] : ""
            if suffix == Constants.FileNaming.sportsMatesSuffix {
                out[team]?.smRows.append(row)
            } else {
                out[team]?.individualRows.append(row)
            }
        }
        return out
    }
    
    // MARK: - File Discovery/Copy
    
    private func findIndividualImages(for team: String, in sourceRoot: URL) throws -> [URL] {
        var urls: [URL] = []
        if let en = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
            while let next = en.nextObject() as? URL {
                if !Constants.FileExtensions.isImageFile(next) { continue }
                let name = next.lastPathComponent.uppercased()
                // exclude team/group/coach photos
                if name.contains("COACH") || name.contains("TEAM") || name.contains("GROUP") { continue }
                // prefix must match team_
                if !name.hasPrefix(team.uppercased() + "_") { continue }
                urls.append(next)
            }
        }
        return urls
    }
    
    private func safeCopy(from src: URL, to dst: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            if overwrite {
                try fm.removeItem(at: dst)
            } else {
                return
            }
        }
        try fm.copyItem(at: src, to: dst)
    }
    
    private func safeMove(from src: URL, to dst: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            if overwrite {
                try fm.removeItem(at: dst)
            } else {
                return
            }
        }
        try fm.moveItem(at: src, to: dst)
    }
    
    // MARK: - Save/Folder setup
    
    private func prepareRemakeRoot(jobFolder: URL) throws -> (String, URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let name = "Remake - \(stamp)"
        let remakeRoot = jobFolder.appendingPathComponent(name)
        try createDirectoryIfNeeded(remakeRoot)
        return (stamp, remakeRoot)
    }
    
    private func prepareForUploadRemake(jobFolder: URL, timestamp: String, teams: [String]) throws {
        let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
        try createDirectoryIfNeeded(forUpload)
        let remakeRoot = forUpload.appendingPathComponent("Remake - \(timestamp)")
        try createDirectoryIfNeeded(remakeRoot)
        for team in teams {
            let teamFolder = remakeRoot.appendingPathComponent(team)
            try createDirectoryIfNeeded(teamFolder)
        }
    }
    
    private func saveCSV(jobFolder: URL, baseName: String, rows: [[String]]) async throws -> URL {
        let csvURL = jobFolder.appendingPathComponent(baseName)
        try await csvService.writeCSV(rows, to: csvURL, encoding: .utf8)
        return csvURL
    }
    
    private func deleteIndividualAndSMFiles(in teamFolder: URL, team: String) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: teamFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for url in contents {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                if Constants.FileExtensions.isImageFile(url) {
                    let base = url.lastPathComponent
                    // Skip the team photo (we will replace it right after)
                    if base.caseInsensitiveCompare("\(team).jpg") == .orderedSame { continue }
                    try? fm.removeItem(at: url)
                }
            }
        }
    }
    
    // MARK: - Pose Helpers
    
    // Build a map from "team_player" -> sanitizedPose -> filename
    private func buildPlayerPoseMap(for files: [URL], team: String) -> [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for url in files {
            let name = url.lastPathComponent
            let player = parse(name)?.player ?? ""
            let key = normalizedKey(team: team, player: player)
            let pose = sanitizePose(parsePoseFromFileName(name) ?? "")
            if map[key] == nil { map[key] = [:] }
            map[key]?[pose] = name
        }
        return map
    }
    
    // Infer second pose requirement per template by scanning original rows for that team
    private func inferSecondPoseByTemplate(rows: [[String]], headerIndex: [String: Int]) -> [String: String] {
        guard let tIdx = headerIndex["TEMPLATE FILE"], let p2Idx = headerIndex["PLAYER 2 FILE"] else { return [:] }
        var counts: [String: [String: Int]] = [:] // template -> pose -> count
        for r in rows {
            guard tIdx < r.count, p2Idx < r.count else { continue }
            let tmpl = r[tIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tmpl.isEmpty else { continue }
            let p2 = r[p2Idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if p2.isEmpty || p2 == "***MISSING_SECOND_POSE***" { continue }
            if let pose = parsePoseFromFileName(p2) {
                let sp = sanitizePose(pose)
                var byPose = counts[tmpl] ?? [:]
                byPose[sp] = (byPose[sp] ?? 0) + 1
                counts[tmpl] = byPose
            }
        }
        var result: [String: String] = [:]
        for (tmpl, byPose) in counts {
            if let (pose, _) = byPose.max(by: { $0.value < $1.value }) {
                result[tmpl] = pose
            }
        }
        return result
    }
    
    private func parsePoseFromFileName(_ fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_").map(String.init)
        guard let last = parts.last, Int(last) != nil else { return nil }
        return last
    }
    
    private func sanitizePose(_ pose: String) -> String {
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
    
    private func findTeamPhoto(in finishedTeams: URL, for team: String) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: finishedTeams, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        // Prefer files that start with "<TEAM>_" then fall back to any file that equals "<TEAM>.jpg"
        let upperTeam = team.uppercased()
        if let first = items.first(where: { ($0.deletingPathExtension().lastPathComponent.uppercased()).hasPrefix(upperTeam + "_") }) {
            return first
        }
        let alt = finishedTeams.appendingPathComponent("\(team).jpg")
        if fm.fileExists(atPath: alt.path) { return alt }
        return nil
    }
    
    private func createDirectoryIfNeeded(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Filename parsing
    
    // Parse file name TEAM_First Last_01.jpg → (team, player, first, last)
    private func parse(_ fileName: String) -> (team: String, player: String, first: String, last: String)? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let tokens = Set(parts.map { $0.uppercased() })
        if tokens.contains("COACH") || tokens.contains("TEAM") || tokens.contains("GROUP") {
            return nil
        }
        guard let last = parts.last, Int(last) != nil else { return nil }
        let team = parts[0]
        let playerFull = parts.dropFirst().dropLast().joined(separator: " ")
        let nameParts = playerFull.split(separator: " ")
        let first = nameParts.first.map(String.init) ?? ""
        let lastName = nameParts.dropFirst().joined(separator: " ")
        return (team, playerFull, first, lastName)
    }
}


