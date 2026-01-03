import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO

struct TemplateSelectionView: View {
    @ObservedObject var viewModel: CreateSPACSVViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingFilePicker = false
    @State private var pickerType: TemplatePickerType = .globalIndividual
    @State private var selectedTeam: String?
    @State private var showConfigurator = false
    @State private var templateConfigs: [TemplateConfigModel] = []
    
    // MARK: - Library panel state
    @State private var libraryFiles: [URL] = []
    @State private var librarySearch: String = ""
    @State private var selectedLibraryFileNames = Set<String>()
    @State private var psdThumbCache: [URL: NSImage] = [:]
    // Per-file library pose config to ensure toggle works before assignment
    @State private var libraryPoseConfig: [String: (isMulti: Bool, second: String)] = [:]
    @State private var showOverwriteConfirm: Bool = false
    @State private var overwriteTargets: [String] = [] // teams
    
    // MARK: - Team filter
    @State private var teamSearch: String = ""
    
    // MARK: - Drag & Drop
    private let dragUTI = UTType.plainText
    
    private var allowedTypes: [UTType] {
        var types: [UTType] = []
        if let psd = UTType(filenameExtension: "psd") { types.append(psd) }
        if let psb = UTType(filenameExtension: "psb") { types.append(psb) }
        return types + [.jpeg, .png, .tiff]
    }
    
