import Foundation
import Combine

@MainActor
class SchoolBatchViewModel: ObservableObject {
    struct BatchResult: Equatable {
        let csvURL: URL
        let rowCount: Int
        let totalImages: Int
        let imagesCopied: Int
        let imagesRenamedOnConflict: Int
        let duration: TimeInterval
    }
    // Inputs
    @Published var schoolName: String = ""
    @Published var schoolNameLine2: String = ""
    @Published var year: String = ""
    
    // VOL folders
    @Published var volFolders: [URL] = []
    @Published var selectedVOL: URL?
    
    // State
    @Published var isRunning: Bool = false
    @Published var progressMessage: String = ""
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var lastResult: BatchResult?
    
    private let jobFolder: URL
    private let service: SchoolBatchService
    
    init(jobFolder: URL,
         service: SchoolBatchService = SchoolBatchService()) {
        self.jobFolder = jobFolder
        self.service = service
    }
    
    func loadVOLFolders() {
        volFolders = service.findVOLFolders(in: jobFolder)
        if volFolders.count == 1 { selectedVOL = volFolders.first }
    }
    
    func run() async {
        errorMessage = nil
        successMessage = nil
        lastResult = nil
        guard !schoolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Enter School Name"; return }
        guard !schoolNameLine2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Enter School Name Line 2"; return }
        guard !year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Enter Year"; return }
        guard let vol = selectedVOL ?? volFolders.first else { errorMessage = "No VOL* folder found"; return }
        
        isRunning = true
        progressMessage = "Scanning folders..."
        let start = Date()
        
        let built = service.buildRows(volURL: vol, year: year, schoolName: schoolName, groupText1: schoolNameLine2)
        let rows = built.rows
        let images = built.imageFiles
        
        progressMessage = "Writing CSV..."
        do {
            let csvURL = try await service.writeCSV(to: vol, rows: rows)
            progressMessage = "Copying images..."
            let stats = try service.copyImagesToVOL(volURL: vol, rows: rows, sources: images)
            let duration = Date().timeIntervalSince(start)
            lastResult = BatchResult(csvURL: csvURL,
                                     rowCount: rows.count,
                                     totalImages: stats.totalSources,
                                     imagesCopied: stats.copied,
                                     imagesRenamedOnConflict: stats.renamedOnConflict,
                                     duration: duration)
        } catch {
            isRunning = false
            errorMessage = "Failed to write CSV: \(error.localizedDescription)"
            return
        }
        
        isRunning = false
        progressMessage = ""
        if let r = lastResult {
            successMessage = "Created CSV (\(r.rowCount) rows) and copied \(r.imagesCopied)/\(r.totalImages) images to \(vol.lastPathComponent)."
        } else {
            successMessage = "CSV generated and images copied to \(vol.lastPathComponent)"
        }
    }
}


