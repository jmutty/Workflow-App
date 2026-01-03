import SwiftUI

struct SchoolModeView: View {
    let jobFolder: URL
    @EnvironmentObject var jobManager: JobManager
    
    @StateObject private var viewModel: SchoolBatchViewModel
    @State private var showingSheet = false
    @State private var showingResultAlert = false
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        _viewModel = StateObject(wrappedValue: SchoolBatchViewModel(jobFolder: jobFolder))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("School Operations")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create Batch File for Class Composites")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Builds a CSV from student images in class subfolders and copies images to the VOL folder.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { showingSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("Create Batch File")
                    }
                    .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Constants.Colors.brandTint)
                    .cornerRadius(Constants.UI.buttonCornerRadius)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Constants.Colors.cardBackground)
            .cornerRadius(Constants.UI.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                    .stroke(Constants.Colors.cardBorder, lineWidth: 1)
            )
        }
        .onAppear { viewModel.loadVOLFolders() }
        .sheet(isPresented: $showingSheet) { inputSheet }
        .onChange(of: viewModel.successMessage) { _, newValue in
            if newValue != nil { showingSheet = false }
        }
        .onChange(of: viewModel.lastResult) { _, newValue in
            if newValue != nil { showingResultAlert = true }
        }
        .alert("Batch Complete", isPresented: $showingResultAlert, presenting: viewModel.lastResult) { _ in
            Button("OK", role: .cancel) { showingResultAlert = false }
        } message: { result in
            VStack(alignment: .leading, spacing: 4) {
                Text("CSV: \(result.csvURL.lastPathComponent)")
                Text("Rows: \(result.rowCount)")
                Text("Images copied: \(result.imagesCopied)/\(result.totalImages)")
                if result.imagesRenamedOnConflict > 0 {
                    Text("Renamed on conflict: \(result.imagesRenamedOnConflict)")
                }
                Text(String(format: "Duration: %.2fs", result.duration))
            }
        }
    }
    
    private var inputSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Batch File for Class Composites")
                .font(.system(size: 20, weight: .bold))
            
            if viewModel.volFolders.count == 0 {
                Text("No VOL* folder found in the selected job folder.")
                    .foregroundColor(Constants.Colors.warningOrange)
                Button("Rescan") { viewModel.loadVOLFolders() }
                    .buttonStyle(.bordered)
            } else if viewModel.volFolders.count > 1 {
                Picker("VOL Folder", selection: $viewModel.selectedVOL) {
                    ForEach(viewModel.volFolders, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("School Name – Ex: HARRINGTON", text: $viewModel.schoolName)
                Text("Goes to SCHOOLNAME column")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("School Name Line 2 – Ex: ELEMENTARY SCHOOL", text: $viewModel.schoolNameLine2)
                Text("Goes to GROUPTEXT1 column")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("Year – Ex: 2025-2026", text: $viewModel.year)
                Text("Will become YEAR as 'Year - GROUPID' per class")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let err = viewModel.errorMessage { Text(err).foregroundColor(Constants.Colors.errorRed) }
            if let ok = viewModel.successMessage { Text(ok).foregroundColor(Constants.Colors.successGreen) }
            if viewModel.isRunning { ProgressView(viewModel.progressMessage).progressViewStyle(.linear) }
            
            HStack {
                Spacer()
                Button("Close") { showingSheet = false }
                Button(viewModel.isRunning ? "Working..." : "Create") {
                    Task { await viewModel.run() }
                }
                .disabled(viewModel.isRunning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}


