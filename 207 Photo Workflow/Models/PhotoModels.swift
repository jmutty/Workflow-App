import Foundation

// MARK: - Photo Record
struct PhotoRecord: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let teamName: String
    let playerName: String
    let firstName: String
    let lastName: String
    let poseNumber: String
    let sourceURL: URL
    let isManual: Bool
    
    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
    
    var playerKey: String {
        "\(teamName)_\(playerName)"
    }
    
    var needsManualAssignment: Bool {
        isManual || teamName == "MANUAL"
    }
}

// MARK: - Team Files
struct TeamPoseFile: Identifiable {
    let id = UUID()
    let originalName: String
    let teamName: String
    let poseNumber: String
    let sourceURL: URL
    let destinationFolder: URL
    
    var destinationURL: URL {
        destinationFolder.appendingPathComponent(originalName)
    }
}

struct CoachFile: Identifiable {
    let id = UUID()
    let originalName: String
    let teamName: String
    let sourceURL: URL
    let destinationFolder: URL
    let destinationPath: String
    let newName: String?
    let isManager: Bool
    
    var finalName: String {
        newName ?? originalName
    }
    
    var destinationURL: URL {
        destinationFolder.appendingPathComponent(finalName)
    }
    
    var needsPrefix: Bool {
        !originalName.hasPrefix(Constants.FileNaming.teamPhotoPrefix)
    }
}

// MARK: - Rename Operation
struct RenameOperation: Identifiable, Equatable {
    let id = UUID()
    let originalName: String
    let newName: String
    let hasConflict: Bool
    let sourceURL: URL
    
    var conflictResolution: ConflictResolution?
    
    static func == (lhs: RenameOperation, rhs: RenameOperation) -> Bool {
        lhs.id == rhs.id
    }
    
    enum ConflictResolution {
        case skip
        case overwrite
        case addSuffix(String)
    }
    
    var finalName: String {
        switch conflictResolution {
        case .skip:
            return originalName
        case .overwrite:
            return newName
        case .addSuffix(let suffix):
            return appendSuffix(suffix, to: newName)
        case .none:
            return newName
        }
    }
    
    private func appendSuffix(_ suffix: String, to fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
    }
}

// MARK: - CSV Row
struct CSVRow: Identifiable {
    let id = UUID()
    let original: String
    let firstName: String
    let lastName: String
    let groupName: String
    let barcode: String?
    
    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
    
    var isValid: Bool {
        !original.isEmpty && !firstName.isEmpty && !groupName.isEmpty
    }
}

// MARK: - Validation Models
struct PoseCountValidation: Equatable {
    let expectedCount: Int
    let playersWithIssues: [(player: String, count: Int)]
    let totalPlayers: Int
    
    static func == (lhs: PoseCountValidation, rhs: PoseCountValidation) -> Bool {
        lhs.expectedCount == rhs.expectedCount &&
        lhs.totalPlayers == rhs.totalPlayers &&
        lhs.playersWithIssues.count == rhs.playersWithIssues.count
    }
    
    var hasIssues: Bool {
        !playersWithIssues.isEmpty
    }
    
    var issueCount: Int {
        playersWithIssues.count
    }
    
    var validPlayerCount: Int {
        totalPlayers - issueCount
    }
    
    func issueType(for count: Int) -> IssueType {
        if count < expectedCount {
            return .missing(expectedCount - count)
        } else if count > expectedCount {
            return .extra(count - expectedCount)
        } else {
            return .none
        }
    }
    
    enum IssueType {
        case missing(Int)
        case extra(Int)
        case none
        
        var description: String {
            switch self {
            case .missing(let count):
                return "Missing \(count)"
            case .extra(let count):
                return "Extra \(count)"
            case .none:
                return "OK"
            }
        }
        
        var severity: Severity {
            switch self {
            case .missing:
                return .high
            case .extra:
                return .medium
            case .none:
                return .none
            }
        }
        
        enum Severity {
            case high, medium, low, none
        }
    }
}

// MARK: - Team Photo Found (for sorting)
struct TeamPhotoFound: Identifiable {
    let id = UUID()
    let teamName: String
    let sourceURL: URL
    
    var fileName: String {
        sourceURL.lastPathComponent
    }
}

// MARK: - File Analysis Result
struct FileAnalysisResult {
    let totalFiles: Int
    let imageFiles: Int
    let csvFiles: Int
    let otherFiles: Int
    let teams: Set<String>
    let errors: [Error]
    
    var hasErrors: Bool {
        !errors.isEmpty
    }
    
    var teamCount: Int {
        teams.count
    }
}
