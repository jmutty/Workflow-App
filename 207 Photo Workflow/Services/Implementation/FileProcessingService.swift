import Foundation
import AppKit
import SwiftUI

// MARK: - File Processing Service Implementation ONLY
// (Protocols are in Protocols.swift, not here!)

actor FileProcessingService: FileProcessingServiceProtocol {
    
    // MARK: - Properties
    nonisolated var maxConcurrency: Int {
        get { Constants.Operations.maxConcurrentFileOperations }
        set { } // Setter does nothing, but satisfies protocol
    }
    
    private var currentProgress: Double = 0
    private var isCancelled = false
    
    // MARK: - Public Methods
    
    func processFiles<T>(_ files: [URL],
                        operation: @escaping (URL) async throws -> T,
                        progress: ((Double) -> Void)?) async throws -> [Result<T, Error>] {
        
        guard !files.isEmpty else { return [] }
        
        // Reset state
        currentProgress = 0
        isCancelled = false
        
        let totalFiles = files.count
        var processedCount = 0
        
        // Process files with limited concurrency
        return try await withThrowingTaskGroup(of: (Int, Result<T, Error>).self) { group in
            // Add initial batch of tasks
            for (index, file) in files.enumerated().prefix(maxConcurrency) {
                group.addTask { [weak self] in
                    if await self?.checkCancellation() ?? false {
                        return (index, .failure(PhotoWorkflowError.operationCancelled))
                    }
                    
                    do {
                        let result = try await operation(file)
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            
            var nextIndex = maxConcurrency
            var indexedResults: [(Int, Result<T, Error>)] = []
            
            // Process results and add new tasks
            for try await (index, result) in group {
                indexedResults.append((index, result))
                processedCount += 1
                
                // Update progress
                let newProgress = Double(processedCount) / Double(totalFiles)
                await updateProgress(newProgress, callback: progress)
                
                // Add next task if available
                if nextIndex < files.count && !isCancelled {
                    let fileIndex = nextIndex
                    nextIndex += 1
                    
                    group.addTask { [weak self] in
                        if await self?.checkCancellation() ?? false {
                            return (fileIndex, .failure(PhotoWorkflowError.operationCancelled))
                        }
                        
                        do {
                            let result = try await operation(files[fileIndex])
                            return (fileIndex, .success(result))
                        } catch {
                            return (fileIndex, .failure(error))
                        }
                    }
                }
            }
            
            // Sort results by original index
            indexedResults.sort { $0.0 < $1.0 }
            return indexedResults.map { $0.1 }
        }
    }
    
    func batchProcessFiles<T>(_ files: [URL],
                             batchSize: Int,
                             operation: @escaping ([URL]) async throws -> [T],
                             progress: ((Double) -> Void)?) async throws -> [Result<T, Error>] {
        
        guard !files.isEmpty else { return [] }
        
        // Reset state
        currentProgress = 0
        isCancelled = false
        
        // Create batches
        let batches = files.chunked(into: batchSize)
        let totalBatches = batches.count
        var processedBatches = 0
        
        return try await withThrowingTaskGroup(of: [Result<T, Error>].self) { group in
            var allResults: [Result<T, Error>] = []
            
            // Process batches with limited concurrency
            for batch in batches.prefix(maxConcurrency) {
                group.addTask { [weak self] in
                    if await self?.checkCancellation() ?? false {
                        return batch.map { _ in Result<T, Error>.failure(PhotoWorkflowError.operationCancelled) }
                    }
                    
                    do {
                        let results = try await operation(batch)
                        return results.map { .success($0) }
                    } catch {
                        return batch.map { _ in Result<T, Error>.failure(error) }
                    }
                }
            }
            
            var nextBatchIndex = maxConcurrency
            
            // Process results and add new batches
            for try await batchResults in group {
                allResults.append(contentsOf: batchResults)
                processedBatches += 1
                
                // Update progress
                let newProgress = Double(processedBatches) / Double(totalBatches)
                await updateProgress(newProgress, callback: progress)
                
                // Add next batch if available
                if nextBatchIndex < batches.count && !isCancelled {
                    let batch = batches[nextBatchIndex]
                    nextBatchIndex += 1
                    
                    group.addTask { [weak self] in
                        if await self?.checkCancellation() ?? false {
                            return batch.map { _ in Result<T, Error>.failure(PhotoWorkflowError.operationCancelled) }
                        }
                        
                        do {
                            let results = try await operation(batch)
                            return results.map { .success($0) }
                        } catch {
                            return batch.map { _ in Result<T, Error>.failure(error) }
                        }
                    }
                }
            }
            
            return allResults
        }
    }
    
    nonisolated func cancel() {
        Task {
            await setCancelled()
        }
    }

    private func setCancelled() {
        isCancelled = true
    }
    
    // MARK: - Private Methods
    
    private func checkCancellation() -> Bool {
        return isCancelled
    }
    
    private func updateProgress(_ value: Double, callback: ((Double) -> Void)?) async {
        currentProgress = value
        
        // Call progress callback on main thread
        if let callback = callback {
            await MainActor.run {
                callback(value)
            }
        }
    }
}

// MARK: - Array Extension for Chunking
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Progress Tracker
class ProgressTracker: ProgressReporting {
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentOperation: String = ""
    @Published private(set) var isIndeterminate: Bool = false
    
    private let queue = DispatchQueue(label: "com.photoworkflow.progress")
    
    func updateProgress(_ value: Double, operation: String) {
        queue.async { [weak self] in
            DispatchQueue.main.async {
                self?.progress = value
                self?.currentOperation = operation
            }
        }
    }
    
    func setIndeterminate(_ indeterminate: Bool) {
        queue.async { [weak self] in
            DispatchQueue.main.async {
                self?.isIndeterminate = indeterminate
            }
        }
    }
    
    func reset() {
        queue.async { [weak self] in
            DispatchQueue.main.async {
                self?.progress = 0
                self?.currentOperation = ""
                self?.isIndeterminate = false
            }
        }
    }
}

// MARK: - Batch Operation Result
struct BatchOperationResult<T> {
    let successful: [T]
    let failed: [(URL, Error)]
    let totalProcessed: Int
    let duration: TimeInterval
    
    var successRate: Double {
        guard totalProcessed > 0 else { return 0 }
        return Double(successful.count) / Double(totalProcessed)
    }
    
    var hasErrors: Bool {
        !failed.isEmpty
    }
    
    func summary() -> String {
        let successCount = successful.count
        let failureCount = failed.count
        let rate = String(format: "%.1f%%", successRate * 100)
        
        return """
        Processed: \(totalProcessed) files
        Successful: \(successCount)
        Failed: \(failureCount)
        Success Rate: \(rate)
        Duration: \(String(format: "%.2f", duration)) seconds
        """
    }
}

// MARK: - File Operation Extensions
extension FileProcessingService {
    
    /// Process image files specifically with optimizations
    func processImageFiles(_ files: [URL],
                          operation: @escaping (NSImage, URL) async throws -> Void,
                          progress: ((Double) -> Void)?) async throws -> BatchOperationResult<URL> {
        
        let startTime = Date()
        var successful: [URL] = []
        var failed: [(URL, Error)] = []
        
        let results = try await processFiles(files, operation: { url in
            // Load image
            guard let image = NSImage(contentsOf: url) else {
                throw PhotoWorkflowError.invalidImageFormat(fileName: url.lastPathComponent)
            }
            
            // Process image
            try await operation(image, url)
            return url
        }, progress: progress)
        
        // Collect results
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let url):
                successful.append(url)
            case .failure(let error):
                failed.append((files[index], error))
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return BatchOperationResult(
            successful: successful,
            failed: failed,
            totalProcessed: files.count,
            duration: duration
        )
    }
    
    /// Copy files with progress tracking
    func copyFiles(from sources: [URL],
                   to destination: URL,
                   overwrite: Bool = false,
                   progress: ((Double) -> Void)?) async throws -> BatchOperationResult<URL> {
        
        let fileManager = FileManager.default
        let startTime = Date()
        var successful: [URL] = []
        var failed: [(URL, Error)] = []
        
        let results = try await processFiles(sources, operation: { sourceURL in
            let destinationURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            
            // Check if file exists
            if fileManager.fileExists(atPath: destinationURL.path) {
                if overwrite {
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    throw PhotoWorkflowError.fileAlreadyExists(path: destinationURL.path)
                }
            }
            
            // Copy file
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }, progress: progress)
        
        // Collect results
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let url):
                successful.append(url)
            case .failure(let error):
                failed.append((sources[index], error))
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return BatchOperationResult(
            successful: successful,
            failed: failed,
            totalProcessed: sources.count,
            duration: duration
        )
    }
    
    /// Move files with progress tracking
    func moveFiles(from sources: [URL],
                   to destination: URL,
                   overwrite: Bool = false,
                   progress: ((Double) -> Void)?) async throws -> BatchOperationResult<URL> {
        
        let fileManager = FileManager.default
        let startTime = Date()
        var successful: [URL] = []
        var failed: [(URL, Error)] = []
        
        let results = try await processFiles(sources, operation: { sourceURL in
            let destinationURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            
            // Check if file exists
            if fileManager.fileExists(atPath: destinationURL.path) {
                if overwrite {
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    throw PhotoWorkflowError.fileAlreadyExists(path: destinationURL.path)
                }
            }
            
            // Move file
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }, progress: progress)
        
        // Collect results
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let url):
                successful.append(url)
            case .failure(let error):
                failed.append((sources[index], error))
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return BatchOperationResult(
            successful: successful,
            failed: failed,
            totalProcessed: sources.count,
            duration: duration
        )
    }
}
