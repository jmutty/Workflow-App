import Foundation
import SwiftUI

// MARK: - Application Constants
struct Constants {
    
    // MARK: - File Extensions
    struct FileExtensions {
        static let supportedImages = ["jpg", "jpeg", "png", "tiff", "tif"]
        static let csv = "csv"
        static let allImages = Set(supportedImages)
        
        static func isImageFile(_ url: URL) -> Bool {
            allImages.contains(url.pathExtension.lowercased())
        }
    }
    
    // MARK: - Folder Names
    struct Folders {
        static let output = "Output"
        static let extracted = "Extracted"
        static let sortedTeams = "Sorted Teams"
        static let finishedTeams = "Finished Teams"
        static let buddyPhotos = "Buddy Photos"
        static let forUpload = "For Upload"
        static let capture = "Capture"
        static let seniorBanners = "Senior Banners"
        static let group = "group"
        static let requiredFolders = [output, extracted]
    }
    
    // MARK: - CSV Configuration
    struct CSV {
        static let headerCount = 41
        static let defaultEncoding = String.Encoding.utf8
        static let bomPrefix = "\u{FEFF}"
        static let minFieldCount = 8
        static let spaReadyFileName = "SPA Ready.csv"
        static let seniorBannersFileName = "Senior Banners.csv"
        
        static let header = "SPA,NAME,FIRSTNAME,LASTNAME,POSITION,NUMBER,TEAMNAME,LEAGUENAME,YEAR,SCHOOLNAME,CLASS,SPATEXT1,SPATEXT2,SPATEXT3,SPATEXT4,SPATEXT5,NEW FILE NAME,APPEND FILE NAME,SUB FOLDER,TEAM FILE,LOGO FILE,PLAYER 2 FILE,PLAYER 3 FILE,TEMPLATE FILE,HIDE LAYER 1,HIDE LAYER 2,HIDE LAYER 3,HIDE LAYER 4,HIDE LAYER 5,SHOW LAYER 1,SHOW LAYER 2,SHOW LAYER 3,SHOW LAYER 4,SHOW LAYER 5,PRE ACTION 1,PRE ACTION 2,PRE ACTION 3,POST ACTION 1,POST ACTION 2,POST ACTION 3"
        
        static let manualAssignmentMarkers = [
            "***NEEDS_NAME***",
            "***CHANGE***",
            "***ASSIGN_TEAM***"
        ]
    }
    
    // MARK: - UI Configuration
    struct UI {
        // Main window recommended/default size
        static let mainWindowWidth: CGFloat = 1100
        static let mainWindowHeight: CGFloat = 820
        static let minWindowWidth: CGFloat = 900
        static let minWindowHeight: CGFloat = 700
        static let animationDuration = 0.2
        static let defaultPadding: CGFloat = 20
        static let cornerRadius: CGFloat = 12
        static let buttonCornerRadius: CGFloat = 10
        
        // Operation window sizes
        static let renameWindowWidth: CGFloat = 800
        static let renameWindowHeight: CGFloat = 650
        static let sortWindowWidth: CGFloat = 750
        static let sortWindowHeight: CGFloat = 650
        static let csvWindowWidth: CGFloat = 800
        static let csvWindowHeight: CGFloat = 700
        static let templateWindowWidth: CGFloat = 700
        static let templateWindowHeight: CGFloat = 600
        
        // Icon sizes
        static let largeIconSize: CGFloat = 36
        static let mediumIconSize: CGFloat = 24
        static let smallIconSize: CGFloat = 18
    }
    
    // MARK: - Validation Rules
    struct Validation {
        static let minTeamNameLength = 1
        static let maxFileNameLength = 255
        static let defaultPoseNumber = "1"
        static let multiPoseMainDefault = "2"
        static let multiPoseSecondDefault = "3"
        
        // Patterns to exclude from player names
        static let excludePatterns = [
            "COACH",
            "TEAM",
            "GROUP",
            "IMG_",
            "DSC_",
            "PHOTO_"
        ]
    }
    
    // MARK: - Operation Configuration
    struct Operations {
        static let maxConcurrentFileOperations = 4
        static let fileOperationBatchSize = 100
        static let progressUpdateInterval: TimeInterval = 0.1
    }
    
    // MARK: - File Naming
    struct FileNaming {
        static let teamPhotoPrefix = "TOP "
        static let conflictSuffixFormat = " (%d)"
        static let poseSeparator = "_"
        static let nameSeparator = " "
        static let sportsMatesSuffix = "_MM"
        static let buddyPoseStart = 300
    }
    
    // MARK: - Colors (moved from extension)
    struct Colors {
        // Semantic tokens backed by asset catalog colors (dynamic Any/Dark)
        static let background = Color("Background")
        static let surface = Color("Surface")
        static let surfaceElevated = Color("SurfaceElevated")
        static let border = Color("Border")
        static let textPrimary = Color("TextPrimary")
        static let textSecondary = Color("TextSecondary")
        static let brandTint = Color("BrandTint")
        static let brandHover = Color("BrandTintHover")
        static let brandPressed = Color("BrandTintPressed")
        static let brandSoftFill = Color("BrandSoftFill")
        static let focusRing = Color("FocusRing")
        static let successGreen = Color(red: 0.20, green: 0.70, blue: 0.35)
        static let warningOrange = Color(red: 1.0, green: 0.6, blue: 0.2)
        static let errorRed = Color(red: 0.92, green: 0.25, blue: 0.25)
        // For legacy code that still references card* names
        static let cardBackground = surface
        static let cardBorder = border
    }
    
    // MARK: - Rebuild
    struct Rebuild {
        static let remakeFolderPrefix = "Remake - "
        static let csvRemakePrefix = "SPA Ready CSV - Remake - "
        static let csvSMRemakePrefix = "SPA Ready CSV - SM Remake - "
    }
}

// MARK: - Type Aliases for Clarity
typealias ImageFileURL = URL
typealias TeamName = String
typealias PlayerName = String
typealias PoseNumber = String
typealias FileName = String
