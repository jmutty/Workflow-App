import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image Service Implementation
class ImageService: ImageServiceProtocol {
    
    // MARK: - Properties
    private let thumbnailCache = NSCache<NSURL, NSImage>()
    private let metadataCache = NSCache<NSURL, NSData>()
    
    init() {
        // Configure cache limits
        thumbnailCache.countLimit = 100
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }
    
    // MARK: - Public Methods
    
    func loadImage(from url: URL) async throws -> NSImage {
        // Try to load image
        guard let image = NSImage(contentsOf: url) else {
            throw PhotoWorkflowError.invalidImageFormat(fileName: url.lastPathComponent)
        }
        
        // Validate image has representations
        guard !image.representations.isEmpty else {
            throw PhotoWorkflowError.corruptedImage(fileName: url.lastPathComponent)
        }
        
        return image
    }
    
    func getThumbnail(for url: URL, size: CGSize) async throws -> NSImage {
        // Check cache first
        let cacheKey = NSURL(fileURLWithPath: "\(url.path)_\(size.width)x\(size.height)")
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Generate thumbnail
        let thumbnail = try await generateThumbnail(from: url, targetSize: size)
        
        // Cache it
        let cost = Int(size.width * size.height * 4) // Approximate memory cost
        thumbnailCache.setObject(thumbnail, forKey: cacheKey, cost: cost)
        
        return thumbnail
    }
    
    func getImageMetadata(from url: URL) async throws -> ImageMetadata {
        // Check cache first
        let cacheKey = url as NSURL
        if let cachedData = metadataCache.object(forKey: cacheKey),
           let metadata = try? JSONDecoder().decode(ImageMetadata.self, from: cachedData as Data) {
            return metadata
        }
        
        // Extract metadata
        let metadata = try extractMetadata(from: url)
        
        // Cache it
        if let data = try? JSONEncoder().encode(metadata) {
            metadataCache.setObject(data as NSData, forKey: cacheKey)
        }
        
        return metadata
    }
    
    func validateImage(at url: URL) async throws -> Bool {
        do {
            // Try to create image source
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return false
            }
            
            // Check if we can get image properties
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                return false
            }
            
            // Check for required properties
            guard let _ = properties[kCGImagePropertyPixelWidth] as? Int,
                  let _ = properties[kCGImagePropertyPixelHeight] as? Int else {
                return false
            }
            
            // Check file type is supported
            guard let uti = CGImageSourceGetType(imageSource) as String? else {
                return false
            }
            
            let supportedTypes = [
                UTType.jpeg.identifier,
                UTType.png.identifier,
                UTType.tiff.identifier,
                UTType.heic.identifier,
                UTType.heif.identifier
            ]
            
            return supportedTypes.contains(uti)
            
        } catch {
            return false
        }
    }
    
    func getImageDimensions(from url: URL) throws -> CGSize {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoWorkflowError.invalidImageFormat(fileName: url.lastPathComponent)
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            throw PhotoWorkflowError.corruptedImage(fileName: url.lastPathComponent)
        }
        
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PhotoWorkflowError.corruptedImage(fileName: url.lastPathComponent)
        }
        
        return CGSize(width: width, height: height)
    }
    
    // MARK: - Private Methods
    
    private func generateThumbnail(from url: URL, targetSize: CGSize) async throws -> NSImage {
        return try await Task.detached(priority: .userInitiated) {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw PhotoWorkflowError.invalidImageFormat(fileName: url.lastPathComponent)
            }
            
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw PhotoWorkflowError.corruptedImage(fileName: url.lastPathComponent)
            }
            
            return NSImage(cgImage: thumbnail, size: targetSize)
        }.value
    }
    
    private func extractMetadata(from url: URL) throws -> ImageMetadata {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoWorkflowError.invalidImageFormat(fileName: url.lastPathComponent)
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            throw PhotoWorkflowError.corruptedImage(fileName: url.lastPathComponent)
        }
        
        // Get basic properties
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        
        // Get file attributes
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let creationDate = attributes[.creationDate] as? Date
        let modificationDate = attributes[.modificationDate] as? Date
        
        // Extract EXIF data if available
        let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        
        // Get color space
        let colorSpace = properties[kCGImagePropertyColorModel] as? String
        
        // Get DPI
        let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Int
        let dpiHeight = properties[kCGImagePropertyDPIHeight] as? Int
        let dpi = dpiWidth ?? dpiHeight
        
        // Get camera info from EXIF
        let cameraModel = tiffDict?[kCGImagePropertyTIFFModel] as? String
        
        // Get orientation
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        
        // Check for alpha channel
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        
        // Get bit depth
        let bitDepth = properties[kCGImagePropertyDepth] as? Int
        
        return ImageMetadata(
            dimensions: CGSize(width: width, height: height),
            fileSize: fileSize,
            colorSpace: colorSpace,
            dpi: dpi,
            creationDate: creationDate,
            modificationDate: modificationDate,
            cameraModel: cameraModel,
            orientation: orientation,
            hasAlpha: hasAlpha,
            bitDepth: bitDepth
        )
    }
    
    // MARK: - Batch Operations
    
    func validateImages(at urls: [URL]) async throws -> [(URL, Bool)] {
        var results: [(URL, Bool)] = []
        
        await withTaskGroup(of: (URL, Bool).self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    let isValid = (try? await self?.validateImage(at: url)) ?? false
                    return (url, isValid)
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        return results
    }
    
    func generateThumbnails(for urls: [URL], size: CGSize) async throws -> [URL: NSImage] {
        var thumbnails: [URL: NSImage] = [:]
        
        try await withThrowingTaskGroup(of: (URL, NSImage).self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self = self else {
                        throw PhotoWorkflowError.operationCancelled
                    }
                    let thumbnail = try await self.getThumbnail(for: url, size: size)
                    return (url, thumbnail)
                }
            }
            
            for try await (url, thumbnail) in group {
                thumbnails[url] = thumbnail
            }
        }
        
        return thumbnails
    }
    
    // MARK: - Cache Management
    
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }
    
    func clearMetadataCache() {
        metadataCache.removeAllObjects()
    }
    
    func clearAllCaches() {
        clearThumbnailCache()
        clearMetadataCache()
    }
}

// MARK: - ImageMetadata Codable Extension
extension ImageMetadata: Codable {
    enum CodingKeys: String, CodingKey {
        case dimensions, fileSize, colorSpace, dpi
        case creationDate, modificationDate, cameraModel
        case orientation, hasAlpha, bitDepth
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode dimensions
        let dimensionsDict = try container.decode([String: Double].self, forKey: .dimensions)
        dimensions = CGSize(
            width: dimensionsDict["width"] ?? 0,
            height: dimensionsDict["height"] ?? 0
        )
        
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        dpi = try container.decodeIfPresent(Int.self, forKey: .dpi)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        cameraModel = try container.decodeIfPresent(String.self, forKey: .cameraModel)
        orientation = try container.decodeIfPresent(Int.self, forKey: .orientation)
        hasAlpha = try container.decode(Bool.self, forKey: .hasAlpha)
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Encode dimensions as dictionary
        let dimensionsDict = ["width": dimensions.width, "height": dimensions.height]
        try container.encode(dimensionsDict, forKey: .dimensions)
        
        try container.encode(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(colorSpace, forKey: .colorSpace)
        try container.encodeIfPresent(dpi, forKey: .dpi)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try container.encodeIfPresent(orientation, forKey: .orientation)
        try container.encode(hasAlpha, forKey: .hasAlpha)
        try container.encodeIfPresent(bitDepth, forKey: .bitDepth)
    }
}
