import SwiftUI
import UniformTypeIdentifiers

struct TemplateSelectionView: View {
    @ObservedObject var viewModel: CreateSPACSVViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingFilePicker = false
    @State private var pickerType: TemplatePickerType = .globalIndividual
    @State private var selectedTeam: String?
    @State private var showConfigurator = false
    @State private var templateConfigs: [TemplateConfigModel] = []
    
    private var allowedTypes: [UTType] {
        var types: [UTType] = []
        if let psd = UTType(filenameExtension: "psd") { types.append(psd) }
        if let psb = UTType(filenameExtension: "psb") { types.append(psb) }
        return types + [.jpeg, .png, .tiff]
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Configure Templates").font(.title2).bold()
            if viewModel.templateMode == .sameForAll {
                sameForAllView
            } else {
                perTeamView
            }
            Spacer()
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                Button("Apply") { finalizeAndApply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnyTemplates())
            }
        }
        .padding()
        .frame(width: Constants.UI.templateWindowWidth, height: Constants.UI.templateWindowHeight)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showConfigurator) { configurationSheet }
        .onDisappear {
            viewModel.applyTemplateConfiguration()
            viewModel.runPreflight()
        }
    }
    
    private var sameForAllView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Individual Templates") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Templates: \(viewModel.globalIndividualTemplates.count)")
                        Spacer()
                        Button("Add") { pickerType = .globalIndividual; showingFilePicker = true }
                        if !viewModel.globalIndividualTemplates.isEmpty ||
                            viewModel.teamTemplates.values.contains(where: { !$0.individual.isEmpty }) {
                            Button("Configure") {
                                templateConfigs = gatherAllIndividualConfigModels()
                                showConfigurator = true
                            }
                        }
                    }
                    listTemplates(viewModel.globalIndividualTemplates)
                }
                .padding(8)
            }
            GroupBox("Sports Mate Templates") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Templates: \(viewModel.globalSportsMateTemplates.count)")
                        Spacer()
                        Button("Add") { pickerType = .globalSportsMate; showingFilePicker = true }
                        // Sports Mate defaults to single-pose. Use Configure (opened from header area) if needed.
                    }
                    listTemplates(viewModel.globalSportsMateTemplates)
                }
                .padding(8)
            }
        }
    }
    
    private var perTeamView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.detectedTeams, id: \.self) { team in
                        teamRow(team)
                    }
                }
            }
        }
    }

    private func teamRow(_ team: String) -> some View {
        GroupBox(team) {
            let teamConfig = viewModel.teamTemplates[team]
            return AnyView(
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("Individual: \(teamConfig?.individual.count ?? 0)")
                        HStack {
                            Button("Add") { selectedTeam = team; pickerType = .teamIndividual(team: team); showingFilePicker = true }
                            if !(teamConfig?.individual.isEmpty ?? true) {
                                Button("Configure") {
                                    templateConfigs = gatherTeamIndividualConfigModels(team)
                                    showConfigurator = true
                                }
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Sports Mate: \(teamConfig?.sportsMate.count ?? 0)")
                        HStack {
                            Button("Add") { selectedTeam = team; pickerType = .teamSportsMate(team: team); showingFilePicker = true }
                            // Sports Mate defaults to single-pose. Use header Configure if needed.
                        }
                    }
                    Spacer()
                }
                .padding(6)
            )
        }
    }
    
    private func listTemplates(_ templates: [CSVBTemplateInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(templates, id: \.fileName) { t in
                HStack {
                    Image(systemName: t.isMultiPose ? "photo.on.rectangle" : "photo")
                        .foregroundColor(t.isMultiPose ? .orange : .blue)
                    Text(t.fileName).font(.caption)
                    Spacer()
                }
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
                    .foregroundColor(config.wrappedValue.poseMode == .multiPose ? .orange : .blue)
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


