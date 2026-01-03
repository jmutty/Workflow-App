import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

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
    
    @MainActor func loadImage(from url: URL) async throws -> NSImage {
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
    
    @MainActor func getThumbnail(for url: URL, size: CGSize) async throws -> NSImage {
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
    
    @MainActor func getImageMetadata(from url: URL) async throws -> ImageMetadata {
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
    
    // MARK: - Face Detection
    
    func detectFaces(in image: NSImage) async -> [CGRect] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        return await withCheckedContinuation { continuation in
            do {
                try handler.perform([request])
                if let results = request.results {
                    let faceRects = results.map { $0.boundingBox }
                    continuation.resume(returning: faceRects)
                } else {
                    continuation.resume(returning: [])
                }
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Private Methods
    
    @MainActor private func generateThumbnail(from url: URL, targetSize: CGSize) async throws -> NSImage {
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
        
        // Extract EXIF/IPTC data if available
        let _ = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptcDict = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
 
        // Basic properties we still expose
        let colorSpace = properties[kCGImagePropertyColorModel] as? String
        let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Int
        let dpiHeight = properties[kCGImagePropertyDPIHeight] as? Int
        let dpi = dpiWidth ?? dpiHeight
        let cameraModel = tiffDict?[kCGImagePropertyTIFFModel] as? String

        // IPTC/TIFF copyright strings
        let iptcCopyright = iptcDict?[kCGImagePropertyIPTCCopyrightNotice] as? String
        let tiffCopyright = tiffDict?[kCGImagePropertyTIFFCopyright] as? String

        // Heuristic fallback: scan file text for XMP dc:rights/Rights and capture a numeric code
        var xmpRightsValue: String? = nil
        if let rawData = try? Data(contentsOf: url),
           let text = String(data: rawData, encoding: .utf8) {
            // Look for digits near a rights tag to avoid false positives
            let patterns = [
                "(?is)dc:rights.{0,200}?(\\d{6,})",
                "(?is)<Rights>[^<]{0,200}?(\\d{6,})",
                "(?is)Rights.{0,200}?(\\d{6,})"
            ]
            for pat in patterns {
                if let re = try? NSRegularExpression(pattern: pat, options: []) {
                    if let match = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
                       match.numberOfRanges >= 2,
                       let r = Range(match.range(at: 1), in: text) {
                        let candidate = String(text[r]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if !candidate.isEmpty { xmpRightsValue = candidate; break }
                    }
                }
            }
        }
        let trimmedIptc = iptcCopyright?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTiff = tiffCopyright?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedXmp = xmpRightsValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let iptc = trimmedIptc, !iptc.isEmpty {
            print("🔍 [Meta] IPTC copyright for \(url.lastPathComponent): '\(iptc)'")
        }
        if let tiff = trimmedTiff, !tiff.isEmpty {
            print("🔍 [Meta] TIFF copyright for \(url.lastPathComponent): '\(tiff)'")
        }
        if let xmp = trimmedXmp, !xmp.isEmpty {
            print("🔍 [Meta] XMP rights for \(url.lastPathComponent): '\(xmp)'")
        }
        
        let resolvedCopyright =
            (trimmedIptc?.isEmpty == false ? trimmedIptc :
                (trimmedTiff?.isEmpty == false ? trimmedTiff :
                    (trimmedXmp?.isEmpty == false ? trimmedXmp : nil)))
        
        if let resolved = resolvedCopyright {
            print("✅ [Meta] Resolved barcode/copyright for \(url.lastPathComponent): '\(resolved)'")
        } else {
            print("⚠️ [Meta] No usable barcode/copyright resolved for \(url.lastPathComponent)")
        }
 
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
            bitDepth: bitDepth,
            copyrightNotice: resolvedCopyright
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
    
    @MainActor func generateThumbnails(for urls: [URL], size: CGSize) async throws -> [URL: NSImage] {
        var thumbnails: [URL: NSImage] = [:]
        for url in urls {
            let thumb = try await getThumbnail(for: url, size: size)
            thumbnails[url] = thumb
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
        case orientation, hasAlpha, bitDepth, copyrightNotice
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
        copyrightNotice = try container.decodeIfPresent(String.self, forKey: .copyrightNotice)
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
        try container.encodeIfPresent(copyrightNotice, forKey: .copyrightNotice)
    }
}
