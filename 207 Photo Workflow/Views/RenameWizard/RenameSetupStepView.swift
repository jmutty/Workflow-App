import SwiftUI

// MARK: - Setup Step View
struct RenameSetupStepView: View {
    @ObservedObject var coordinator: RenameWizardCoordinator
    
    @State private var isAnalyzing = false
    @State private var hasAnalyzedYet = false
    @State private var showingCustomFolderPicker = false
    @State private var showingCSVPicker = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
            headerSection
            
            // Configuration
            configurationSection
            
            // Status
            statusSection
            
            Spacer(minLength: 50)
        }
        .padding(30)
        .frame(maxWidth: 600)
        .onChange(of: coordinator.viewModel.config.sourceFolder) { _, _ in
            // Reset analysis state when configuration changes
            hasAnalyzedYet = false
        }
        .onChange(of: coordinator.viewModel.config.dataSource) { _, _ in
            // Reset analysis state when configuration changes  
            hasAnalyzedYet = false
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 48))
                .foregroundColor(Constants.Colors.brandTint)
            
            Text("Quick Setup")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Choose where to find your photos and how to name them")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Configuration Section
    private var configurationSection: some View {
        VStack(spacing: 20) {
            // Source Folder Selection
            sourceFolderCard
            
            // Data Source Selection  
            dataSourceCard
        }
    }
    
    private var sourceFolderCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Photo Location")
                    .font(.headline)
                Spacer()
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                    .help("Choose the folder containing the photos you want to rename")
            }
            
            Picker("Source", selection: $coordinator.viewModel.config.sourceFolder) {
                ForEach(SourceFolder.allCases, id: \.self) { folder in
                    Text(folder.rawValue).tag(folder)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: coordinator.viewModel.config.sourceFolder) { _, newValue in
                if newValue == .custom {
                    showingCustomFolderPicker = true
                }
            }
            
            // Custom folder selection
            if coordinator.viewModel.config.sourceFolder == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    if let customPath = coordinator.viewModel.config.customSourcePath {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                            Text(customPath.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                            Spacer()
                            Button("Change") {
                                showingCustomFolderPicker = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(Constants.Colors.surface)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
                        )
                    } else {
                        Button(action: {
                            showingCustomFolderPicker = true
                        }) {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("Select Custom Folder")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            
            Text(sourceFolderDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
        .fileImporter(
            isPresented: $showingCustomFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleCustomFolderSelection(result)
        }
    }
    
    private var dataSourceCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: coordinator.viewModel.hasCSV ? "doc.text.fill" : "textformat.abc")
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Naming Method")
                    .font(.headline)
                Spacer()
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                    .help("Choose how to generate the new file names")
            }
            
            Picker("Data Source", selection: $coordinator.viewModel.config.dataSource) {
                ForEach(DataSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!coordinator.viewModel.hasCSV && coordinator.viewModel.config.dataSource == .csv)
            
            Text(dataSourceDescription)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if coordinator.viewModel.config.dataSource == .csv {
                csvSelectionControls
            }
        }
        .padding(20)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    private var csvSelectionControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let csvURL = coordinator.viewModel.currentCSVURL {
                Text("Using CSV: \(csvURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No CSV selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("Choose CSV File…") {
                showingCSVPicker = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .fileImporter(
                isPresented: $showingCSVPicker,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task {
                            await coordinator.viewModel.useCSV(from: url)
                            coordinator.updateFromViewModel()
                        }
                    }
                case .failure(let error):
                    print("❌ CSV selection failed: \(error)")
                }
            }
        }
    }
    
    // MARK: - Status Section
    private var statusSection: some View {
        VStack(spacing: 20) {
            if isAnalyzing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Scanning photos...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 80)
            } else {
                statusCards
            }
        }
    }
    
    private var statusCards: some View {
        VStack(spacing: 16) {
            // Status summary
            HStack(spacing: 20) {
                // Photos Found
                StatusCard(
                    icon: "photo.stack.fill",
                    title: "Photos Found",
                    value: "\(coordinator.viewModel.filesToRename.count)",
                    color: coordinator.viewModel.filesToRename.isEmpty ? .secondary : Constants.Colors.successGreen
                )
                
                // CSV Status
                StatusCard(
                    icon: coordinator.viewModel.hasCSV ? "checkmark.circle.fill" : "xmark.circle.fill",
                    title: "CSV File",
                    value: coordinator.viewModel.hasCSV ? "Found" : "Missing",
                    color: coordinator.viewModel.hasCSV ? Constants.Colors.successGreen : Constants.Colors.warningOrange
                )
                
                // Issues Count
                StatusCard(
                    icon: coordinator.issueCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
                    title: "Issues",
                    value: coordinator.issueCount > 0 ? "\(coordinator.issueCount)" : "None",
                    color: coordinator.issueCount > 0 ? Constants.Colors.warningOrange : Constants.Colors.successGreen
                )
            }
            
            // Action buttons
            VStack(spacing: 12) {
                if !hasAnalyzedYet || coordinator.viewModel.filesToRename.isEmpty {
                    Button("Scan for Photos") {
                        analyzeIfReady()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.headline)
                    .disabled(isAnalyzing)
                }
                
                // Undo button for restoring original filenames
                if coordinator.viewModel.lastRenameOperationId != nil {
                    Button("Undo Previous Rename") {
                        Task {
                            await coordinator.viewModel.undoLastRename()
                            coordinator.updateFromViewModel()
                            // Refresh the analysis after undo
                            await coordinator.viewModel.analyzeFiles()
                            coordinator.updateFromViewModel()
                        }
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.orange)
                    .help("Restore original filenames and move files back to Extracted folder")
                    .onAppear {
                        print("🔘 Setup undo button appeared! lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
                    }
                } else {
                    // Debug: Show why undo button is not showing
                    Text("")
                        .onAppear {
                            print("🔘 ❌ Setup undo button NOT showing. lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
                        }
                }
            }
        }
    }
    
    // MARK: - Helper Properties
    private var sourceFolderDescription: String {
        switch coordinator.viewModel.config.sourceFolder {
        case .extracted:
            return "Photos that have been processed and are ready for renaming"
        case .output:
            return "Raw photos directly from the camera or import"
        case .custom:
            if let customPath = coordinator.viewModel.config.customSourcePath {
                return "Uses photos from: \(customPath.path)"
            } else {
                return "Select a custom folder containing your photos"
            }
        }
    }
    
    private func handleCustomFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                coordinator.viewModel.config.customSourcePath = url
                print("📁 Selected custom folder: \(url.path)")
            }
        case .failure(let error):
            print("❌ Custom folder selection failed: \(error)")
            // Optionally show an error to the user
        }
    }
    
    private var dataSourceDescription: String {
        switch coordinator.viewModel.config.dataSource {
        case .csv:
            if coordinator.viewModel.hasCSV {
                return "Use player names and team information from the CSV roster file"
            } else {
                return "No CSV file found in the job folder"
            }
        case .filenames:
            return "Extract player and team names from the current file names"
        }
    }
    
    // MARK: - Helper Methods
    private func analyzeIfReady() {
        guard !isAnalyzing else { return }
        
        isAnalyzing = true
        Task {
            await coordinator.viewModel.analyzeFiles()
            coordinator.updateFromViewModel()
            await MainActor.run {
                isAnalyzing = false
                hasAnalyzedYet = true
            }
        }
    }
}

// MARK: - Status Card Component
private struct StatusCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Preview
#if DEBUG
struct RenameSetupStepView_Previews: PreviewProvider {
    static var previews: some View {
        RenameSetupStepView(
            coordinator: RenameWizardCoordinator(
                jobFolder: URL(fileURLWithPath: "/tmp/test"),
                jobManager: JobManager()
            )
        )
    }
}
#endif
