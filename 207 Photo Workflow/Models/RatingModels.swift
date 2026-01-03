import Foundation

// MARK: - Admin Rating Models

enum AdminModeType: String, CaseIterable, Codable, Identifiable {
    case sports
    case school
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sports: return "Sports"
        case .school: return "School"
        }
    }
}

struct RatingCategory: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let criteria: String
    
    init(id: UUID = UUID(), name: String, criteria: String) {
        self.id = id
        self.name = name
        self.criteria = criteria
    }
}

struct RatingEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let categoryName: String
    var score: Int? // 1-5
    var notes: String
    
    init(id: UUID = UUID(), categoryName: String, score: Int? = nil, notes: String) {
        self.id = id
        self.categoryName = categoryName
        self.score = score
        self.notes = notes
    }
}

struct ImageRating: Identifiable, Codable, Equatable {
    let id: UUID
    let imageURL: URL
    let mode: AdminModeType
    var entries: [RatingEntry]
    var overallScore: Int?
    
    init(id: UUID = UUID(), imageURL: URL, mode: AdminModeType, entries: [RatingEntry], overallScore: Int?) {
        self.id = id
        self.imageURL = imageURL
        self.mode = mode
        self.entries = entries
        self.overallScore = overallScore
    }
}

enum RatingPresets {
    static let sportsCategories: [RatingCategory] = [
        RatingCategory(
            name: "Pose & Body Positioning",
            criteria: "Shoulders level, chin level, good posture, natural hand placement, tidy uniform, props positioned correctly."
        ),
        RatingCategory(
            name: "Expression & Eye Contact",
            criteria: "Confident expression, strong eye contact, relaxed mouth, no mid-blink, believable energy. Expression matches the sport."
        ),
        RatingCategory(
            name: "Lighting & Exposure",
            criteria: "Even exposure, soft but directional light, rim balanced, no hotspots or color cast. Exposure and white balance match the rest of the session."
        ),
        RatingCategory(
            name: "Framing & Cropping",
            criteria: "Framed straight in camera, centered, no clipped edges."
        ),
        RatingCategory(
            name: "Sharpness & Focus",
            criteria: "Eyes tack-sharp, appropriate depth of field, no blur, natural skin tone detail."
        ),
        RatingCategory(
            name: "Wardrobe & Grooming",
            criteria: "Neat hair, hat straight, visible logos/numbers, no wrinkles or stains, consistent team look."
        )
    ]

    static let schoolCategories: [RatingCategory] = [
        RatingCategory(
            name: "Posture & Alignment",
            criteria: "Shoulders slightly turned, chin down, spine straight, relaxed posture."
        ),
        RatingCategory(
            name: "Expression & Eye Contact",
            criteria: "Natural, genuine smile, eyes open and bright, comfortable gaze toward camera."
        ),
        RatingCategory(
            name: "Lighting & Exposure",
            criteria: "Soft, even light; correct white balance and exposure. Exposure and white balance consistent across all students."
        ),
        RatingCategory(
            name: "Framing & Cropping",
            criteria: "Eyes in top third, enough headroom, centered subject, cropped wide enough for auto cropping and off center crop."
        ),
        RatingCategory(
            name: "Sharpness & Detail",
            criteria: "Eyes tack-sharp, natural texture, minimal noise."
        ),
        RatingCategory(
            name: "Wardrobe & Grooming",
            criteria: "Straight collars, hair neat, face clean, minimal glare on glasses, neat clothing, clean overall presentation."
        )
    ]
}


