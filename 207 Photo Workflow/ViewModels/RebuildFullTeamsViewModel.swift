import Foundation
import Combine
import SwiftUI

@MainActor
class RebuildFullTeamsViewModel: ObservableObject {
    // Config/state
    @Published var availableTeams: [String] = []
    @Published var selectedTeams: Set<String> = []
    @Published var useExtractedAsSource: Bool = true
    @Published var customSourceURL: URL?
    
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
    
    @Published var operationProgress: Double = 0
    @Published var currentOperation: String = ""
    
    private let jobFolder: URL
    private let fileManager: FileManagerProtocol
    private let rebuildService: RebuildService
    private var cancellables: Set<AnyCancellable> = []
    let templateBuilder: CreateSPACSVViewModel
    
    init(jobFolder: URL,
         fileManager: FileManagerProtocol = FileManager.default,
         rebuildService: RebuildService? = nil) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
        self.rebuildService = rebuildService ?? RebuildService()
        self.templateBuilder = CreateSPACSVViewModel(jobFolder: jobFolder, fileManager: fileManager)
    }
    
    func analyze() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        lastError = nil
        availableTeams = []
        selectedTeams = []
        
        // Prefer teams from existing SPA Ready.csv
        do {
            let csvURL = jobFolder.appendingPathComponent(Constants.CSV.spaReadyFileName)
            if FileManager.default.fileExists(atPath: csvURL.path) {
                let csv = try await CSVService().parseCSV(from: csvURL)
                if let teamCol = csv.headers.firstIndex(of: "TEAMNAME") {
                    let teams = Set(csv.rows.compactMap { row in
                        teamCol < row.count ? row[teamCol].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                    }.filter { !$0.isEmpty })
                    if !teams.isEmpty {
                        availableTeams = Array(teams).sorted()
                        return
                    }
                }
            }
        } catch {
            // Fall back to scanning files
        }
        
        // Fallback: scan Extracted and For Upload
        var teams = Set<String>()
        let extracted = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        if let en = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
            while let next = en.nextObject() as? URL {
                let name = (next.lastPathComponent as NSString).deletingPathExtension
                let parts = name.split(separator: "_").map(String.init)
                if let first = parts.first, !first.isEmpty { teams.insert(first) }
            }
        }
        let forUpload = jobFolder.appendingPathComponent(Constants.Folders.forUpload)
        if FileManager.default.fileExists(atPath: forUpload.path) {
            if let sub = try? FileManager.default.contentsOfDirectory(at: forUpload, includingPropertiesForKeys: nil) {
                for u in sub { teams.insert(u.lastPathComponent) }
            }
        }
        availableTeams = Array(teams).sorted()
    }
    
    func build() async {
        guard !selectedTeams.isEmpty else { lastError = "Select at least one team"; return }
        isProcessing = true
        defer { isProcessing = false }
        lastError = nil
        resultCSVURL = nil
        remakeRootURL = nil
        
        do {
            let source = useExtractedAsSource ? nil : customSourceURL
            let result = try await rebuildService.buildFullTeams(jobFolder: jobFolder,
                                                                 teams: Array(selectedTeams).sorted(),
                                                                 source: source)
            resultCSVURL = result.csvURL
            remakeRootURL = result.remakeRoot
            lastFilesCopied = result.filesCopied
            lastFilesMoved = result.filesMoved
            lastCsvRows = result.csvRowCount
            lastTeamsWithNewPhotos = result.teamPhotosReplaced
            showSummary = true
        } catch {
            lastError = error.localizedDescription
        }
    }
}


