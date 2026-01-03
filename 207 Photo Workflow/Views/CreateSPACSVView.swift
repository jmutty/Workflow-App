import SwiftUI
import UniformTypeIdentifiers

struct CreateSPACSVView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var viewModel: CreateSPACSVViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingCSVEditor = false
    @State private var tempCSVURL: URL?
    @State private var showingImagePreview = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []
    @State private var showingTemplateSelection = false
    @State private var showingError = false
    @State private var showManualList = false
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        _viewModel = StateObject(wrappedValue: CreateSPACSVViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configuration
                    analysisSection
                    if !viewModel.preflightIssues.isEmpty {
                        GroupBox("Preflight: Missing Second Pose") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(viewModel.preflightIssues.count) item(s) require attention for multi-pose templates.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 6) {
                                        ForEach(viewModel.preflightIssues) { issue in
                                            Text("\(issue.teamName) – \(issue.playerName) missing pose \(issue.requiredPose) for \(issue.templateFile)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .frame(maxHeight: 120)
                            }
                            .padding(8)
                        }
                    }
                    if viewModel.isAnalyzing || viewModel.isProcessing {
                        DetailedProgressView(
                            progress: viewModel.operationProgress,
                            currentFile: viewModel.currentOperation,
                            filesCompleted: viewModel.filesCompleted,
                            totalFiles: max(viewModel.totalFiles, 1),
                            status: viewModel.isAnalyzing ? "Analyzing photos..." : "Generating CSV...",
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
            viewModel.loadExistingCSVIfPresent()
            Task { await runAnalyze() }
        }
        .sheet(isPresented: $showingCSVEditor) {
            if let csvURL = tempCSVURL {
                CSVEditorView(
                    url: csvURL,
                    sourceFolderURL: jobFolder.appendingPathComponent(Constants.Folders.extracted),
                    allImageURLs: enumerateAllImageURLs(),
                    onPreview: { url in
                        // Open large preview while editor is up
                        previewURLs = enumerateAllImageURLs()
                        previewURL = url
                        showingImagePreview = true
                    },
                    onClose: {
                        // Reload edited CSV content back into the view model
                        if let csvURL = tempCSVURL, let content = try? String(contentsOf: csvURL, encoding: .utf8) {
                            viewModel.generatedCSV = content
                        }
                        // Ensure any large preview sheet is also closed when CSV editor closes
                        showingImagePreview = false
                        previewURL = nil
                        previewURLs = []
                        showingCSVEditor = false
                    }
                )
            } else {
                Text("No CSV to edit").frame(width: 400, height: 200)
            }
        }
        .sheet(isPresented: $showingImagePreview) {
            if let url = previewURL {
                ImagePreviewView(imageURL: url, allImageURLs: previewURLs, initialIndex: previewURLs.firstIndex(of: url) ?? 0)
                    .id(url)
            } else {
                Text("No image selected").frame(width: 300, height: 200)
            }
        }
        .sheet(isPresented: $showingTemplateSelection) {
            TemplateSelectionView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingError) {
            ErrorDetailView(
                title: "Create SPA CSV Error",
                message: viewModel.lastError ?? "Unknown error",
                suggestion: "Review configuration and try again.",
                details: nil,
                onRetry: { showingError = false }
            )
            .frame(width: 600, height: 360)
        }
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Create SPA-Ready CSV").font(.title)
            Text("Job Folder: \(jobFolder.lastPathComponent)")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
    
    private var configuration: some View {
        Button(action: { showingTemplateSelection = true }) {
            HStack(spacing: 10) {
                Image(systemName: "paintbrush").foregroundColor(.white)
                Text("Configure Templates").foregroundColor(.white).font(.headline)
                Spacer()
                if viewModel.templatesConfigured {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.white)
                        Text("Configured").font(.caption).foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Constants.Colors.brandTint)
            .cornerRadius(12)
        }
        .disabled(!viewModel.hasAnalyzedData)
        .padding(.horizontal, 8)
    }
    
    private var analysisSection: some View {
        GroupBox("Analysis Results") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isAnalyzing {
                    ProgressView("Analyzing photos...")
                        .frame(height: 120)
                } else if viewModel.hasAnalyzedData {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Photos analyzed: \(viewModel.totalPhotoCount)").font(.headline)
                            Text("Regular photos: \(viewModel.regularPhotos.count)").font(.subheadline)
                            HStack(spacing: 6) {
                                Button(action: { withAnimation { showManualList.toggle() } }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: showManualList ? "chevron.down" : "chevron.right")
                                        Text("Manual photos: \(viewModel.manualPhotos.count)")
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(viewModel.manualPhotos.count > 0 ? Constants.Colors.warningOrange : .secondary)
                            }
                            Text("Teams detected: \(viewModel.detectedTeams.count)").font(.subheadline)
                            if viewModel.missingSecondPoseCount > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                    Text("Missing second pose links: \(viewModel.missingSecondPoseCount)")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                        }
                        Spacer()
                        if showManualList && !viewModel.manualPhotos.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Manual filenames:").font(.caption).foregroundColor(.secondary)
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(viewModel.manualPhotos, id: \.self) { rec in
                                            Text(rec.fileName)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .frame(maxHeight: 140)
                            }
                            .padding(.top, 6)
                        }
                    }
                    if !viewModel.detectedTeams.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Teams:").font(.subheadline).fontWeight(.medium)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                                ForEach(viewModel.detectedTeams, id: \.self) { team in
                                    Text(team)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Constants.Colors.brandSoftFill)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                } else {
                    VStack {
                        Image(systemName: "doc.text").font(.system(size: 48)).foregroundColor(.secondary)
                        Text("No photos analyzed yet").foregroundColor(.secondary)
                    }.frame(height: 120)
                }
            }
            .padding()
        }
    }
    
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
            // Removed explicit Analyze / Configure buttons per UX cleanup
            if viewModel.templatesConfigured && !viewModel.csvGenerated {
                Button("Generate CSV") { Task { await runGenerate() } }
                    .buttonStyle(.borderedProminent)
            }
            if viewModel.csvGenerated {
                Button("Preview CSV") { Task { await openCSVInEditor() } }
                    .buttonStyle(.bordered)
                
                if viewModel.lastCSVOperationId != nil {
                    Button("Undo CSV Save") { 
                        Task { await undoCSVOperation() }
                    }
                    .buttonStyle(.bordered)
                    .help("Restore previous CSV file and undo folder changes")
                }
                
                Button("Save & Complete") { Task { await confirmSaveAndComplete() } }
                .buttonStyle(.borderedProminent)
            }
            // Bottom menu removed per UX cleanup
        }
        .padding()
    }

    // MARK: - Ops with JobManager status + error handling
    private func runAnalyze() async {
        jobManager.updateOperationStatus(.createSPACSV, status: .running(progress: nil))
        await viewModel.analyzePhotos()
        if let err = viewModel.lastError {
            jobManager.updateOperationStatus(.createSPACSV, status: .error(err))
            showingError = true
        } else {
            jobManager.updateOperationStatus(.createSPACSV, status: .completed(Date()))
        }
    }
    
    private func runGenerate() async {
        jobManager.updateOperationStatus(.createSPACSV, status: .running(progress: nil))
        await viewModel.generateCSV()
        if let err = viewModel.lastError {
            jobManager.updateOperationStatus(.createSPACSV, status: .error(err))
            showingError = true
        } else {
            jobManager.updateOperationStatus(.createSPACSV, status: .completed(Date()))
        }
    }
    
    private func runSave() async {
        jobManager.updateOperationStatus(.createSPACSV, status: .running(progress: nil))
        let ok = await viewModel.saveCSV()
        if ok {
            jobManager.updateOperationStatus(.createSPACSV, status: .completed(Date()))
            dismiss()
        } else {
            let err = viewModel.lastError ?? "Failed to save CSV"
            jobManager.updateOperationStatus(.createSPACSV, status: .error(err))
            showingError = true
        }
    }

    private func enumerateAllImageURLs() -> [URL] {
        let extracted = jobFolder.appendingPathComponent(Constants.Folders.extracted)
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Constants.FileExtensions.isImageFile($0) }
    }
    
    private func openCSVInEditor() async {
        // Write generated CSV to a temp file and open the inline CSV editor
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spa_preview_\(UUID().uuidString).csv")
        do {
            try viewModel.generatedCSV.write(to: tmp, atomically: true, encoding: .utf8)
            tempCSVURL = tmp
            showingCSVEditor = true
        } catch {
            // Fall back to error view
            // In this screen we keep it simple; CreateSPACSVView already has error support for main ops
        }
    }

    private func confirmSaveAndComplete() async {
        // If SPA Ready.csv exists, confirm overwrite
        let dest = viewModel.existingCSVURL()
        let exists = FileManager.default.fileExists(atPath: dest.path)
        if exists {
            // Use a simple inline confirm via ErrorDetailView-like flow is overkill; just overwrite for now.
            // If you want a native confirm sheet, we can add one. For now, overwrite behavior:
            await runSave()
        } else {
            await runSave()
        }
    }
    
    private func undoCSVOperation() async {
        jobManager.updateOperationStatus(.createSPACSV, status: .running(progress: nil))
        await viewModel.undoLastCSVOperation()
        
        if let err = viewModel.lastError {
            jobManager.updateOperationStatus(.createSPACSV, status: .error(err))
            showingError = true
        } else {
            jobManager.updateOperationStatus(.createSPACSV, status: .completed(Date()))
        }
    }
}


