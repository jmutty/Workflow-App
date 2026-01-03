import Foundation

// MARK: - School Batch Service
struct SchoolBatchRow {
    let ezcomp: String
    let firstName: String
    let lastName: String
    let forceOrder: String
    let groupId: String
    let yearWithGroup: String
    let schoolName: String
    let groupText1: String
}

class SchoolBatchService {
    private let fileManager: FileManagerProtocol
    private let csvService: CSVServiceProtocol
    
    init(fileManager: FileManagerProtocol = FileManager.default,
         csvService: CSVServiceProtocol = CSVService()) {
        self.fileManager = fileManager
        self.csvService = csvService
    }
    
    // Find top-level VOL* folders in the selected job folder
    func findVOLFolders(in jobFolder: URL) -> [URL] {
        var candidates: [URL] = []
        
        // If the selected job folder IS the VOL folder, accept it
        if jobFolder.lastPathComponent.uppercased().hasPrefix("VOL") {
            candidates.append(jobFolder)
        }
        
        // Look for immediate child VOL* folders
        do {
            let items = try fileManager.contentsOfDirectory(at: jobFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let immediate = items.filter { url in
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
                return url.lastPathComponent.uppercased().hasPrefix("VOL")
            }
            candidates.append(contentsOf: immediate)
        } catch {
            // ignore and try recursive fallback
        }
        
        // If still none, do a shallow recursive search for any VOL* directory beneath
        if candidates.isEmpty {
            if let en = FileManager.default.enumerator(at: jobFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in en {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        if url.lastPathComponent.uppercased().hasPrefix("VOL") {
                            candidates.append(url)
                        }
                    }
                }
            }
        }
        
        // Deduplicate and sort
        let unique = Array(Set(candidates.map { $0.standardizedFileURL })).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return unique
    }
    
    // Scan the VOL folder for subfolders and image files and build CSV rows
    func buildRows(volURL: URL,
                   year: String,
                   schoolName: String,
                   groupText1: String) -> (rows: [SchoolBatchRow], imageFiles: [URL]) {
        var rows: [SchoolBatchRow] = []
        var imagesToCopy: [URL] = []
        
        do {
            let classFolders = try fileManager.contentsOfDirectory(at: volURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { url in
                    var isDir: ObjCBool = false
                    return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            for classFolder in classFolders {
                let rawGroupId = classFolder.lastPathComponent
                let groupId = rawGroupId.replacingOccurrences(of: "_", with: " ")
                let contents = try fileManager.contentsOfDirectory(at: classFolder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
                let imageFiles = contents.filter { Constants.FileExtensions.isImageFile($0) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                
                for imageURL in imageFiles {
                    let fileName = imageURL.lastPathComponent
                    let base = imageURL.deletingPathExtension().lastPathComponent
                    let parts = base.split(separator: "_").map(String.init)
                    guard parts.count >= 2 else { continue }
                    let lastName = parts[0]
                    let firstName = parts[1]
                    let row = SchoolBatchRow(
                        ezcomp: fileName,
                        firstName: firstName,
                        lastName: lastName,
                        forceOrder: "",
                        groupId: groupId,
                        yearWithGroup: "\(year) - \(groupId)",
                        schoolName: schoolName,
                        groupText1: groupText1
                    )
                    rows.append(row)
                    imagesToCopy.append(imageURL)
                }
            }
        } catch {
            // If enumeration fails, return what we have
        }
        
        // Sort rows by GROUPID then EZCOMP
        rows.sort { a, b in
            if a.groupId != b.groupId { return a.groupId < b.groupId }
            return a.ezcomp < b.ezcomp
        }
        
        return (rows, imagesToCopy)
    }
    
    // Write CSV to VOL folder with required headers
    func writeCSV(to volURL: URL, rows: [SchoolBatchRow]) async throws -> URL {
        let headers = [
            "EZCOMP",
            "FIRSTNAME",
            "LASTNAME",
            "FORCEORDER",
            "GROUPID",
            "YEAR",
            "SCHOOLNAME",
            "GROUPTEXT1"
        ]
        var out: [[String]] = []
        out.append(headers)
        for r in rows {
            out.append([
                r.ezcomp,
                r.firstName,
                r.lastName,
                r.forceOrder,
                r.groupId,
                r.yearWithGroup,
                r.schoolName,
                r.groupText1
            ])
        }
        let csvURL = volURL.appendingPathComponent("ClassComposites.csv")
        try await csvService.writeCSV(out, to: csvURL, encoding: .utf8)
        return csvURL
    }
    
    struct CopyStats {
        let totalSources: Int
        let copied: Int
        let renamedOnConflict: Int
    }

    // Copy images into VOL root, handling filename conflicts by appending " - GROUPID" before extension
    func copyImagesToVOL(volURL: URL, rows: [SchoolBatchRow], sources: [URL]) throws -> CopyStats {
        // Build a map from source file name to group for quick lookup
        var nameToGroup: [String: String] = [:]
        for r in rows { nameToGroup[r.ezcomp] = r.groupId }
        
        var copied = 0
        var renamedOnConflict = 0

        for src in sources {
            let fileName = src.lastPathComponent
            let groupId = nameToGroup[fileName] ?? ""
            let destBase = fileName
            var destURL = volURL.appendingPathComponent(destBase)
            
            if FileManager.default.fileExists(atPath: destURL.path) {
                // Append " - GROUPID" before extension
                let ext = destURL.pathExtension
                let base = destURL.deletingPathExtension().lastPathComponent
                let withGroup = base + " - " + groupId
                destURL = volURL.appendingPathComponent(withGroup).appendingPathExtension(ext)
                
                // If still exists, append numeric suffixes until unique
                var counter = 2
                while FileManager.default.fileExists(atPath: destURL.path) {
                    let candidate = withGroup + " (\(counter))"
                    destURL = volURL.appendingPathComponent(candidate).appendingPathExtension(ext)
                    counter += 1
                }
                renamedOnConflict += 1
            }
            
            // Perform copy
            if FileManager.default.fileExists(atPath: destURL.path) == false {
                try FileManager.default.copyItem(at: src, to: destURL)
                copied += 1
            }
        }

        return CopyStats(totalSources: sources.count, copied: copied, renamedOnConflict: renamedOnConflict)
    }
}


