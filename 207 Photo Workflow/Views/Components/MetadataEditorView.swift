import SwiftUI

// MARK: - Metadata Editor View
struct MetadataEditorView: View {
    let imageURLs: [URL]
    let initialImageIndex: Int
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @StateObject private var metadataService = MetadataService()
    @State private var selectedImageIndex = 0
    @State private var copyrightText = ""
    @State private var originalCopyright = ""
    @State private var imageInfo: ImageInfo?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var hasUnsavedChanges = false
    @State private var showingFilePicker = false
    @State private var isLoadingReference = false
    @State private var newFileBaseName: String = ""
    @State private var selectedImageOverrideURL: URL?
    
    private var selectedImageURL: URL? {
        if let override = selectedImageOverrideURL {
            return override
        }
        guard !imageURLs.isEmpty else {
            print("📝 ERROR: imageURLs is empty in selectedImageURL")
            return nil 
        }
        
        let url = imageURLs[safe: selectedImageIndex] ?? imageURLs.first
        print("📝 selectedImageURL computed: \(url?.lastPathComponent ?? "nil")")
        print("📝 selectedImageIndex: \(selectedImageIndex), imageURLs.count: \(imageURLs.count)")
        
        if url == nil {
            print("📝 ERROR: selectedImageURL is nil - this might be the source of 'disn't have url'")
        }
        
        return url
    }
    
