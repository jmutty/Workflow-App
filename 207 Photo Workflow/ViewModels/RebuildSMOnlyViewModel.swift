import Foundation
import Combine
import SwiftUI

@MainActor
class RebuildSMOnlyViewModel: ObservableObject {
    @Published var availableTeams: [String] = []
    @Published var selectedTeams: Set<String> = []
    @Published var globalSMFixTemplateName: String = "SM FIX Template.psd"
    @Published var isAnalyzing: Bool = false
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    
    @Published var resultCSVURL: URL?
    @Published var remakeRootURL: URL?
    @Published var lastFilesCopied: Int = 0
    @Published var lastFilesMoved: Int = 0
    @Published var lastCsvRows: Int = 0
    @Published var lastTeamsWithNewPhotos: Int = 0
    @Published var showSummary: Bool = false
    
    private let jobFolder: URL
    private let rebuildService: RebuildService
    private let taggingService: TaggingService
    
    init(jobFolder: URL,
         rebuildService: RebuildService? = nil,
         taggingService: TaggingService? = nil) {
        self.jobFolder = jobFolder
        self.rebuildService = rebuildService ?? RebuildService()
        self.taggingService = taggingService ?? TaggingService()
    }
    
    func analyze() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        lastError = nil
        availableTeams = []
        selectedTeams = []
        
        // Teams from For Upload subfolders
        let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
        guard FileManager.default.fileExists(atPath: forUpload.path) else { return }
        do {
            let subs = try FileManager.default.contentsOfDirectory(at: forUpload, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var teams: [String] = []
            for url in subs {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    teams.append(url.lastPathComponent)
                }
            }
            availableTeams = teams.sorted()
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func build() async {
        guard !selectedTeams.isEmpty else { lastError = "Select at least one team"; return }
        isProcessing = true
        defer { isProcessing = false }
        lastError = nil
        resultCSVURL = nil
        remakeRootURL = nil
        
        do {
            let result = try await rebuildService.buildSMOnly(jobFolder: jobFolder,
                                                              teams: Array(selectedTeams).sorted(),
                                                              globalSMFixTemplateName: globalSMFixTemplateName)
            resultCSVURL = result.csvURL
            remakeRootURL = result.remakeRoot
            lastFilesCopied = result.filesCopied
            lastFilesMoved = result.filesMoved
            lastCsvRows = result.csvRowCount
            lastTeamsWithNewPhotos = result.teamPhotosReplaced
            showSummary = true
            
            // Tag For Upload team folders red
            let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
            let urls = Array(selectedTeams).map { forUpload.appendingPathComponent($0) }
            taggingService.setRedTag(for: urls)
            
        } catch {
            lastError = error.localizedDescription
        }
    }
}