    var body: some View {
        HStack(spacing: 16) {
            templateLibraryPanel
            Divider()
            VStack(spacing: 16) {
                perTeamView
                Spacer()
                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                    Button("Apply") { finalizeAndApply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasAnyTemplates())
                }
            }
        }
        .padding()
        .frame(width: 980, height: 620)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showConfigurator) { configurationSheet }
        .onDisappear {
            viewModel.applyTemplateConfiguration()
            viewModel.runPreflight()
        }
        .onAppear { refreshLibrary() }
        .alert("Overwrite existing templates for all teams?", isPresented: $showOverwriteConfirm, actions: {
            Button("Cancel", role: .cancel) {}
            Button("Overwrite") { applySelectedLibraryToSelectedTeams(confirmOverwrite: true) }
        }, message: {
            Text(overwriteTargets.sorted().joined(separator: ", "))
        })
    }
    
    // sameForAllView removed
    
    private var perTeamView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Search teams", text: $teamSearch)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(.bottom, 6)
            assignmentMatrix
        }
    }

    private func teamRow(_ team: String) -> some View {
        let teamConfig = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
        return HStack(alignment: .top, spacing: 12) {
            Text(team)
                .frame(width: 220, alignment: .leading)
            // Individual cell (drop target)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Individual"); Spacer() }
                flowChips(for: teamConfig.individual, team: team, type: .individual)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Constants.Colors.surface)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Constants.Colors.border, lineWidth: 1))
            .onDrop(of: [dragUTI], isTargeted: nil) { providers in
                handleDrop(into: team, type: .individual, providers: providers)
            }
            // Sports Mate cell (drop target)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Sports Mate"); Spacer() }
                flowChips(for: teamConfig.sportsMate, team: team, type: .sportsMate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Constants.Colors.surface)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Constants.Colors.border, lineWidth: 1))
            .onDrop(of: [dragUTI], isTargeted: nil) { providers in
                handleDrop(into: team, type: .sportsMate, providers: providers)
            }
        }
        .padding(8)
        .background(Constants.Colors.surfaceElevated)
        .cornerRadius(8)
    }
    
    private func listTemplates(_ templates: [CSVBTemplateInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(templates, id: \.fileName) { t in
                templateChip(t)
            }
        }
    }
    
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        switch pickerType {
        case .globalIndividual:
            let existing = Set(viewModel.globalIndividualTemplates.map { $0.fileName })
            let newOnes = urls.map { $0.lastPathComponent }.filter { !existing.contains($0) }
            viewModel.globalIndividualTemplates.append(contentsOf: newOnes.map { CSVBTemplateInfo(fileName: $0, isMultiPose: false, mainPose: nil, secondPose: nil) })
        case .globalSportsMate:
            // Default Sports Mate to single-pose; user can switch to multi in Configure
            let existing = Set(viewModel.globalSportsMateTemplates.map { $0.fileName })
            let newOnes = urls.map { $0.lastPathComponent }.filter { !existing.contains($0) }
            viewModel.globalSportsMateTemplates.append(contentsOf: newOnes.map { CSVBTemplateInfo(fileName: $0, isMultiPose: false, mainPose: nil, secondPose: nil) })
        case .teamIndividual(let team):
            var cfg = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
            let existing = Set(cfg.individual.map { $0.fileName })
            let newOnes = urls.map { $0.lastPathComponent }.filter { !existing.contains($0) }
            cfg.individual.append(contentsOf: newOnes.map { CSVBTemplateInfo(fileName: $0, isMultiPose: false, mainPose: nil, secondPose: nil) })
            viewModel.teamTemplates[team] = cfg
        case .teamSportsMate(let team):
            // Default Sports Mate to single-pose; user can switch to multi in Configure
            var cfg = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
            let existing = Set(cfg.sportsMate.map { $0.fileName })
            let newOnes = urls.map { $0.lastPathComponent }.filter { !existing.contains($0) }
            cfg.sportsMate.append(contentsOf: newOnes.map { CSVBTemplateInfo(fileName: $0, isMultiPose: false, mainPose: nil, secondPose: nil) })
            viewModel.teamTemplates[team] = cfg
        }
    }
    
    private func finalizeAndApply() {
        viewModel.applyTemplateConfiguration()
        dismiss()
    }
    
    private func hasAnyTemplates() -> Bool {
        !viewModel.globalIndividualTemplates.isEmpty ||
        !viewModel.globalSportsMateTemplates.isEmpty ||
        viewModel.teamTemplates.values.contains { !$0.individual.isEmpty || !$0.sportsMate.isEmpty }
    }
    
    private func gatherAllIndividualConfigModels() -> [TemplateConfigModel] {
        var fileNames = Set<String>()
        var names: [String] = []
        for t in viewModel.globalIndividualTemplates { if fileNames.insert(t.fileName).inserted { names.append(t.fileName) } }
        for (_, cfg) in viewModel.teamTemplates { for t in cfg.individual { if fileNames.insert(t.fileName).inserted { names.append(t.fileName) } } }
        return names.map { TemplateConfigModel(fileName: $0) }
    }

    private func gatherAllSportsMateConfigModels() -> [TemplateConfigModel] {
        var fileNames = Set<String>()
        var names: [String] = []
        for t in viewModel.globalSportsMateTemplates { if fileNames.insert(t.fileName).inserted { names.append(t.fileName) } }
        return names.map { TemplateConfigModel(fileName: $0, poseMode: .multiPose, mainPose: Constants.Validation.multiPoseMainDefault, secondPose: Constants.Validation.multiPoseSecondDefault) }
    }

    private func gatherTeamIndividualConfigModels(_ team: String) -> [TemplateConfigModel] {
        let cfg = viewModel.teamTemplates[team]
        let names = (cfg?.individual ?? []).map { $0.fileName }
        return names.map { TemplateConfigModel(fileName: $0) }
    }

    private func gatherTeamSportsMateConfigModels(_ team: String) -> [TemplateConfigModel] {
        let cfg = viewModel.teamTemplates[team]
        let names = (cfg?.sportsMate ?? []).map { $0.fileName }
        return names.map { TemplateConfigModel(fileName: $0, poseMode: .multiPose, mainPose: Constants.Validation.multiPoseMainDefault, secondPose: Constants.Validation.multiPoseSecondDefault) }
    }

    private var configurationSheet: some View {
        VStack(spacing: 12) {
            Text("Configure Templates").font(.title3).bold()
            if templateConfigs.isEmpty {
                Text("No templates selected").foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(templateConfigs.indices, id: \.self) { idx in
                            let binding = Binding(get: { templateConfigs[idx] }, set: { templateConfigs[idx] = $0 })
                            TemplateConfigRow(binding)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            HStack {
                Button("Cancel") { showConfigurator = false }
                Spacer()
                Button("Apply") {
                    applyConfigToViewModel()
                    showConfigurator = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(templateConfigs.isEmpty || !templateConfigs.allSatisfy { $0.isValid })
            }
        }
        .padding()
        .frame(width: 620, height: 520)
    }

    private func TemplateConfigRow(_ config: Binding<TemplateConfigModel>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: config.wrappedValue.poseMode == .multiPose ? "photo.on.rectangle" : "photo")
                    .foregroundColor(config.wrappedValue.poseMode == .multiPose ? Constants.Colors.warningOrange : Constants.Colors.brandTint)
                Text(config.wrappedValue.fileName)
                Spacer()
                Picker("", selection: config.poseMode) {
                    Text("Single").tag(PoseMode.singlePose)
                    Text("Multi").tag(PoseMode.multiPose)
                }.pickerStyle(.segmented).frame(width: 160)
            }
            if config.wrappedValue.poseMode == .multiPose {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Second Pose").font(.caption)
                        TextField(Constants.Validation.multiPoseSecondDefault, text: config.secondPose)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
            }
            Divider()
        }
        .padding(8)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }

    private func applyConfigToViewModel() {
        // Build map
        // Merge configs by filename; last wins to avoid duplicate-key crash
        var map: [String: CSVBTemplateInfo] = [:]
        for cfg in templateConfigs {
            let info = CSVBTemplateInfo(
                fileName: cfg.fileName,
                isMultiPose: cfg.poseMode == .multiPose,
                mainPose: nil,
                secondPose: cfg.poseMode == .multiPose ? cfg.secondPose : nil
            )
            map[cfg.fileName] = info
        }
        // Update globals
        viewModel.globalIndividualTemplates = viewModel.globalIndividualTemplates.map { t in map[t.fileName] ?? t }
        viewModel.globalSportsMateTemplates = viewModel.globalSportsMateTemplates.map { t in map[t.fileName] ?? t }
        // Update per-team
        for (team, cfg) in viewModel.teamTemplates {
            var updated = cfg
            updated.individual = cfg.individual.map { t in map[t.fileName] ?? t }
            updated.sportsMate = cfg.sportsMate.map { t in map[t.fileName] ?? t }
            viewModel.teamTemplates[team] = updated
        }
        viewModel.applyTemplateConfiguration()
    }
}

