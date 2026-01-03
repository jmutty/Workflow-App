import Foundation
import Combine
import AppKit

struct ParsedNameInfo {
    let team: String
    let playerName: String
    let pose: String
    let isCoach: Bool
    let isManager: Bool
    let isGroup: Bool
    let isTeamPhoto: Bool
}

@MainActor
class SortIntoTeamsViewModel: ObservableObject {
    // Configuration
    @Published var selectedPose: String = "1"
    @Published var copyTeamPhotos: Bool = true
    @Published var processCoachFiles: Bool = true
    @Published var createTeamFolders: Bool = true
    @Published var includeSubfolders: Bool = false
    @Published var overwriteExisting: Bool = false
    
    // State
    @Published var isSorting: Bool = false
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var summaryMessage: String = ""
    @Published var lastSortOperationId: UUID?
    
    // Analysis results
    @Published var detectedTeams: [String] = []
    @Published var teamPoseFiles: [TeamPoseFile] = []
    @Published var coachFiles: [CoachFile] = []
    @Published var teamPoseCounts: [String: Int] = [:]
    
    // Swing handling
    @Published var swingTeams: [String] = []
    @Published var swingFilesByTeam: [String: [TeamPoseFile]] = [:]
    @Published var allPlayerFilesByTeam: [String: [TeamPoseFile]] = [:]
    @Published var showSwingPrompt: Bool = false
    // User selections for resolving swing players: map swing team -> two chosen teams
    @Published var swingSelections: [String: (String?, String?)] = [:]
    
    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    private let fileProcessor: FileProcessingService
    private let history: OperationHistoryProtocol
    
