import Foundation
import Combine
import AppKit

@MainActor
class AdminRatingViewModel: ObservableObject {
    // MARK: - Inputs
    let jobFolder: URL
    private let fileManager: FileManagerProtocol
    private let imageService: ImageServiceProtocol
    private let compositeService: RatingCompositeService
    
    // MARK: - UI State
    @Published var selectedMode: AdminModeType = .sports
    @Published var isSampling: Bool = false
    @Published var isStarted: Bool = false
    @Published var statusMessage: String = ""
    
    // Images
    @Published var copiedSampleURLs: [URL] = []
    @Published var currentIndex: Int = 0
    @Published var currentImage: NSImage? = nil
    
    // Ratings
    @Published var entries: [RatingEntry] = []
    
    init(jobFolder: URL,
         fileManager: FileManagerProtocol = FileManager.default,
         imageService: ImageServiceProtocol = ImageService(),
         compositeService: RatingCompositeService = RatingCompositeService()) {
        self.jobFolder = jobFolder
        self.fileManager = fileManager
        self.imageService = imageService
        self.compositeService = compositeService
    }
    
    // MARK: - Actions
    func start() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        statusMessage = "Sampling images..."
        do {
            let captureURL = jobFolder.appendingPathComponent(Constants.Folders.capture)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: captureURL.path, isDirectory: &isDir), isDir.boolValue else {
                statusMessage = "Missing 'capture' folder"
                return
            }
            let jobRatingURL = captureURL.appendingPathComponent("Job Rating")
            if !FileManager.default.fileExists(atPath: jobRatingURL.path) {
                try fileManager.createDirectory(at: jobRatingURL, withIntermediateDirectories: true, attributes: nil)
            }
            // Discover image files recursively under capture, excluding Job Rating
            let discovered = try await discoverImages(in: captureURL, excludingFolderNamed: "Job Rating")
            let sample = Array(discovered.shuffled().prefix(5))
            guard !sample.isEmpty else {
                statusMessage = "No images found in capture"
                return
            }
            // Copy to Job Rating
            var copied: [URL] = []
            for src in sample {
                let dest = jobRatingURL.appendingPathComponent(src.lastPathComponent)
                let finalDest = try uniqueURL(for: dest)
                try fileManager.copyItem(at: src, to: finalDest)
                copied.append(finalDest)
            }
            copiedSampleURLs = copied
            currentIndex = 0
            await loadCurrentImage()
            entries = defaultEntries(for: selectedMode)
            isStarted = true
            statusMessage = "Loaded \(copied.count) images"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func saveRatedJPG() async {
        guard let url = currentURL else { return }
        do {
            let nsImage = try await imageService.loadImage(from: url)
            let rating = ImageRating(
                imageURL: url,
                mode: selectedMode,
                entries: entries,
                overallScore: nil
            )
            let composite = try compositeService.renderComposite(original: nsImage, rating: rating, fileName: url.lastPathComponent)
            let ratedURL = try ratedOutputURL(for: url)
            try compositeService.writeJPEG(composite, to: ratedURL)
            // Delete original from Job Rating folder after successful save
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // Non-fatal: keep going if deletion fails
            }
            // Swap current entry to the saved composite path and update preview
            if currentIndex >= 0 && currentIndex < copiedSampleURLs.count {
                copiedSampleURLs[currentIndex] = ratedURL
            }
            currentImage = composite
            statusMessage = "Saved: \(ratedURL.lastPathComponent) (original removed)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
    
    func next() async {
        guard currentIndex + 1 < copiedSampleURLs.count else { return }
        currentIndex += 1
        entries = defaultEntries(for: selectedMode)
        await loadCurrentImage()
    }
    
    func back() async {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        entries = defaultEntries(for: selectedMode)
        await loadCurrentImage()
    }
    
    // MARK: - Helpers
    var currentURL: URL? {
        guard currentIndex >= 0, currentIndex < copiedSampleURLs.count else { return nil }
        return copiedSampleURLs[currentIndex]
    }
    
    private func loadCurrentImage() async {
        if let url = currentURL {
            do {
                currentImage = try await imageService.loadImage(from: url)
            } catch {
                currentImage = nil
            }
        } else {
            currentImage = nil
        }
    }
    
    private func defaultEntries(for mode: AdminModeType) -> [RatingEntry] {
        let categories: [RatingCategory] = (mode == .sports) ? RatingPresets.sportsCategories : RatingPresets.schoolCategories
        return categories.map { RatingEntry(categoryName: $0.name, score: nil, notes: "") }
    }
    
    private func discoverImages(in folder: URL, excludingFolderNamed excluded: String) async throws -> [URL] {
        var results: [URL] = []
        try await discoverRecursive(folder, excluded: excluded, results: &results)
        return results
    }
    
    private func discoverRecursive(_ folder: URL, excluded: String, results: inout [URL]) async throws {
        let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for url in contents {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, isDir.boolValue {
                if url.lastPathComponent == excluded { continue }
                try await discoverRecursive(url, excluded: excluded, results: &results)
            } else {
                if Constants.FileExtensions.isImageFile(url) {
                    results.append(url)
                }
            }
        }
    }
    
    private func uniqueURL(for destination: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: destination.path) { return destination }
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let dir = destination.deletingLastPathComponent()
        var idx = 1
        while true {
            let candidate = dir.appendingPathComponent("\(base)\(String(format: Constants.FileNaming.conflictSuffixFormat, idx))").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            idx += 1
        }
    }
    
    private func ratedOutputURL(for originalInJobRating: URL) throws -> URL {
        let dir = originalInJobRating.deletingLastPathComponent()
        let base = originalInJobRating.deletingPathExtension().lastPathComponent + "_RATED"
        let ext = "jpg"
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)\(String(format: Constants.FileNaming.conflictSuffixFormat, idx))").appendingPathExtension(ext)
            idx += 1
        }
        return candidate
    }
}


