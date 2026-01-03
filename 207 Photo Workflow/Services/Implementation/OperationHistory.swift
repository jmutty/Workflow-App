import Foundation

// MARK: - Operation History with Basic Backup/Undo
class OperationHistory: OperationHistoryProtocol {
    enum ChangeMode: String, Codable, Equatable {
        case move
        case copy
    }
    
    struct FileChange: Codable, Equatable {
        let originalURL: URL
        let newURL: URL
        let mode: ChangeMode
    }
    
    struct OperationRecord: Identifiable, Codable, Equatable {
        let id: UUID
        let type: Operation
        let timestamp: Date
        let affectedFiles: [FileChange]
        let reversible: Bool
        let backupFolder: URL?
        
        enum CodingKeys: String, CodingKey {
            case id, type, timestamp, affectedFiles, reversible, backupFolder
        }
        
        init(id: UUID, type: Operation, timestamp: Date, affectedFiles: [FileChange], reversible: Bool, backupFolder: URL?) {
            self.id = id
            self.type = type
            self.timestamp = timestamp
            self.affectedFiles = affectedFiles
            self.reversible = reversible
            self.backupFolder = backupFolder
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            type = try container.decode(Operation.self, forKey: .type)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            affectedFiles = try container.decode([FileChange].self, forKey: .affectedFiles)
            reversible = try container.decode(Bool.self, forKey: .reversible)
            // backupFolder may be absent or invalid; decode if present
            backupFolder = try container.decodeIfPresent(URL.self, forKey: .backupFolder)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(affectedFiles, forKey: .affectedFiles)
            try container.encode(reversible, forKey: .reversible)
            try container.encodeIfPresent(backupFolder, forKey: .backupFolder)
        }
    }
    
    private var records: [OperationRecord] = []
    private let fileManager: FileManagerProtocol
    
    init(fileManager: FileManagerProtocol = FileManager.default) {
        self.fileManager = fileManager
    }
    
    func record(_ record: OperationRecord) {
        records.append(record)
        if records.count > 200 { records.removeFirst() }
    }
    
    func getHistory() -> [OperationRecord] {
        records.sorted { $0.timestamp > $1.timestamp }
    }
    
    func undo(operationId: UUID) async throws {
        guard let index = records.firstIndex(where: { $0.id == operationId }) else { return }
        let record = records[index]
        guard record.reversible else { return }
        
        // Undo changes respecting mode
        for change in record.affectedFiles {
            switch change.mode {
            case .move:
                // Move files back from newURL to originalURL
                if fileManager.fileExists(atPath: change.newURL.path, isDirectory: nil) {
                    // If destination exists, try to remove
                    if fileManager.fileExists(atPath: change.originalURL.path, isDirectory: nil) {
                        try fileManager.removeItem(at: change.originalURL)
                    }
                    try fileManager.moveItem(at: change.newURL, to: change.originalURL)
                }
            case .copy:
                // For copies, simply delete the copied file at newURL
                if fileManager.fileExists(atPath: change.newURL.path, isDirectory: nil) {
                    try fileManager.removeItem(at: change.newURL)
                }
            }
        }
        
        // If backup folder exists, optionally clean it up
        if let backup = record.backupFolder {
            try? fileManager.removeItem(at: backup)
        }
        
        records.remove(at: index)
    }
}


