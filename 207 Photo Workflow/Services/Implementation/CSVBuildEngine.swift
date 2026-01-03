import Foundation

struct CSVBuildEngine {
    
    struct Input {
        let headers: [String]
        let templateMode: CreateSPACSVViewModel.TemplateMode
        let detectedTeams: [String]
        let regularPhotos: [CSVPhotoRecord]
        let manualPhotos: [CSVPhotoRecord]
        let teamTemplates: [String: (individual: [CSVBTemplateInfo], sportsMate: [CSVBTemplateInfo])]
        let globalIndividualTemplates: [CSVBTemplateInfo]
        let globalSportsMateTemplates: [CSVBTemplateInfo]
        let includeTeams: Set<String>?
        let includeManualWithoutTeam: Bool
        let progressCallback: ((String) -> Void)?
    }
    
    static func buildRows(input: Input, missingSecondPoseCount: inout Int) -> [[String]] {
        var rows: [[String]] = []
        rows.append(input.headers)
        
        var idx: [String: Int] = [:]
        for (i, h) in input.headers.enumerated() { idx[h] = i }
        
        func sanitizePose(_ pose: String) -> String {
            let trimmed = pose.trimmingCharacters(in: .whitespacesAndNewlines)
            let noLeadingZeros = trimmed.drop { $0 == "0" }
            return noLeadingZeros.isEmpty ? "0" : String(noLeadingZeros)
        }
        
        func normalizedKey(team: String, player: String) -> String {
            func norm(_ s: String) -> String {
                let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                return collapsed.precomposedStringWithCanonicalMapping
            }
            return "\(norm(team))_\(norm(player))"
        }
        
        func isBuddyPhoto(_ fileName: String) -> Bool {
            let name = (fileName as NSString).deletingPathExtension
            let parts = name.split(separator: "_").map(String.init)
            guard parts.count >= 2 else { return false }
            let token = parts[1]
            if token.hasPrefix("Buddy") {
                let suffix = token.dropFirst("Buddy".count)
                return suffix.isEmpty || suffix.allSatisfy({ $0.isNumber })
            }
            return false
        }
        
        func buildPlayerPoseMap(_ photos: [CSVPhotoRecord]) -> [String: [String: String]] {
            var map: [String: [String: String]] = [:]
            for p in photos {
                let key = normalizedKey(team: p.teamName, player: p.playerName)
                if map[key] == nil { map[key] = [:] }
                let sp = sanitizePose(p.poseNumber)
                map[key]?[p.poseNumber] = p.fileName
                map[key]?[sp] = p.fileName
            }
            return map
        }
        
        let playerPoseMap = buildPlayerPoseMap(input.regularPhotos)
        
        func manualTemplate(for rec: CSVPhotoRecord) -> CSVBTemplateInfo {
            if !rec.teamName.isEmpty, rec.teamName != "MANUAL" {
                if let cfg = input.teamTemplates[rec.teamName], let t = cfg.individual.first {
                    return t
                }
            }
            if let t = input.globalIndividualTemplates.first { return t }
            if let any = input.detectedTeams.compactMap({ input.teamTemplates[$0]?.individual.first }).first { return any }
            return CSVBTemplateInfo(fileName: "", isMultiPose: false, mainPose: nil, secondPose: nil)
        }
        
        func addRow(for photo: CSVPhotoRecord, template: CSVBTemplateInfo, appendSuffix: String) {
            var fields = Array(repeating: "", count: input.headers.count)
            fields[idx["SPA"] ?? 0] = photo.fileName
            if isBuddyPhoto(photo.fileName) {
                fields[idx["NAME"] ?? 0] = ""
                fields[idx["FIRSTNAME"] ?? 0] = ""
                fields[idx["LASTNAME"] ?? 0] = ""
                fields[idx["TEAMNAME"] ?? 0] = photo.teamName
            } else if photo.isManual {
                fields[idx["NAME"] ?? 0] = "***NEEDS_NAME***"
                fields[idx["FIRSTNAME"] ?? 0] = "***CHANGE***"
                fields[idx["LASTNAME"] ?? 0] = "***CHANGE***"
                fields[idx["TEAMNAME"] ?? 0] = "***ASSIGN_TEAM***"
            } else {
                fields[idx["NAME"] ?? 0] = photo.playerName
                fields[idx["FIRSTNAME"] ?? 0] = photo.firstName
                fields[idx["LASTNAME"] ?? 0] = photo.lastName
                fields[idx["TEAMNAME"] ?? 0] = photo.teamName
            }
            fields[idx["APPEND FILE NAME"] ?? 0] = appendSuffix
            if isBuddyPhoto(photo.fileName) {
                fields[idx["SUB FOLDER"] ?? 0] = "\(photo.teamName)"
            } else {
                fields[idx["SUB FOLDER"] ?? 0] = photo.isManual ? "***ASSIGN_TEAM***" : photo.teamName
            }
            fields[idx["TEAM FILE"] ?? 0] = isBuddyPhoto(photo.fileName) ? "\(photo.teamName).jpg" : (photo.isManual ? "***ASSIGN_TEAM***.jpg" : "\(photo.teamName).jpg")
            fields[idx["TEMPLATE FILE"] ?? 0] = template.fileName
            
            if let secondPose = template.secondPose, !secondPose.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = normalizedKey(team: photo.teamName, player: photo.playerName)
                let sp = sanitizePose(secondPose)
                let secondFile = playerPoseMap[key]?[sp] ?? playerPoseMap[key]?[secondPose]
                if let second = secondFile, second != photo.fileName {
                    fields[idx["PLAYER 2 FILE"] ?? 0] = second
                } else if secondFile == nil {
                    fields[idx["PLAYER 2 FILE"] ?? 0] = "***MISSING_SECOND_POSE***"
                    missingSecondPoseCount += 1
                }
            }
            rows.append(fields)
            input.progressCallback?(photo.fileName)
        }
        
