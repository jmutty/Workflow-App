import Foundation
import Darwin

class TaggingService {
    func setRedTag(for urls: [URL]) {
        setTags(["Red"], for: urls)
    }
    
    func setTag(_ name: String, for urls: [URL]) {
        setTags([name], for: urls)
    }
    
    func setTags(_ names: [String], for urls: [URL]) {
        for url in urls {
            if #available(macOS 26.0, *) {
                var values = URLResourceValues()
                values.tagNames = names
                var mutableURL = url
                try? mutableURL.setResourceValues(values)
            } else {
                setLegacyTags(names, for: url)
            }
        }
    }
    
    // Fallback for older macOS: set extended attribute com.apple.metadata:_kMDItemUserTags
    private func setLegacyTags(_ names: [String], for url: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0) else {
            return
        }
        data.withUnsafeBytes { rawBuffer in
            if let base = rawBuffer.baseAddress {
                _ = setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", base, data.count, 0, 0)
            }
        }
    }
}