    init(jobFolder: URL,
         fileManager: FileManagerProtocol = FileManager.default,
         fileProcessor: FileProcessingService = FileProcessingService(),
         history: OperationHistoryProtocol = OperationHistory()) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
        self.fileProcessor = fileProcessor
        self.history = history
    }
    
    func initialize() async {
        await analyze()
        await checkForExistingSortBackups()
    }
    
    func analyze() async {
        detectedTeams = []
        teamPoseFiles = []
        coachFiles = []
        teamPoseCounts = [:]
        swingTeams = []
        swingFilesByTeam = [:]
        allPlayerFilesByTeam = [:]
        showSwingPrompt = false
        operationProgress = 0
        currentOperation = "Analyzing files..."
        defer { currentOperation = "" }
        
        let extracted = jobFolder.appendingPathComponent("Extracted")
        let fm = FileManager.default
        do {
            let files: [URL] = try {
                if includeSubfolders {
                    var all: [URL] = []
                    if let en = fm.enumerator(at: extracted, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                        for case let u as URL in en {
                            // Exclude archived swing folders
                            let last = u.deletingLastPathComponent().lastPathComponent
                            if last.hasSuffix("_FILES COPIED - SAFE TO DELETE") { continue }
                            all.append(u)
                        }
                    }
                    return all
                } else {
                    // Exclude archived swing folders at root level
                    let roots = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey])
                    var result: [URL] = []
                    for u in roots {
                        if u.lastPathComponent.hasSuffix("_FILES COPIED - SAFE TO DELETE") { continue }
                        result.append(u)
                    }
                    return result
                }
            }()
            let imageFiles = files.filter { Constants.FileExtensions.isImageFile($0) }
            guard !imageFiles.isEmpty else { summaryMessage = "No images found in Extracted"; return }
            
            var teams: Set<String> = []
            var foundPoseFiles: [TeamPoseFile] = []
            var foundCoach: [CoachFile] = []
            var counts: [String: Int] = [:]
            
            for url in imageFiles {
                let name = url.lastPathComponent
                if let parsed = parseFilename(name) {
                    if parsed.isTeamPhoto { continue }
                    if parsed.isCoach || parsed.isManager {
                        let teamFolder = extracted.appendingPathComponent(parsed.team)
                        let destinationPath = "\(parsed.team)/\(name)"
                        let newName = name.hasPrefix("TOP ") ? name : "TOP \(name)"
                        let cf = CoachFile(
                            originalName: name,
                            teamName: parsed.team,
                            sourceURL: url,
                            destinationFolder: teamFolder,
                            destinationPath: destinationPath,
                            newName: newName,
                            isManager: parsed.isManager
                        )
                        foundCoach.append(cf)
                        teams.insert(parsed.team)
                    } else if !parsed.isGroup, !parsed.playerName.isEmpty, !parsed.pose.isEmpty {
                        teams.insert(parsed.team)
                        // Collect all player files by team (regardless of pose) to help swing detection
                        let teamFolder = extracted.appendingPathComponent(parsed.team)
                        let tfAnyPose = TeamPoseFile(
                            originalName: name,
                            teamName: parsed.team,
                            poseNumber: parsed.pose,
                            sourceURL: url,
                            destinationFolder: teamFolder
                        )
                        allPlayerFilesByTeam[parsed.team, default: []].append(tfAnyPose)
                        if parsed.pose == selectedPose {
                            let tf = TeamPoseFile(
                                originalName: name,
                                teamName: parsed.team,
                                poseNumber: parsed.pose,
                                sourceURL: url,
                                destinationFolder: teamFolder
                            )
                            foundPoseFiles.append(tf)
                            counts[parsed.team, default: 0] += 1
                        }
                    }
                }
            }
            detectedTeams = Array(teams).sorted()
            teamPoseFiles = foundPoseFiles.sorted { $0.teamName < $1.teamName }
            coachFiles = foundCoach.sorted { $0.teamName < $1.teamName }
            teamPoseCounts = counts
            let managerCount = foundCoach.filter { $0.isManager }.count
            let coachOnlyCount = foundCoach.count - managerCount
            summaryMessage = "Teams: \(detectedTeams.count) • Pose \(selectedPose): \(teamPoseFiles.count) • Coach: \(coachOnlyCount) • Manager: \(managerCount)"

            // Detect swing teams (name contains swing variants)
            let swingKeywords = ["swing", "swings", "swinger", "swingers"]
            let swingSet = Set(detectedTeams.filter { team in
                let lower = team.lowercased()
                return swingKeywords.contains(where: { lower.contains($0) })
            })
            if !swingSet.isEmpty {
                var map: [String: [TeamPoseFile]] = [:]
                // Use all files by team so we show swing files even if pose != selectedPose
                for (team, files) in allPlayerFilesByTeam {
                    if swingSet.contains(team) {
                        map[team, default: []].append(contentsOf: files)
                    }
                }
                swingTeams = Array(map.keys).sorted()
                swingFilesByTeam = map
                if !swingTeams.isEmpty {
                    showSwingPrompt = true
                }
            }
        } catch {
            summaryMessage = "Error analyzing: \(error.localizedDescription)"
        }
    }
    
    func executeSort(overwrite: Bool) async {
        let fm = FileManager.default
        guard !(teamPoseFiles.isEmpty && coachFiles.isEmpty) else { return }
        isSorting = true
        operationProgress = 0
        currentOperation = "Sorting files..."
        defer { isSorting = false; currentOperation = "" }
        
        let extracted = jobFolder.appendingPathComponent("Extracted")
        let sortedRoot = extracted.appendingPathComponent(Constants.Folders.sortedTeams)
        // Ensure team folders
        if createTeamFolders {
            if !fm.fileExists(atPath: sortedRoot.path) {
                try? fm.createDirectory(at: sortedRoot, withIntermediateDirectories: true)
            }
            for team in detectedTeams {
                let tf = sortedRoot.appendingPathComponent(team)
                if !fm.fileExists(atPath: tf.path) { try? fm.createDirectory(at: tf, withIntermediateDirectories: true) }
            }
        }
        
        var changes: [OperationHistory.FileChange] = []
        let managers = coachFiles.filter { $0.isManager }
        let coachesOnly = coachFiles.filter { !$0.isManager }
        let total = managers.count + coachesOnly.count + teamPoseFiles.count
        var completed = 0
        
        // Manager files: always process, copy into team folders with TOP prefix
        for manager in managers {
            let finalName = manager.newName ?? manager.originalName
            let dest = sortedRoot.appendingPathComponent(manager.teamName).appendingPathComponent(finalName)
            if fm.fileExists(atPath: dest.path) && !overwrite { completed += 1; operationProgress = Double(completed)/Double(total); continue }
            if overwrite && fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            do {
                try fm.copyItem(at: manager.sourceURL, to: dest)
                changes.append(.init(originalURL: manager.sourceURL, newURL: dest, mode: .copy))
            } catch {
                // ignore copy errors
            }
            completed += 1
            operationProgress = Double(completed)/Double(total)
        }

        // Coach files: move before player photos (optional via toggle)
        if processCoachFiles {
            for coach in coachesOnly {
                let finalName = coach.newName ?? coach.originalName
                let dest = sortedRoot.appendingPathComponent(coach.teamName).appendingPathComponent(finalName)
                if fm.fileExists(atPath: dest.path) && !overwrite { completed += 1; operationProgress = Double(completed)/Double(total); continue }
                if overwrite && fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                do {
                    try fm.moveItem(at: coach.sourceURL, to: dest)
                    changes.append(.init(originalURL: coach.sourceURL, newURL: dest, mode: .move))
                } catch {
                    // ignore move errors
                }
                completed += 1
                operationProgress = Double(completed)/Double(total)
            }
        }
        
        // Team pose files
        for tf in teamPoseFiles {
            let dest = sortedRoot.appendingPathComponent(tf.teamName).appendingPathComponent(tf.originalName)
            if fm.fileExists(atPath: dest.path) && !overwrite { completed += 1; operationProgress = Double(completed)/Double(total); continue }
            if overwrite && fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            do {
                if copyTeamPhotos {
                    try fm.copyItem(at: tf.sourceURL, to: dest)
                    changes.append(.init(originalURL: tf.sourceURL, newURL: dest, mode: .copy))
                } else {
                    try fm.moveItem(at: tf.sourceURL, to: dest)
                    changes.append(.init(originalURL: tf.sourceURL, newURL: dest, mode: .move))
                }
            } catch {
                // ignore file op error
            }
            completed += 1
            operationProgress = Double(completed)/Double(total)
        }
        
        if !changes.isEmpty {
            // Record history and keep operation id for undo
            let record = OperationHistory.OperationRecord(
                id: UUID(),
                type: .sortIntoTeams,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: true,
                backupFolder: nil
            )
            history.record(record)
            lastSortOperationId = record.id
            
            // Write mapping CSV for sort operations
            writeSortMappingCSV(for: changes)
        }
        summaryMessage = "Sorted \(completed)/\(total)"
    }
    
    func cancelSort() {
        fileProcessor.cancel()
    }
    
    func undoLastSort() async {
        guard let id = lastSortOperationId else { return }
        do {
            try await history.undo(operationId: id)
            lastSortOperationId = nil
            await analyze()
        } catch {
            // Silent failure; UI can surface errors in future enhancement
        }
    }
    
    private func checkForExistingSortBackups() async {
        let fm = FileManager.default
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        guard fm.fileExists(atPath: backupsRoot.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: [.creationDateKey], options: [])
            let sortCSVs = files.filter { $0.lastPathComponent.hasPrefix("Sort_") && $0.pathExtension.lowercased() == "csv" && !$0.path.contains("/Archive/") }
            guard let latest = sortCSVs.max(by: { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return da < db
            }) else { return }
            
            // Parse minimal CSV to rebuild a synthetic undo record
            let contents = (try? String(contentsOf: latest, encoding: .utf8)) ?? ""
            let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count >= 2 else { return }
            let header = lines.first?.split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.map { $0.lowercased() } ?? []
            func idx(_ key: String) -> Int? {
                let normKey = key.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression)
                for (i, h) in header.enumerated() {
                    let n = h.replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression)
                    if n == normKey { return i }
                }
                return nil
            }
            let actionIdx = idx("action")
            let opIdx = idx("original_path")
            let onIdx = idx("original_name")
            let npIdx = idx("new_path")
            let nnIdx = idx("new_name")
            
            var changes: [OperationHistory.FileChange] = []
            for line in lines.dropFirst() {
                // Basic CSV splitting honoring simple quoted fields
                var fields: [String] = []
                var current = ""
                var inQuotes = false
                for ch in line {
                    if ch == "\"" {
                        inQuotes.toggle()
                        continue
                    }
                    if ch == "," && !inQuotes {
                        fields.append(current)
                        current = ""
                    } else {
                        current.append(ch)
                    }
                }
                fields.append(current)
                let trimmed = fields.map { $0.trimmingCharacters(in: .whitespaces) }
                guard trimmed.count >= 5 || (opIdx != nil && npIdx != nil) else { continue }
                
                let action = actionIdx.flatMap { trimmed.indices.contains($0) ? trimmed[$0] : nil }?.lowercased() ?? "moved"
                let mode: OperationHistory.ChangeMode = action.contains("copy") ? .copy : .move
                let oPath = opIdx.flatMap { trimmed.indices.contains($0) ? trimmed[$0] : nil } ?? ""
                let nPath = npIdx.flatMap { trimmed.indices.contains($0) ? trimmed[$0] : nil } ?? ""
                let oName = onIdx.flatMap { trimmed.indices.contains($0) ? trimmed[$0] : nil } ?? (oPath as NSString).lastPathComponent
                let nName = nnIdx.flatMap { trimmed.indices.contains($0) ? trimmed[$0] : nil } ?? (nPath as NSString).lastPathComponent
                
                var originalURL = jobFolder.appendingPathComponent(oPath)
                var newURL = jobFolder.appendingPathComponent(nPath)
                if !fm.fileExists(atPath: originalURL.path) {
                    let test = jobFolder.appendingPathComponent("Extracted").appendingPathComponent(oName)
                    if fm.fileExists(atPath: test.path) { originalURL = test }
                }
                if !fm.fileExists(atPath: newURL.path) {
                    let testA = jobFolder.appendingPathComponent("Extracted").appendingPathComponent(nName)
                    let testB = jobFolder.appendingPathComponent("Extracted/\(Constants.Folders.sortedTeams)").appendingPathComponent(nName)
                    if fm.fileExists(atPath: testA.path) { newURL = testA }
                    else if fm.fileExists(atPath: testB.path) { newURL = testB }
                }
                changes.append(.init(originalURL: originalURL, newURL: newURL, mode: mode))
            }
            guard !changes.isEmpty else { return }
            
            let record = OperationHistory.OperationRecord(
                id: UUID(),
                type: .sortIntoTeams,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: true,
                backupFolder: nil
            )
            history.record(record)
            lastSortOperationId = record.id
        } catch {
            // ignore detection errors
        }
    }
    
    private func writeSortMappingCSV(for changes: [OperationHistory.FileChange]) {
        let fm = FileManager.default
        let backupsRoot = jobFolder.appendingPathComponent("Backups")
        if !fm.fileExists(atPath: backupsRoot.path) {
            try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        }
        let ts = Int(Date().timeIntervalSince1970)
        let csvURL = backupsRoot.appendingPathComponent("Sort_\(ts)_mapping.csv")
        
        func relPath(_ url: URL) -> String {
            let base = jobFolder.path.hasSuffix("/") ? jobFolder.path : jobFolder.path + "/"
            return url.path.replacingOccurrences(of: base, with: "")
        }
        func esc(_ s: String) -> String {
            let doubled = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        
        var lines: [String] = []
        lines.append("action,original_path,original_name,new_path,new_name")
        for ch in changes {
            let action = (ch.mode == .copy) ? "copied" : "moved"
            let oPath = relPath(ch.originalURL)
            let nPath = relPath(ch.newURL)
            let row = [
                esc(action),
                esc(oPath),
                esc(ch.originalURL.lastPathComponent),
                esc(nPath),
                esc(ch.newURL.lastPathComponent)
            ].joined(separator: ",")
            lines.append(row)
        }
        let csv = lines.joined(separator: "\n")
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
    }
    
    private func parseFilename(_ fileName: String) -> ParsedNameInfo? {
        let name = (fileName as NSString).deletingPathExtension
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let upper = parts.map { $0.uppercased() }
        let team = parts[0]
        // Detect tokens
        let isTeam = upper.contains("TEAM")
        let isGroup = upper.contains("GROUP")
        // Detect COACH or COACHn where n is optional digits; detect MANAGER similarly
        let isCoach: Bool = upper.contains("COACH") || upper.contains(where: { $0.hasPrefix("COACH") })
        let isManager: Bool = upper.contains("MANAGER") || upper.contains(where: { $0.hasPrefix("MANAGER") })
        if isTeam { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: false, isManager: false, isGroup: false, isTeamPhoto: true) }
        if isCoach { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: true, isManager: false, isGroup: false, isTeamPhoto: false) }
        if isManager { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: false, isManager: true, isGroup: false, isTeamPhoto: false) }
        if isGroup { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: false, isManager: false, isGroup: true, isTeamPhoto: false) }
        // Player: last segment must be numeric pose
        guard let last = parts.last, Int(last) != nil else { return nil }
        let pose = String(last)
        let playerParts = parts.dropFirst().dropLast()
        guard !playerParts.isEmpty else { return nil }
        let playerName = playerParts.joined(separator: " ")
        return ParsedNameInfo(team: team, playerName: playerName, pose: pose, isCoach: false, isManager: false, isGroup: false, isTeamPhoto: false)
    }

    // MARK: - Swing Resolution
    func suggestedTeams(for swingTeam: String) -> (String?, String?) {
        // Heuristic: remove swing keywords and try to find matching JV/Varsity teams
        let lower = swingTeam.lowercased()
        let base = lower
            .replacingOccurrences(of: "swingers", with: "")
            .replacingOccurrences(of: "swinger", with: "")
            .replacingOccurrences(of: "swings", with: "")
            .replacingOccurrences(of: "swing", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var jv: String?
        var v: String?
        for team in detectedTeams {
            let t = team.lowercased()
            if t.contains(base) {
                if (t.contains(" jv") || t.hasSuffix("jv") || t.contains(" junior") ) {
                    jv = team
                }
                if (t.contains(" v") || t.contains(" varsity")) {
                    v = team
                }
            }
        }
        return (v, jv)
    }

    func updateSelection(for swingTeam: String, firstTeam: String?, secondTeam: String?) {
        swingSelections[swingTeam] = (firstTeam, secondTeam)
    }

    func hasCompleteSelections() -> Bool {
        guard !swingTeams.isEmpty else { return false }
        for swing in swingTeams {
            // If user provided a complete selection, accept it
            if let sel = swingSelections[swing],
               let a = sel.0, let b = sel.1,
               !a.isEmpty, !b.isEmpty, a != b {
                continue
            }
            // Otherwise, fall back to auto-suggestions
            let suggested = suggestedTeams(for: swing)
            if let a = suggested.0, let b = suggested.1,
               !a.isEmpty, !b.isEmpty, a != b {
                continue
            }
            // Neither explicit selection nor valid suggestion present
            return false
        }
        return true
    }

    func resolveSwingPlayers(applyToAll: Bool = true) async {
        guard !swingTeams.isEmpty else { return }
        let fm = FileManager.default
        let extracted = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        for swing in swingTeams {
            guard let files = swingFilesByTeam[swing], !files.isEmpty else { continue }
            let selection = swingSelections[swing]
            let (teamAOpt, teamBOpt) = selection ?? suggestedTeams(for: swing)
            guard let teamA = teamAOpt, let teamB = teamBOpt, !teamA.isEmpty, !teamB.isEmpty, teamA != teamB else { continue }

            // Precompute used numbers for teams A and B
            var usedA: Set<Int> = collectUsedPlayerNumbers(in: extracted, forTeam: teamA)
            var usedB: Set<Int> = collectUsedPlayerNumbers(in: extracted, forTeam: teamB)

            // Prepare archive folder for this swing team
            let archiveFolderName = "\(swing)_FILES COPIED - SAFE TO DELETE"
            let archiveFolder = extracted.appendingPathComponent(archiveFolderName)
            if !fm.fileExists(atPath: archiveFolder.path) {
                try? fm.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
            }

            for tf in files {
                let origURL = tf.sourceURL
                let name = tf.originalName
                let ext = origURL.pathExtension
                let base = (name as NSString).deletingPathExtension
                let parts = base.split(separator: "_").map(String.init)
                guard parts.count >= 2 else { continue }

                // Parts: [TEAM, player components..., pose]
                let pose = parts.last ?? selectedPose

                // Build new name using a single Subject<number> token (no Player token)
                func buildNewName(for team: String, nextNumber: inout Int, used: inout Set<Int>) -> String {
                    let assigned = nextAvailableNumber(startAt: 500, used: used, current: &nextNumber)
                    used.insert(assigned)
                    // Only keep a single Subject token; drop any existing Player/Subject tokens
                    var pp: [String] = []
                    pp.append("Subject\(assigned)")
                    let newBase = ([team] + pp + [pose]).joined(separator: "_")
                    return newBase + "." + ext
                }

                var cursorA = 500
                var cursorB = 500
                let newNameA = buildNewName(for: teamA, nextNumber: &cursorA, used: &usedA)
                let newNameB = buildNewName(for: teamB, nextNumber: &cursorB, used: &usedB)

                let destA = extracted.appendingPathComponent(newNameA)
                let destB = extracted.appendingPathComponent(newNameB)
                do {
                    if !fm.fileExists(atPath: destA.path) { try fm.copyItem(at: origURL, to: destA) }
                    if !fm.fileExists(atPath: destB.path) { try fm.copyItem(at: origURL, to: destB) }
                    // Move original swing file to archive folder instead of deleting
                    let archivedURL = archiveFolder.appendingPathComponent(origURL.lastPathComponent)
                    if fm.fileExists(atPath: archivedURL.path) {
                        try? fm.removeItem(at: archivedURL)
                    }
                    try fm.moveItem(at: origURL, to: archivedURL)
                } catch {
                    // ignore errors per-file
                }
            }
        }
        // After resolution, re-analyze to refresh lists
        await analyze()
    }

    private func collectUsedPlayerNumbers(in folder: URL, forTeam team: String) -> Set<Int> {
        var used: Set<Int> = []
        let fm = FileManager.default
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                guard Constants.FileExtensions.isImageFile(u) else { continue }
                let base = (u.lastPathComponent as NSString).deletingPathExtension
                let parts = base.split(separator: "_").map(String.init)
                guard parts.count >= 2 else { continue }
                let t = parts[0]
                if t != team { continue }
                let middle = parts.dropFirst().dropLast()
                for token in middle {
                    if token.hasPrefix("Player") {
                        if let num = Int(token.replacingOccurrences(of: "Player", with: "")) { used.insert(num) }
                    } else if token.hasPrefix("Subject") {
                        if let num = Int(token.replacingOccurrences(of: "Subject", with: "")) { used.insert(num) }
                    }
                }
            }
        }
        return used
    }

    private func nextAvailableNumber(startAt: Int, used: Set<Int>, current: inout Int) -> Int {
        var n = max(startAt, current)
        while used.contains(n) { n += 1 }
        current = n + 1
        return n
    }
}