    var body: some View {
        if imageURLs.isEmpty {
            VStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No Images to Edit")
                    .font(.title2)
                    .fontWeight(.medium)
                Text("The metadata editor requires at least one image file.")
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Button("Close") {
                    onCancel()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top)
            }
            .frame(width: 400, height: 300)
        } else {
            VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Main content
            HStack(spacing: 0) {
                // Image preview (left side)
                imagePreviewSection
                    .frame(maxWidth: 400)
                
                Divider()
                
                // Metadata editing (right side)
                metadataEditingSection
                    .frame(minWidth: 500)
            }
            
            Divider()
            
            // Footer with actions
            footerView
        }
        .frame(width: 1000, height: 700)
        .background(Constants.Colors.background)
        .onAppear {
            print("📝 MetadataEditorView onAppear")
            print("📝 imageURLs count: \(imageURLs.count)")
            print("📝 initialImageIndex: \(initialImageIndex)")
            
            // Ensure we have valid URLs before proceeding
            guard !imageURLs.isEmpty else {
                print("📝 ERROR: No imageURLs provided to MetadataEditorView")
                errorMessage = "No images available for metadata editing"
                showingError = true
                return
            }
            
            // Set initial image index
            selectedImageIndex = max(0, min(initialImageIndex, imageURLs.count - 1))
            print("📝 Set selectedImageIndex to: \(selectedImageIndex)")
            
            // Verify the selected URL exists
            if let url = selectedImageURL {
                print("📝 Selected image URL: \(url.lastPathComponent)")
                print("📝 File exists: \(FileManager.default.fileExists(atPath: url.path))")
            } else {
                print("📝 ERROR: selectedImageURL is nil after setting selectedImageIndex")
            }
            
            loadImageMetadata()
        }
        .onChange(of: selectedImageIndex) { _, _ in
            if hasUnsavedChanges {
                // Save current changes before switching
                saveCurrentImage()
            }
            loadImageMetadata()
        }
        .alert(errorMessage?.hasPrefix("✅") == true ? "Success" : "Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .onKeyPress(KeyEquivalent.return) {
            saveCurrentImage()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("r")], phases: .down) { _ in
            showingFilePicker = true
            return .handled
        }
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Image Metadata")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if imageURLs.count > 1 {
                    Text("Image \(selectedImageIndex + 1) of \(imageURLs.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Navigation for multiple images
            if imageURLs.count > 1 {
                HStack(spacing: 8) {
                    Button("Previous") {
                        if selectedImageIndex > 0 {
                            selectedImageIndex -= 1
                        }
                    }
                    .disabled(selectedImageIndex == 0)
                    .buttonStyle(.bordered)
                    
                    Button("Next") {
                        if selectedImageIndex < imageURLs.count - 1 {
                            selectedImageIndex += 1
                        }
                    }
                    .disabled(selectedImageIndex >= imageURLs.count - 1)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
    }
    
    // MARK: - Image Preview Section
    private var imagePreviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image Preview")
                .font(.headline)
            
            // Image thumbnail
            if let imageURL = selectedImageURL {
                AsyncImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(4/3, contentMode: .fit)
                        .overlay(
                            VStack {
                                Image(systemName: "photo")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                }
                .frame(maxHeight: 300)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.2))
                    .aspectRatio(4/3, contentMode: .fit)
                    .frame(maxHeight: 300)
                    .overlay(
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Image Selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }
            
            // Image info
            if let info = imageInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Image Information")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: "Filename", value: info.filename)
                        InfoRow(label: "Dimensions", value: info.dimensions)
                        InfoRow(label: "File Size", value: info.formattedFileSize)
                        InfoRow(label: "Color Space", value: info.colorSpace)
                        InfoRow(label: "Resolution", value: info.formattedDPI)
                    }
                    .padding(.leading, 8)
                }
                .padding()
                .background(Constants.Colors.surface)
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Metadata Editing Section
    private var metadataEditingSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Copyright Information")
                .font(.headline)
            
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading metadata...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Current copyright display
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Copyright Notice")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text(originalCopyright.isEmpty ? "No copyright notice set" : originalCopyright)
                            .font(.body)
                            .foregroundColor(originalCopyright.isEmpty ? .secondary : .primary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Constants.Colors.surface)
                            .cornerRadius(8)
                    }
                    
                    // Filename editor
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filename")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        HStack(spacing: 8) {
                            TextField("New filename (without extension)", text: $newFileBaseName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { renameCurrentFile() }
                            if let ext = selectedImageURL?.pathExtension, !ext.isEmpty {
                                Text(".\(ext)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button("Rename File") {
                                renameCurrentFile()
                            }
                            .buttonStyle(.bordered)
                            .disabled((newFileBaseName.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty || selectedImageURL == nil)
                        }
                        Text("Invalid characters will be replaced with underscores")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Copyright editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("New Copyright Notice")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Spacer()
                            
                            if hasUnsavedChanges {
                                Text("• Unsaved changes")
                                    .font(.caption)
                                    .foregroundColor(Constants.Colors.warningOrange)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $copyrightText)
                                .font(.body)
                                .padding(8)
                                .background(Constants.Colors.background)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Constants.Colors.border, lineWidth: 1)
                                )
                                .frame(minHeight: 100, maxHeight: 150)
                                .onChange(of: copyrightText) { _, newValue in
                                    hasUnsavedChanges = newValue != originalCopyright
                                }
                            
                            Text("Enter the copyright notice to embed in the image EXIF data")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Quick templates
                    copyrightTemplatesSection
                    
                    // Reference image picker
                    referenceImageSection
                    
                    Spacer()
                }
            }
        }
        .padding()
        .disabled(isSaving)
    }
    
    // MARK: - Copyright Templates
    private var copyrightTemplatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Templates")
                .font(.subheadline)
                .fontWeight(.medium)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(copyrightTemplates, id: \.self) { template in
                        Button(template) {
                            copyrightText = template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
    
    // MARK: - Reference Image Section
    private var referenceImageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "photo.badge.plus")
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Copy from Reference Image")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Text("Select an image file that has the correct copyright metadata to copy from")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button(action: {
                    showingFilePicker = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text("Choose Reference Image...")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingReference)
                
                if isLoadingReference {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading metadata...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleReferenceImageSelection(result)
        }
    }
    
    // MARK: - Footer
    private var footerView: some View {
        HStack {
            // Keyboard shortcuts hint
            HStack(spacing: 16) {
                Text("⌘S Save")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("⌘R Reference")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Esc Cancel")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
                
                Button("Apply to Current") {
                    saveCurrentImage()
                }
                .buttonStyle(.bordered)
                .disabled(!hasUnsavedChanges || isSaving)
                
                if imageURLs.count > 1 {
                    Button("Apply to All") {
                        saveToAllImages()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(copyrightText.isEmpty || isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("Save") {
                        saveCurrentImage()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges || isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .padding()
    }
    
    // MARK: - Helper Methods
    
    private func loadImageMetadata() {
        print("📝 loadImageMetadata called")
        print("📝 selectedImageURL: \(selectedImageURL?.lastPathComponent ?? "nil")")
        
        guard let imageURL = selectedImageURL else {
            print("📝 No selectedImageURL - clearing metadata")
            imageInfo = nil
            originalCopyright = ""
            copyrightText = ""
            hasUnsavedChanges = false
            isLoading = false
            return
        }
        
        print("📝 Loading metadata for: \(imageURL.lastPathComponent)")
        isLoading = true
        // Initialize filename editor with current base name
        newFileBaseName = (imageURL.deletingPathExtension().lastPathComponent)
        
        Task {
            do {
                let info = try metadataService.getImageInfo(from: imageURL)
                print("📝 Loaded metadata successfully")
                await MainActor.run {
                    imageInfo = info
                    originalCopyright = info.copyright ?? ""
                    copyrightText = originalCopyright
                    hasUnsavedChanges = false
                    isLoading = false
                }
            } catch {
                print("📝 Error loading metadata: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                    isLoading = false
                }
            }
        }
    }
    
    private func sanitizeFileBaseName(_ base: String) -> String {
        // Replace characters commonly invalid in filenames
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = base.components(separatedBy: invalidChars).joined(separator: "_")
        while cleaned.contains("__") { cleaned = cleaned.replacingOccurrences(of: "__", with: "_") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return cleaned
    }
    
    private func renameCurrentFile() {
        guard let currentURL = selectedImageURL else { return }
        let baseInput = newFileBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseInput.isEmpty else { return }
        
        let ext = currentURL.pathExtension
        let sanitizedBase = sanitizeFileBaseName(baseInput)
        let newName = ext.isEmpty ? sanitizedBase : "\(sanitizedBase).\(ext)"
        if newName == currentURL.lastPathComponent {
            // No change
            return
        }
        let destination = currentURL.deletingLastPathComponent().appendingPathComponent(newName)
        // Prevent overwriting an existing file
        if FileManager.default.fileExists(atPath: destination.path) {
            errorMessage = "A file named '\(newName)' already exists."
            showingError = true
            return
        }
        
        do {
            try FileManager.default.moveItem(at: currentURL, to: destination)
            // Update local override so the editor points to the renamed file
            selectedImageOverrideURL = destination
            // Reload metadata to reflect new filename
            loadImageMetadata()
        } catch {
            errorMessage = "Failed to rename file: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func saveCurrentImage() {
        guard hasUnsavedChanges, let imageURL = selectedImageURL else { return }
        
        isSaving = true
        
        Task {
            do {
                try metadataService.writeCopyright(copyrightText, to: imageURL)
                await MainActor.run {
                    originalCopyright = copyrightText
                    hasUnsavedChanges = false
                    isSaving = false
                    
                    // Refresh image info
                    loadImageMetadata()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                    isSaving = false
                }
            }
        }
    }
    
    private func saveToAllImages() {
        guard !copyrightText.isEmpty else { return }
        
        isSaving = true
        
        Task {
            var successCount = 0
            var errors: [String] = []
            
            for imageURL in imageURLs {
                do {
                    try metadataService.writeCopyright(copyrightText, to: imageURL)
                    successCount += 1
                } catch {
                    errors.append("\(imageURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            await MainActor.run {
                isSaving = false
                
                if errors.isEmpty {
                    // All successful - close the editor
                    onSave()
                } else {
                    // Show summary of errors
                    errorMessage = "Applied to \(successCount) of \(imageURLs.count) images.\n\nErrors:\n" + errors.joined(separator: "\n")
                    showingError = true
                }
                
                // Refresh current image
                loadImageMetadata()
            }
        }
    }
    
    // MARK: - Reference Image Handling
    
    private func handleReferenceImageSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let referenceURL = urls.first else { return }
            loadCopyrightFromReference(referenceURL)
            
        case .failure(let error):
            print("📝 Error selecting reference image: \(error.localizedDescription)")
            errorMessage = "Failed to select reference image: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func loadCopyrightFromReference(_ url: URL) {
        print("📝 Loading copyright from reference image: \(url.lastPathComponent)")
        
        isLoadingReference = true
        
        Task {
            do {
                let referenceInfo = try metadataService.getImageInfo(from: url)
                
                await MainActor.run {
                    if let copyright = referenceInfo.copyright, !copyright.isEmpty {
                        copyrightText = copyright
                        hasUnsavedChanges = copyrightText != originalCopyright
                        print("📝 ✅ Copied copyright from reference: \(copyright)")
                        
                        // Show success feedback
                        errorMessage = "✅ Successfully copied copyright from \(url.lastPathComponent)"
                        showingError = true
                    } else {
                        print("📝 ⚠️ No copyright found in reference image")
                        errorMessage = "No copyright metadata found in the selected reference image."
                        showingError = true
                    }
                    
                    isLoadingReference = false
                }
            } catch {
                print("📝 ❌ Error reading reference image: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = "Failed to read metadata from reference image: \(error.localizedDescription)"
                    showingError = true
                    isLoadingReference = false
                }
            }
        }
    }
    
    // MARK: - Constants
    
    private let copyrightTemplates = [
        "© \(Calendar.current.component(.year, from: Date())) All Rights Reserved",
        "© \(Calendar.current.component(.year, from: Date())) Your Studio Name",
        "© \(Calendar.current.component(.year, from: Date())) 207 Photo",
        "All Rights Reserved",
        "Licensed for Editorial Use Only",
        "Not for Commercial Use"
    ]
}

// MARK: - Supporting Views

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

// MARK: - Array Safe Access Extension
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
