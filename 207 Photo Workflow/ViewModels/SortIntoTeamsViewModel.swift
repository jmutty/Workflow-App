import Foundation
import Combine
import AppKit

struct ParsedNameInfo {
    let team: String
    let playerName: String
    let pose: String
    let isCoach: Bool
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
    
    // Analysis results
    @Published var detectedTeams: [String] = []
    @Published var teamPoseFiles: [TeamPoseFile] = []
    @Published var coachFiles: [CoachFile] = []
    @Published var teamPoseCounts: [String: Int] = [:]
    
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
    }
    
    func analyze() async {
        detectedTeams = []
        teamPoseFiles = []
        coachFiles = []
        teamPoseCounts = [:]
        operationProgress = 0
        currentOperation = "Analyzing files..."
        defer { currentOperation = "" }
        
        let extracted = jobFolder.appendingPathComponent("Extracted")
        let sortedRoot = extracted.appendingPathComponent(Constants.Folders.sortedTeams)
        let fm = FileManager.default
        do {
            let files: [URL] = try {
                if includeSubfolders {
                    var all: [URL] = []
                    if let en = fm.enumerator(at: extracted, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                        for case let u as URL in en { all.append(u) }
                    }
                    return all
                } else {
                    return try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.contentTypeKey])
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
                    if parsed.isCoach {
                        let teamFolder = extracted.appendingPathComponent(parsed.team)
                        let destinationPath = "\(parsed.team)/\(name)"
                        let newName = name.hasPrefix("TOP ") ? name : "TOP \(name)"
                        let cf = CoachFile(
                            originalName: name,
                            teamName: parsed.team,
                            sourceURL: url,
                            destinationFolder: teamFolder,
                            destinationPath: destinationPath,
                            newName: newName
                        )
                        foundCoach.append(cf)
                        teams.insert(parsed.team)
                    } else if !parsed.isGroup, !parsed.playerName.isEmpty, !parsed.pose.isEmpty {
                        teams.insert(parsed.team)
                        if parsed.pose == selectedPose {
                            let teamFolder = extracted.appendingPathComponent(parsed.team)
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
            summaryMessage = "Teams: \(detectedTeams.count) • Pose \(selectedPose): \(teamPoseFiles.count) • Coach: \(coachFiles.count)"
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
        let total = coachFiles.count + teamPoseFiles.count
        var completed = 0
        
        // Coach files: move first before player photos
        if processCoachFiles {
            for coach in coachFiles {
                let finalName = coach.newName ?? coach.originalName
                let dest = sortedRoot.appendingPathComponent(coach.teamName).appendingPathComponent(finalName)
                if fm.fileExists(atPath: dest.path) && !overwrite { completed += 1; operationProgress = Double(completed)/Double(total); continue }
                if overwrite && fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                do {
                    try fm.moveItem(at: coach.sourceURL, to: dest)
                    changes.append(.init(originalURL: coach.sourceURL, newURL: dest))
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
                } else {
                    try fm.moveItem(at: tf.sourceURL, to: dest)
                }
                changes.append(.init(originalURL: tf.sourceURL, newURL: dest))
            } catch {
                // ignore file op error
            }
            completed += 1
            operationProgress = Double(completed)/Double(total)
        }
        
        if !changes.isEmpty {
            history.record(.init(
                id: UUID(),
                type: .sortIntoTeams,
                timestamp: Date(),
                affectedFiles: changes,
                reversible: true,
                backupFolder: nil
            ))
        }
        summaryMessage = "Sorted \(completed)/\(total)"
    }
    
    func cancelSort() {
        fileProcessor.cancel()
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
        // Detect COACH or COACHn where n is optional digits
        let isCoach: Bool = upper.contains("COACH") || upper.contains(where: { $0.hasPrefix("COACH") })
        if isTeam { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: false, isGroup: false, isTeamPhoto: true) }
        if isCoach { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: true, isGroup: false, isTeamPhoto: false) }
        if isGroup { return ParsedNameInfo(team: team, playerName: "", pose: "", isCoach: false, isGroup: true, isTeamPhoto: false) }
        // Player: last segment must be numeric pose
        guard let last = parts.last, Int(last) != nil else { return nil }
        let pose = String(last)
        let playerParts = parts.dropFirst().dropLast()
        guard !playerParts.isEmpty else { return nil }
        let playerName = playerParts.joined(separator: " ")
        return ParsedNameInfo(team: team, playerName: playerName, pose: pose, isCoach: false, isGroup: false, isTeamPhoto: false)
    }
}
