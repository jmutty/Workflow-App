import Foundation

struct TeamPhotoItem: Hashable {
    let teamName: String
    let sourceURL: URL
}

@MainActor
class SortTeamPhotosViewModel: ObservableObject {
    @Published var overwriteExisting: Bool = false
    @Published var createMissingFolders: Bool = true
    @Published var isAnalyzing: Bool = false
    @Published var isMoving: Bool = false
    @Published var detectedTeams: Set<String> = []
    @Published var foundFiles: [TeamPhotoItem] = []
    @Published var analysisReady: Bool = false
    @Published var lastError: String?
    
    // Progress
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var filesCompleted: Int = 0
    @Published var totalFiles: Int = 0
    
    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    
    init(jobFolder: URL, fileManager: FileManagerProtocol = FileManager.default) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
    }
    
    func analyze() async -> Bool {
        isAnalyzing = true
        lastError = nil
        detectedTeams = []
        foundFiles = []
        analysisReady = false
        operationProgress = 0
        currentOperation = "Scanning..."
        filesCompleted = 0
        totalFiles = 0
        defer { isAnalyzing = false }
        
        let finishedTeams = jobFolder.appendingPathComponent(Constants.Folders.finishedTeams)
        do {
            let urls = try fileManager.contentsOfDirectory(at: finishedTeams, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
            let images = urls.filter { Constants.FileExtensions.isImageFile($0) }
            totalFiles = images.count
            var items: [TeamPhotoItem] = []
            var teams = Set<String>()
            for (i, url) in images.enumerated() {
                let name = url.lastPathComponent
                // Expect naming like TEAM_something.jpg so team is prefix until first '_'
                let base = (name as NSString).deletingPathExtension
                let parts = base.split(separator: "_")
                guard let team = parts.first.map(String.init), !team.isEmpty else { continue }
                items.append(TeamPhotoItem(teamName: team, sourceURL: url))
                teams.insert(team)
                filesCompleted = i + 1
                operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
                currentOperation = name
            }
            foundFiles = items
            detectedTeams = teams
            analysisReady = true
            currentOperation = ""
            return true
        } catch {
            lastError = "Error scanning Finished Teams: \(error.localizedDescription)"
            return false
        }
    }
    
    func executeMove() async -> Bool {
        guard !foundFiles.isEmpty else { return false }
        isMoving = true
        operationProgress = 0
        filesCompleted = 0
        currentOperation = "Copying..."
        defer { isMoving = false }
        do {
            let fm = FileManager.default
            let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
            if !fm.fileExists(atPath: forUpload.path) { try fm.createDirectory(at: forUpload, withIntermediateDirectories: true) }

            // Discover ALT background PNGs in Extracted/Cropped
            let extracted = jobFolder.appendingPathComponent(Constants.Folders.extracted)
            let cropped = extracted.appendingPathComponent("Cropped")
            var altPngFiles: [URL] = []
            if fm.fileExists(atPath: cropped.path) {
                if let en = fm.enumerator(at: cropped, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                    while let obj = en.nextObject() as AnyObject? {
                        if let u = obj as? URL, u.pathExtension.lowercased() == "png" {
                            altPngFiles.append(u)
                        }
                    }
                }
            }

            // Update total to include both team photos and ALT backgrounds
            totalFiles = foundFiles.count + altPngFiles.count

            // First: copy team photos to For Upload/<Team>/group
            for (i, item) in foundFiles.enumerated() {
                let teamFolder = forUpload.appendingPathComponent(item.teamName).appendingPathComponent(Constants.Folders.group)
                if createMissingFolders && !fm.fileExists(atPath: teamFolder.path) {
                    try fm.createDirectory(at: teamFolder, withIntermediateDirectories: true)
                }
                let dest = teamFolder.appendingPathComponent(item.sourceURL.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    if overwriteExisting { try fm.removeItem(at: dest) } else { filesCompleted = i + 1; operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0; continue }
                }
                try fm.copyItem(at: item.sourceURL, to: dest)
                filesCompleted = i + 1
                operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
                currentOperation = item.sourceURL.lastPathComponent
            }

            // Then: move ALT background PNGs to For Upload/<Team> ALT BACKGROUNDS/
            for (j, url) in altPngFiles.enumerated() {
                let name = url.lastPathComponent
                let base = (name as NSString).deletingPathExtension
                let parts = base.split(separator: "_")
                guard let teamRaw = parts.first.map(String.init), !teamRaw.isEmpty else { continue }
                let team = teamRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let altFolderName = "\(team) ALT BACKGROUNDS"
                let altFolder = forUpload.appendingPathComponent(altFolderName)
                if createMissingFolders && !fm.fileExists(atPath: altFolder.path) {
                    try fm.createDirectory(at: altFolder, withIntermediateDirectories: true)
                }
                let dest = altFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    if overwriteExisting {
                        try fm.removeItem(at: dest)
                    } else {
                        filesCompleted = foundFiles.count + j + 1
                        operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
                        continue
                    }
                }
                try fm.moveItem(at: url, to: dest)
                filesCompleted = foundFiles.count + j + 1
                operationProgress = totalFiles > 0 ? Double(filesCompleted) / Double(totalFiles) : 0
                currentOperation = name
            }

            return true
        } catch {
            lastError = "Error moving team photos: \(error.localizedDescription)"
            return false
        }
    }
}


