import Foundation
import SwiftUI

// MARK: - File Management Protocol
protocol FileManagerProtocol {
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any]
}

// Extend FileManager to conform to our protocol
extension FileManager: FileManagerProtocol { }

// MARK: - CSV Service Protocol
protocol CSVServiceProtocol {
    func parseCSV(from url: URL) async throws -> CSVParseResult
    func parseCSV(from content: String, encoding: String.Encoding) throws -> CSVParseResult
    func writeCSV(_ rows: [[String]], to url: URL, encoding: String.Encoding) async throws
    func validateCSVFormat(_ url: URL) async throws -> CSVValidationResult
    func detectEncoding(for url: URL) throws -> String.Encoding
    func detectDelimiter(in content: String) -> String
}

// MARK: - Image Service Protocol
protocol ImageServiceProtocol {
    @MainActor func loadImage(from url: URL) async throws -> NSImage
    @MainActor func getThumbnail(for url: URL, size: CGSize) async throws -> NSImage
    @MainActor func getImageMetadata(from url: URL) async throws -> ImageMetadata
    func validateImage(at url: URL) async throws -> Bool
    func validateImages(at urls: [URL]) async throws -> [(URL, Bool)]  // ADD THIS LINE
    func getImageDimensions(from url: URL) throws -> CGSize
    func detectFaces(in image: NSImage) async -> [CGRect]
}

// MARK: - File Processing Service Protocol
protocol FileProcessingServiceProtocol {
    func processFiles<T>(_ files: [URL],
                        operation: @escaping (URL) async throws -> T,
                        progress: ((Double) -> Void)?) async throws -> [Result<T, Error>]
    
    func batchProcessFiles<T>(_ files: [URL],
                             batchSize: Int,
                             operation: @escaping ([URL]) async throws -> [T],
                             progress: ((Double) -> Void)?) async throws -> [Result<T, Error>]
    
    func cancel()  // ← ADD THIS LINE
    
    var maxConcurrency: Int { get set }
}

// MARK: - Validation Service Protocol
protocol ValidationServiceProtocol {
    @MainActor
    func preflightValidationForRename(jobFolder: URL,
                                      files: [URL],
                                      config: OperationConfig.RenameConfig,
                                      csvService: CSVServiceProtocol,
                                      imageService: ImageServiceProtocol,
                                      flagStore: IssueFlagStore?) async -> ValidationReport
}

// MARK: - Operation History Protocol
protocol OperationHistoryProtocol {
    func record(_ record: OperationHistory.OperationRecord)
    func getHistory() -> [OperationHistory.OperationRecord]
    func undo(operationId: UUID) async throws
}

// MARK: - Progress Reporting Protocol
protocol ProgressReporting {
    var progress: Double { get }
    var currentOperation: String { get }
    var isIndeterminate: Bool { get }
    func updateProgress(_ value: Double, operation: String)
}

// MARK: - Operation Executor Protocol
protocol OperationExecutorProtocol {
    associatedtype ConfigType
    associatedtype ResultType
    
    func execute(with config: ConfigType,
                 in jobFolder: URL,
                 progress: ((OperationProgress) -> Void)?) async throws -> ResultType
    func validate(config: ConfigType, in jobFolder: URL) async throws
    func cancel()
    var isCancelled: Bool { get }
}

// MARK: - Data Models for Protocols

struct CSVParseResult {
    let headers: [String]
    let rows: [[String]]
    let encoding: String.Encoding
    let delimiter: String
    let lineCount: Int
    let warnings: [String]
    
    var isEmpty: Bool {
        rows.isEmpty
    }
    
    var columnCount: Int {
        headers.count
    }
    
    func row(at index: Int) -> [String]? {
        guard index < rows.count else { return nil }
        return rows[index]
    }
    
    func column(named name: String) -> [String]? {
        guard let index = headers.firstIndex(of: name) else { return nil }
        return rows.compactMap { row in
            index < row.count ? row[index] : nil
        }
    }
}

struct CSVValidationResult {
    let isValid: Bool
    let errors: [CSVValidationError]
    let warnings: [String]
    let encoding: String.Encoding?
    let delimiter: String?
    let expectedColumns: Int?
    let actualColumns: Int?
    