// MARK: - Library/Matrix helpers
extension TemplateSelectionView {
    private var templateLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Template Library").font(.headline)
                Spacer()
                Button(role: .none) { refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan PSD/PSB in job root")
            }
            HStack(spacing: 8) {
                TextField("Search templates", text: $librarySearch)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredLibraryFiles(), id: \.self) { url in
                        libraryRow(for: url)
                            .onDrag { NSItemProvider(object: dragPayload(for: url) as NSString) }
                    }
                }
            }
            // Bottom controls removed per UX cleanup
        }
        .frame(width: 320)
    }
    
    private func libraryRow(for url: URL) -> some View {
        let fileName = url.lastPathComponent
        return HStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Constants.Colors.surface)
                    .frame(width: 56, height: 42)
                if let img = psdThumbCache[url] {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 42)
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(Constants.Colors.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName).font(.caption)
                HStack(spacing: 10) {
                    Toggle("Multi-pose", isOn: Binding(get: { libraryIsMulti(fileName) }, set: { setLibraryMulti(fileName, $0) }))
                        .toggleStyle(.switch)
                    if libraryIsMulti(fileName) {
                        HStack(spacing: 6) {
                            Text("Second:").font(.caption2)
                            TextField(Constants.Validation.multiPoseSecondDefault, text: Binding(get: { librarySecondPose(fileName) }, set: { setLibrarySecondPose(fileName, $0) }))
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                    }
                }
            }
            Spacer()
            // Removed slider icon per UX preference
        }
        .padding(6)
        .background(Constants.Colors.surfaceElevated)
        .cornerRadius(8)
        .task { await ensurePSDThumb(url) }
    }
    
    private func filteredLibraryFiles() -> [URL] {
        let q = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return libraryFiles }
        return libraryFiles.filter { $0.lastPathComponent.lowercased().contains(q) }
    }
    
    private func refreshLibrary() {
        let root = viewModel.jobRootURL()
        let fm = FileManager.default
        var urls: [URL] = []
        if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
            urls = contents.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }
        }
        libraryFiles = urls.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        // Eagerly preload thumbnails to avoid scroll stutter
        Task { await preloadPSDThumbs() }
    }

    private func preloadPSDThumbs() async {
        for url in libraryFiles {
            await ensurePSDThumb(url)
        }
    }

    private func openConfiguratorForSingle(_ fileName: String) {
        templateConfigs = [TemplateConfigModel(fileName: fileName)]
        showConfigurator = true
    }

    private var applyAllRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Apply to all teams")
                .font(.headline)
                .frame(width: 220, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Constants.Colors.brandSoftFill)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Constants.Colors.brandTint, style: StrokeStyle(lineWidth: 1, dash: [6]))
                Text("Individual").font(.subheadline)
            }
            .frame(height: 48)
            .onDrop(of: [dragUTI], isTargeted: nil) { providers in
                handleDropAll(type: .individual, providers: providers)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Constants.Colors.brandSoftFill)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Constants.Colors.brandTint, style: StrokeStyle(lineWidth: 1, dash: [6]))
                Text("Sports Mate").font(.subheadline)
            }
            .frame(height: 48)
            .onDrop(of: [dragUTI], isTargeted: nil) { providers in
                handleDropAll(type: .sportsMate, providers: providers)
            }
        }
        .padding(10)
        .background(Constants.Colors.surfaceElevated)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Constants.Colors.brandTint, lineWidth: 1))
        .cornerRadius(12)
    }

    private func handleDropAll(type: TemplateType, providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let ns = obj as? NSString else { return }
                    let s = ns as String
                    DispatchQueue.main.async {
                        for team in viewModel.detectedTeams {
                            addTemplate(name: s, to: team, type: type)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func ensurePSDThumb(_ url: URL) async {
        if psdThumbCache[url] != nil { return }
        // Try to rasterize first layer thumbnail via CGImageSource
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                let img = NSImage(cgImage: cg, size: NSSize(width: 256, height: 256))
                await MainActor.run { psdThumbCache[url] = img }
                return
            }
        }
        // Fallback: use file icon
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        await MainActor.run { psdThumbCache[url] = icon }
    }
    
    private func dragPayload(for url: URL) -> String {
        return url.lastPathComponent
    }
    
    private func handleDrop(into team: String, providers: [NSItemProvider]) -> Bool {
        handleDrop(into: team, type: .individual, providers: providers)
    }

    private func handleDrop(into team: String, type: TemplateType, providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let ns = obj as? NSString else { return }
                    let s = ns as String
                    DispatchQueue.main.async { addTemplate(name: s, to: team, type: type) }
                }
                return true
            }
        }
        return false
    }
    
    private var assignmentMatrix: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                applyAllRow
                ForEach(filteredTeams(), id: \.self) { team in
                    teamRow(team)
                }
            }
        }
    }
    
    private func filteredTeams() -> [String] {
        let q = teamSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let teams = viewModel.detectedTeams
        if q.isEmpty { return teams }
        return teams.filter { $0.lowercased().contains(q) }
    }
    
    private func flowChips(for templates: [CSVBTemplateInfo], team: String, type: TemplateType) -> some View {
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(templates, id: \.fileName) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.isMultiPose ? "photo.on.rectangle" : "photo")
                        .foregroundColor(t.isMultiPose ? Constants.Colors.warningOrange : Constants.Colors.brandTint)
                    Text(t.fileName).font(.caption2)
                    Button(action: { removeTemplate(name: t.fileName, from: team, type: type) }) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(Constants.Colors.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Constants.Colors.surface)
                .cornerRadius(10)
            }
        }
    }
    
    private func templateChip(_ t: CSVBTemplateInfo) -> some View {
        HStack {
            Image(systemName: t.isMultiPose ? "photo.on.rectangle" : "photo")
                .foregroundColor(t.isMultiPose ? Constants.Colors.warningOrange : Constants.Colors.brandTint)
            Text(t.fileName).font(.caption)
            Spacer()
        }
        .padding(4)
        .background(Constants.Colors.surfaceElevated)
        .cornerRadius(6)
    }
    
    private func addTemplate(name: String, to team: String, type: TemplateType) {
        var cfg = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
        let isMulti = libraryPoseConfig[name]?.isMulti ?? libraryIsMulti(name)
        let second = libraryPoseConfig[name]?.second ?? librarySecondPose(name)
        let info = CSVBTemplateInfo(fileName: name, isMultiPose: isMulti, mainPose: nil, secondPose: isMulti ? (second.isEmpty ? Constants.Validation.multiPoseSecondDefault : second) : nil)
        switch type {
        case .individual:
            if !cfg.individual.contains(where: { $0.fileName == name }) { cfg.individual.append(info) }
        case .sportsMate:
            if !cfg.sportsMate.contains(where: { $0.fileName == name }) { cfg.sportsMate.append(info) }
        }
        viewModel.teamTemplates[team] = cfg
    }
    
    private func removeTemplate(name: String, from team: String, type: TemplateType) {
        guard var cfg = viewModel.teamTemplates[team] else { return }
        switch type {
        case .individual:
            cfg.individual.removeAll { $0.fileName == name }
        case .sportsMate:
            cfg.sportsMate.removeAll { $0.fileName == name }
        }
        viewModel.teamTemplates[team] = cfg
    }
    
    private func applySelectedLibraryToSelectedTeams(confirmOverwrite: Bool) {
        // Determine teams that will be overwritten
        let intended = selectedLibraryFileNames
        var overwrite: [String] = []
        if !confirmOverwrite {
            for team in viewModel.detectedTeams {
                let cfg = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
                let existing = cfg.individual.map { $0.fileName } + cfg.sportsMate.map { $0.fileName }
                if !existing.isEmpty { overwrite.append(team) }
            }
            if !overwrite.isEmpty {
                overwriteTargets = overwrite
                showOverwriteConfirm = true
                return
            }
        }
        for team in viewModel.detectedTeams {
            var cfg = viewModel.teamTemplates[team] ?? (individual: [], sportsMate: [])
            if confirmOverwrite { cfg.individual.removeAll(); cfg.sportsMate.removeAll() }
            for name in intended {
                let isMulti = libraryIsMulti(name)
                let second = librarySecondPose(name)
                let info = CSVBTemplateInfo(fileName: name, isMultiPose: isMulti, mainPose: nil, secondPose: isMulti ? (second.isEmpty ? Constants.Validation.multiPoseSecondDefault : second) : nil)
                if !cfg.individual.contains(where: { $0.fileName == name }) { cfg.individual.append(info) }
            }
            viewModel.teamTemplates[team] = cfg
        }
        showOverwriteConfirm = false
    }
    
    // Library per-file multi-pose states (kept transient in View)
    private func libraryIsMulti(_ name: String) -> Bool {
        if let cached = libraryPoseConfig[name]?.isMulti { return cached }
        let all = currentAllTemplates()
        let v = all.first(where: { $0.fileName == name })?.isMultiPose ?? false
        libraryPoseConfig[name] = (v, libraryPoseConfig[name]?.second ?? "")
        return v
    }
    private func setLibraryMulti(_ name: String, _ v: Bool) {
        let second = libraryPoseConfig[name]?.second ?? Constants.Validation.multiPoseSecondDefault
        libraryPoseConfig[name] = (v, second)
        func mapArray(_ arr: [CSVBTemplateInfo]) -> [CSVBTemplateInfo] {
            arr.map { t in t.fileName == name ? CSVBTemplateInfo(fileName: t.fileName, isMultiPose: v, mainPose: t.mainPose, secondPose: v ? (t.secondPose ?? second) : nil) : t }
        }
        viewModel.globalIndividualTemplates = mapArray(viewModel.globalIndividualTemplates)
        viewModel.globalSportsMateTemplates = mapArray(viewModel.globalSportsMateTemplates)
        for (team, cfg) in viewModel.teamTemplates {
            var updated = cfg
            updated.individual = mapArray(cfg.individual)
            updated.sportsMate = mapArray(cfg.sportsMate)
            viewModel.teamTemplates[team] = updated
        }
    }
    private func librarySecondPose(_ name: String) -> String {
        if let cached = libraryPoseConfig[name]?.second { return cached }
        let all = currentAllTemplates()
        let s = all.first(where: { $0.fileName == name })?.secondPose ?? Constants.Validation.multiPoseSecondDefault
        libraryPoseConfig[name] = (libraryPoseConfig[name]?.isMulti ?? false, s)
        return s
    }
    private func setLibrarySecondPose(_ name: String, _ v: String) {
        let isMulti = libraryPoseConfig[name]?.isMulti ?? true
        libraryPoseConfig[name] = (isMulti, v)
        func mapArray(_ arr: [CSVBTemplateInfo]) -> [CSVBTemplateInfo] {
            arr.map { t in t.fileName == name ? CSVBTemplateInfo(fileName: t.fileName, isMultiPose: t.isMultiPose, mainPose: t.mainPose, secondPose: v) : t }
        }
        viewModel.globalIndividualTemplates = mapArray(viewModel.globalIndividualTemplates)
        viewModel.globalSportsMateTemplates = mapArray(viewModel.globalSportsMateTemplates)
        for (team, cfg) in viewModel.teamTemplates {
            var updated = cfg
            updated.individual = mapArray(cfg.individual)
            updated.sportsMate = mapArray(cfg.sportsMate)
            viewModel.teamTemplates[team] = updated
        }
    }
    private func currentAllTemplates() -> [CSVBTemplateInfo] {
        var out: [CSVBTemplateInfo] = []
        out.append(contentsOf: viewModel.globalIndividualTemplates)
        out.append(contentsOf: viewModel.globalSportsMateTemplates)
        for (_, cfg) in viewModel.teamTemplates { out.append(contentsOf: cfg.individual); out.append(contentsOf: cfg.sportsMate) }
        return out
    }
}