        // Sort photos by team, player, pose number (ascending) for grouping
        let sortedRegular = input.regularPhotos.sorted { a, b in
            if a.teamName != b.teamName { return a.teamName < b.teamName }
            if a.playerName != b.playerName { return a.playerName < b.playerName }
            let ap = Int(a.poseNumber) ?? 0
            let bp = Int(b.poseNumber) ?? 0
            return ap < bp
        }
        
        switch input.templateMode {
        case .perTeam:
            let allowedTeams = input.includeTeams ?? Set(input.detectedTeams)
            for team in input.detectedTeams where allowedTeams.contains(team) {
                guard let cfg = input.teamTemplates[team] else { continue }
                let teamPhotos = sortedRegular.filter { $0.teamName == team }
                let teamManual = input.manualPhotos.filter { $0.teamName == team }
                
                for template in cfg.individual {
                    for p in teamPhotos {
                        if let sp = template.secondPose, !sp.trimmingCharacters(in: .whitespaces).isEmpty,
                           sanitizePose(p.poseNumber) == sanitizePose(sp) {
                            continue
                        }
                        addRow(for: p, template: template, appendSuffix: "")
                    }
                    for m in teamManual {
                        addRow(for: m, template: template, appendSuffix: "")
                    }
                }
                
                rows.append(Array(repeating: "", count: input.headers.count))
                
                for template in cfg.sportsMate {
                    for p in teamPhotos {
                        addRow(for: p, template: template, appendSuffix: "_MM")
                    }
                }
            }
            
            if input.includeManualWithoutTeam {
                let unknownManual = input.manualPhotos.filter { $0.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !unknownManual.isEmpty {
                    for p in unknownManual {
                        let t = manualTemplate(for: p)
                        addRow(for: p, template: t, appendSuffix: "")
                    }
                }
            }
        }
        
        var seen = Set<String>()
        var out: [[String]] = []
        for r in rows {
            let line = r.joined(separator: ",")
            if seen.insert(line).inserted || r == rows.first {
                out.append(r)
            }
        }
        return out
    }
}

