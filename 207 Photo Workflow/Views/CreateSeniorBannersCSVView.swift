import SwiftUI

struct CreateSeniorBannersCSVView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: CreateSeniorBannersCSVViewModel
    @StateObject private var templateViewModel: CreateSPACSVViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingError = false
    @State private var showingTemplateSelection = false
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: CreateSeniorBannersCSVViewModel(jobFolder: jobFolder))
        _templateViewModel = StateObject(wrappedValue: CreateSPACSVViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pasteSection
                    stepControlsSection
                    resultsSection
                    
                    if viewModel.isProcessing {
                        DetailedProgressView(
                            progress: viewModel.operationProgress,
                            currentFile: viewModel.currentOperation,
                            filesCompleted: viewModel.filesCompleted,
                            totalFiles: max(viewModel.totalFiles, 1),
                            status: "Copying PNGs...",
                            etaText: nil,
                            onCancel: nil
                        )
                    }
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(width: Constants.UI.csvWindowWidth, height: Constants.UI.csvWindowHeight)
        .preferredColorScheme(jobManager.colorScheme)
        .onAppear {
            loadExistingCSVIfPresent()
        }
        .sheet(isPresented: $showingTemplateSelection, onDismiss: syncTemplatesFromSelection) {
            TemplateSelectionView(viewModel: templateViewModel)
        }
        .sheet(isPresented: $showingError) {
            ErrorDetailView(
                title: "Senior Banner CSV Error",
                message: viewModel.lastError ?? "Unknown error",
                suggestion: "Fix the issue and try again.",
                details: nil,
                onRetry: { showingError = false }
            )
            .frame(width: 600, height: 360)
        }
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Create Senior Banner CSV").font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
    
    private var pasteSection: some View {
        GroupBox("1) Paste info from Orders") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the order text here. Each subject starts at the filename line and ends at YEAR OF GRADUATION::.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ZStack(alignment: .topLeading) {
                    if viewModel.pastedOrderData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Paste order data…")
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }
                    TextEditor(text: $viewModel.pastedOrderData)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                }
            }
            .padding(8)
        }
    }
    
    private var stepControlsSection: some View {
        GroupBox("2) Parse  •  3) Configure templates  •  4) Generate/copy/save CSV") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("2) Parse") {
                        viewModel.parseOrderData()
                        prepareTemplateSelectionTeams()
                        syncTemplatesFromSelection()
                        viewModel.findMissingPNGs()
                        if viewModel.records.isEmpty, viewModel.lastError != nil {
                            showingError = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.pastedOrderData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
                    
                    Text(parseStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                HStack(spacing: 12) {
                    Button(action: { showingTemplateSelection = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "paintbrush")
                            Text("3) Configure Templates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasParsed || viewModel.records.isEmpty || viewModel.isProcessing)
                    
                    Text(templateStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                Divider()
                
                HStack(spacing: 12) {
                    Button("4) Generate + Copy + Save CSV") {
                        Task { await runGenerateCopySave() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRunStep4)
                    
                    Text(step4StatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            .padding(8)
        }
    }
    
    private var resultsSection: some View {
        GroupBox("Results") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subjects parsed: \(viewModel.records.count)")
                        .font(.headline)
                    Spacer()
                    if viewModel.didCopyPNGs {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(Constants.Colors.successGreen)
                            Text("PNGs copied").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if viewModel.csvGenerated {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill").foregroundColor(Constants.Colors.successGreen)
                            Text("CSV ready").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                
                if !viewModel.missingPNGs.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Constants.Colors.warningOrange)
                            Text("Missing PNGs in Extracted: \(viewModel.missingPNGs.count)")
                                .font(.subheadline)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(viewModel.missingPNGs, id: \.self) { name in
                                    Text(name)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                
                if !viewModel.records.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preview:").font(.subheadline).fontWeight(.medium)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(viewModel.records) { r in
                                    let tmplName = viewModel.templateByTeam[r.teamName]?.fileName ?? ""
                                    let secondPose = viewModel.templateByTeam[r.teamName]?.secondPose ?? ""
                                    let isMulti = viewModel.templateByTeam[r.teamName]?.isMultiPose ?? false
                                    let tmpl = tmplName.isEmpty ? "— no template —" : (isMulti ? "\(tmplName) (P2: \(secondPose))" : tmplName)
                                    Text("\(r.pngFileName) — \(r.fullName) — Team: \(r.teamName) — Album: \(r.album) — \(r.gradYear) — \(tmpl)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                    }
                }
                
                if let err = viewModel.lastError, !err.isEmpty {
                    Divider()
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Constants.Colors.errorRed)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }
    
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
            
            Spacer()
        }
        .padding()
    }
    
    private func loadExistingCSVIfPresent() {
        let url = viewModel.existingCSVURL()
        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty {
            viewModel.generatedCSV = content
            viewModel.csvGenerated = true
        }
    }
    
    // MARK: - Ops with JobManager status + error handling
    private func runGenerateCopySave() async {
        jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .running(progress: nil))
        
        syncTemplatesFromSelection()
        viewModel.generateCSV()
        viewModel.findMissingPNGs()
        if let err = viewModel.lastError, !err.isEmpty {
            jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .error(err))
            showingError = true
            return
        }
        if !viewModel.missingPNGs.isEmpty {
            let err = "Missing \(viewModel.missingPNGs.count) PNG(s) in Extracted."
            jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .error(err))
            viewModel.lastError = err
            showingError = true
            return
        }
        
        let ok = await viewModel.copyPNGsToTimestampedFolder()
        if !ok {
            let err = viewModel.lastError ?? "Copy failed"
            jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .error(err))
            showingError = true
            return
        }
        
        let saved = await viewModel.saveCSVToJobRoot()
        if !saved {
            let err = viewModel.lastError ?? "Save failed"
            jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .error(err))
            showingError = true
            return
        }
        
        jobManager.updateOperationStatus(.createSeniorBannersCSV, status: .completed(Date()))
    }
    
    private var albums: [String] {
        // Template selection is per Team (parsed from filename prefix)
        Array(Set(viewModel.records.map { $0.teamName }))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }
    
    private var templatesReady: Bool {
        guard viewModel.hasParsed, !albums.isEmpty else { return false }
        return albums.allSatisfy { !(viewModel.templateByTeam[$0]?.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canRunStep4: Bool {
        viewModel.hasParsed &&
        !viewModel.records.isEmpty &&
        templatesReady &&
        !viewModel.isProcessing
    }
    
    private var parseStatusText: String {
        if viewModel.records.isEmpty { return "Paste order data, then parse." }
        return "Parsed \(viewModel.records.count) subject(s)."
    }
    
    private var templateStatusText: String {
        if !viewModel.hasParsed { return "Parse first so teams are known." }
        if albums.isEmpty { return "No teams found yet." }
        if templatesReady { return "Templates selected for all teams." }
        return "Select a template for each team."
    }
    
    private var step4StatusText: String {
        if !viewModel.hasParsed { return "Parse first." }
        if !templatesReady { return "Configure templates first." }
        if viewModel.isProcessing { return "Working…" }
        return "Creates run folder, copies PNGs, and writes Senior Banners.csv."
    }
    
    private func prepareTemplateSelectionTeams() {
        // Reuse SPA template selection UI: treat Team as TEAMNAME
        templateViewModel.detectedTeams = albums
        templateViewModel.hasAnalyzedData = !albums.isEmpty
        for team in albums {
            if templateViewModel.teamTemplates[team] == nil {
                templateViewModel.teamTemplates[team] = (individual: [], sportsMate: [])
            }
        }
    }
    
    private func syncTemplatesFromSelection() {
        prepareTemplateSelectionTeams()
        var map: [String: CSVBTemplateInfo] = [:]
        for team in albums {
            let cfg = templateViewModel.teamTemplates[team]
            if let selected = cfg?.individual.first, !selected.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                map[team] = selected
            }
        }
        viewModel.templateByTeam = map
        
        // If templates changed after CSV generation, mark CSV as stale
        if viewModel.csvGenerated {
            viewModel.csvGenerated = false
        }
    }
}


