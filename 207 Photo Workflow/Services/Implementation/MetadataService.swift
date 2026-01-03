import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Metadata Service
@MainActor
class MetadataService: ObservableObject {
    
    // MARK: - Public Methods
    
    /// Read copyright information from an image file
    func readCopyright(from url: URL) throws -> String? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.unableToReadFile
        }
        
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw MetadataError.noMetadata
        }
        
        // Check EXIF data for copyright
        if let exifData = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            // Try multiple possible copyright field names
            let copyrightKeys = ["Copyright", "UserComment", "ImageDescription"]
            for key in copyrightKeys {
                if let copyright = exifData[key] as? String, !copyright.isEmpty {
                    return copyright
                }
            }
        }
        
        // Check TIFF data for copyright (alternative location)
        if let tiffData = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let copyrightKeys = ["Copyright", "Artist", "ImageDescription"]
            for key in copyrightKeys {
                if let copyright = tiffData[key] as? String, !copyright.isEmpty {
                    return copyright
                }
            }
        }
        
        return nil
    }
    
    /// Write copyright information to an image file
    func writeCopyright(_ copyright: String, to url: URL) throws {
        // Create backup first
        let backupURL = createBackupURL(for: url)
        try FileManager.default.copyItem(at: url, to: backupURL)
        
        do {
            try performCopyrightWrite(copyright, to: url, backupURL: backupURL)
        } catch {
            // Restore from backup if write fails
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: backupURL, to: url)
            throw error
        }
        
        // Clean up backup on success
        try? FileManager.default.removeItem(at: backupURL)
    }
    
    /// Get basic image information
    func getImageInfo(from url: URL) throws -> ImageInfo {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.unableToReadFile
        }
        
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw MetadataError.noMetadata
        }
        
        let width = metadata[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = metadata[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let colorSpace = metadata[kCGImagePropertyColorModel as String] as? String ?? "Unknown"
        let dpi = metadata[kCGImagePropertyDPIWidth as String] as? Double ?? 0
        
        // Get file size
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        
        return ImageInfo(
            filename: url.lastPathComponent,
            width: width,
            height: height,
            colorSpace: colorSpace,
            dpi: dpi,
            fileSize: fileSize,
            copyright: try readCopyright(from: url)
        )
    }
    
    // MARK: - Private Methods
    
    private func performCopyrightWrite(_ copyright: String, to url: URL, backupURL: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.unableToReadFile
        }
        
        guard let imageType = CGImageSourceGetType(imageSource) else {
            throw MetadataError.unsupportedFormat
        }
        
        // Create destination for writing
        guard let imageDestination = CGImageDestinationCreateWithURL(url as CFURL, imageType, 1, nil) else {
            throw MetadataError.unableToCreateDestination
        }
        
        // Get existing metadata
        var metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]
        
        // Update EXIF copyright - write to multiple fields for maximum compatibility
        var exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exifDict["Copyright"] = copyright
        exifDict["UserComment"] = copyright  // Alternative field for copyright
        metadata[kCGImagePropertyExifDictionary as String] = exifDict
        
        // Also update TIFF copyright for broader compatibility
        var tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiffDict["Copyright"] = copyright
        tiffDict["Artist"] = copyright  // Some software uses Artist field for copyright
        metadata[kCGImagePropertyTIFFDictionary as String] = tiffDict
        
        // Get the image and add it to destination with updated metadata
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw MetadataError.unableToReadImage
        }
        
        CGImageDestinationAddImage(imageDestination, cgImage, metadata as CFDictionary)
        
        if !CGImageDestinationFinalize(imageDestination) {
            throw MetadataError.unableToWriteFile
        }
    }
    
    private func createBackupURL(for url: URL) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupName = "\(url.deletingPathExtension().lastPathComponent)_backup_\(timestamp).\(url.pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(backupName)
    }
}

// MARK: - Supporting Types

struct ImageInfo {
    let filename: String
    let width: Int
    let height: Int
    let colorSpace: String
    let dpi: Double
    let fileSize: Int64
    let copyright: String?
    
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var dimensions: String {
        "\(width) × \(height)"
    }
    
    var formattedDPI: String {
        dpi > 0 ? "\(Int(dpi)) DPI" : "Unknown DPI"
    }
}

enum MetadataError: LocalizedError {
    case unableToReadFile
    case unableToWriteFile
    case unableToReadImage
    case unableToCreateDestination
    case noMetadata
    case unsupportedFormat
    
    var errorDescription: String? {
        switch self {
        case .unableToReadFile:
            return "Unable to read image file"
        case .unableToWriteFile:
            return "Unable to write metadata to file"
        case .unableToReadImage:
            return "Unable to read image data"
        case .unableToCreateDestination:
            return "Unable to create destination for writing"
        case .noMetadata:
            return "No metadata found in image"
        case .unsupportedFormat:
            return "Unsupported image format"
        }
    }
}