    enum CSVValidationError: LocalizedError {
        case missingHeaders
        case inconsistentColumns(expected: Int, row: Int, actual: Int)
        case invalidEncoding
        case emptyFile
        case invalidDelimiter
        case tooManyColumns(count: Int, max: Int)
        
        var errorDescription: String? {
            switch self {
            case .missingHeaders:
                return "CSV file is missing headers"
            case .inconsistentColumns(let expected, let row, let actual):
                return "Row \(row) has \(actual) columns, expected \(expected)"
            case .invalidEncoding:
                return "Unable to detect file encoding"
            case .emptyFile:
                return "CSV file is empty"
            case .invalidDelimiter:
                return "Unable to detect delimiter"
            case .tooManyColumns(let count, let max):
                return "File has \(count) columns, maximum supported is \(max)"
            }
        }
    }
}

struct ImageMetadata {
    let dimensions: CGSize
    let fileSize: Int64
    let colorSpace: String?
    let dpi: Int?
    let creationDate: Date?
    let modificationDate: Date?
    let cameraModel: String?
    let orientation: Int?
    let hasAlpha: Bool
    let bitDepth: Int?
    let copyrightNotice: String?
    
    var aspectRatio: Double {
        guard dimensions.height > 0 else { return 0 }
        return dimensions.width / dimensions.height
    }
    
    var megapixels: Double {
        return (dimensions.width * dimensions.height) / 1_000_000
    }
}

// MARK: - Mock Implementations for Testing

#if DEBUG
class MockFileManager: FileManagerProtocol {
    var mockFiles: [URL] = []
    var shouldThrowError = false
    var fileExistsResult = true
    
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        if shouldThrowError {
            throw PhotoWorkflowError.folderNotFound(name: url.lastPathComponent)
        }
        return mockFiles
    }
    
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if let isDirectory = isDirectory {
            isDirectory.pointee = true
        }
        return fileExistsResult
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        if shouldThrowError {
            throw PhotoWorkflowError.unableToCreateFolder(path: url.path, underlyingError: nil)
        }
    }
    
    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldThrowError {
            throw PhotoWorkflowError.fileAlreadyExists(path: dstURL.path)
        }
    }
    
    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldThrowError {
            throw PhotoWorkflowError.fileAlreadyExists(path: dstURL.path)
        }
    }
    
    func removeItem(at url: URL) throws {
        if shouldThrowError {
            throw PhotoWorkflowError.fileNotFound(path: url.path)
        }
    }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any] {
        if shouldThrowError {
            throw PhotoWorkflowError.fileNotFound(path: path)
        }
        return [
            .size: 1024,
            .creationDate: Date(),
            .modificationDate: Date()
        ]
    }
}

class MockCSVService: CSVServiceProtocol {
    var mockResult: CSVParseResult?
    var shouldThrowError = false
    
    func parseCSV(from url: URL) async throws -> CSVParseResult {
        if shouldThrowError {
            throw PhotoWorkflowError.csvParsingError(line: 1, reason: "Mock error")
        }
        return mockResult ?? CSVParseResult(
            headers: ["First", "Last", "Team"],
            rows: [["John", "Doe", "Eagles"]],
            encoding: .utf8,
            delimiter: ",",
            lineCount: 2,
            warnings: []
        )
    }
    
    func parseCSV(from content: String, encoding: String.Encoding) throws -> CSVParseResult {
        return mockResult ?? CSVParseResult(
            headers: ["First", "Last", "Team"],
            rows: [],
            encoding: encoding,
            delimiter: ",",
            lineCount: 1,
            warnings: []
        )
    }
    
    func writeCSV(_ rows: [[String]], to url: URL, encoding: String.Encoding) async throws {
        if shouldThrowError {
            throw PhotoWorkflowError.unableToWriteFile(path: url.path, underlyingError: nil)
        }
    }
    
    func validateCSVFormat(_ url: URL) async throws -> CSVValidationResult {
        return CSVValidationResult(
            isValid: !shouldThrowError,
            errors: shouldThrowError ? [.missingHeaders] : [],
            warnings: [],
            encoding: .utf8,
            delimiter: ",",
            expectedColumns: 3,
            actualColumns: 3
        )
    }
    
    func detectEncoding(for url: URL) throws -> String.Encoding {
        return .utf8
    }
    
    func detectDelimiter(in content: String) -> String {
        return ","
    }
}
#endif
