import Foundation

// MARK: - Template Enums
enum TemplateMode: String, CaseIterable, Identifiable {
    case sameForAll = "Same for All"
    case perTeam = "Per Team"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .sameForAll:
            return "Use the same templates for all teams"
        case .perTeam:
            return "Configure different templates for each team"
        }
    }
}

enum TemplateType: String, CaseIterable {
    case individual = "Individual"
    case sportsMate = "Sports Mate"
    
    var filenameSuffix: String {
        switch self {
        case .individual:
            return ""
        case .sportsMate:
            return Constants.FileNaming.sportsMatesSuffix
        }
    }
}

enum TemplatePickerType {
    case globalIndividual
    case globalSportsMate
    case teamIndividual(team: String)
    case teamSportsMate(team: String)
    
    var templateType: TemplateType {
        switch self {
        case .globalIndividual, .teamIndividual:
            return .individual
        case .globalSportsMate, .teamSportsMate:
            return .sportsMate
        }
    }
    
    var isGlobal: Bool {
        switch self {
        case .globalIndividual, .globalSportsMate:
            return true
        case .teamIndividual, .teamSportsMate:
            return false
        }
    }
    
    var teamName: String? {
        switch self {
        case .teamIndividual(let team), .teamSportsMate(let team):
            return team
        default:
            return nil
        }
    }
}

enum PoseMode: String, CaseIterable {
    case singlePose = "Single Pose"
    case multiPose = "Multi Pose"
    
    var description: String {
        switch self {
        case .singlePose:
            return "Template displays one pose"
        case .multiPose:
            return "Template combines two poses"
        }
    }
    
    var iconName: String {
        switch self {
        case .singlePose:
            return "photo"
        case .multiPose:
            return "photo.on.rectangle"
        }
    }
}

// MARK: - Template Info
struct TemplateInfo: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let poseMode: PoseMode
    let mainPose: String?
    let secondPose: String?
    
    var isValid: Bool {
        switch poseMode {
        case .singlePose:
            return true
        case .multiPose:
            return mainPose != nil && secondPose != nil && mainPose != secondPose
        }
    }
    
    var poseSummary: String {
        switch poseMode {
        case .singlePose:
            return "Single-pose template"
        case .multiPose:
            return "Multi-pose: Main(\(mainPose ?? "?")) → Second(\(secondPose ?? "?"))"
        }
    }
    
    var requiresPoses: Set<String> {
        switch poseMode {
        case .singlePose:
            return []
        case .multiPose:
            var poses = Set<String>()
            if let main = mainPose { poses.insert(main) }
            if let second = secondPose { poses.insert(second) }
            return poses
        }
    }
    
    static func == (lhs: TemplateInfo, rhs: TemplateInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Template Configuration
struct TemplateConfigModel: Identifiable {
    let id = UUID()
    let fileName: String
    var poseMode: PoseMode = .singlePose
    var mainPose: String = Constants.Validation.multiPoseMainDefault // retained for compatibility but unused
    var secondPose: String = Constants.Validation.multiPoseSecondDefault
    
    func toTemplateInfo() -> TemplateInfo {
        TemplateInfo(
            fileName: fileName,
            poseMode: poseMode,
            mainPose: poseMode == .multiPose ? mainPose : nil,
            secondPose: poseMode == .multiPose ? secondPose : nil
        )
    }
    
    var isValid: Bool {
        switch poseMode {
        case .singlePose:
            return true
        case .multiPose:
            return !mainPose.isEmpty &&
                   !secondPose.isEmpty &&
                   mainPose != secondPose &&
                   Int(mainPose) != nil &&
                   Int(secondPose) != nil
        }
    }
}

// MARK: - Team Template Configuration
struct TeamTemplateConfig {
    var individualTemplates: [TemplateInfo]
    var sportsMateTemplates: [TemplateInfo]
    
    var hasTemplates: Bool {
        !individualTemplates.isEmpty || !sportsMateTemplates.isEmpty
    }
    
    var totalTemplateCount: Int {
        individualTemplates.count + sportsMateTemplates.count
    }
    
    func templates(for type: TemplateType) -> [TemplateInfo] {
        switch type {
        case .individual:
            return individualTemplates
        case .sportsMate:
            return sportsMateTemplates
        }
    }
    
    mutating func addTemplate(_ template: TemplateInfo, type: TemplateType) {
        switch type {
        case .individual:
            individualTemplates.append(template)
        case .sportsMate:
            sportsMateTemplates.append(template)
        }
    }
    
    mutating func removeTemplate(_ template: TemplateInfo, type: TemplateType) {
        switch type {
        case .individual:
            individualTemplates.removeAll { $0.id == template.id }
        case .sportsMate:
            sportsMateTemplates.removeAll { $0.id == template.id }
        }
    }
    
    mutating func clearTemplates(type: TemplateType? = nil) {
        if let type = type {
            switch type {
            case .individual:
                individualTemplates = []
            case .sportsMate:
                sportsMateTemplates = []
            }
        } else {
            individualTemplates = []
            sportsMateTemplates = []
        }
    }
}

// MARK: - Template Assignment Result
struct TemplateAssignmentResult {
    let team: String
    let templateType: TemplateType
    let template: TemplateInfo
    let affectedPhotos: [PhotoRecord]
    
    var photoCount: Int {
        affectedPhotos.count
    }
}
