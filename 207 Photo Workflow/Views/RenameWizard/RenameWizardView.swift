import SwiftUI

// MARK: - Main Wizard View
struct RenameWizardView: View {
    let jobFolder: URL
    let jobManager: JobManager
    
    @StateObject private var coordinator: RenameWizardCoordinator
    @Environment(\.dismiss) private var dismiss
    
    init(jobFolder: URL, jobManager: JobManager) {
        self.jobFolder = jobFolder
        self.jobManager = jobManager
        self._coordinator = StateObject(wrappedValue: RenameWizardCoordinator(jobFolder: jobFolder, jobManager: jobManager))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress Header
            wizardHeader
            
            Divider()
            
            // Main Content Area
            if coordinator.currentStep == .resolveIssues {
                currentStepView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    currentStepView
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Navigation Footer
            navigationFooter
        }
        .frame(minWidth: Constants.UI.renameWindowWidth, minHeight: Constants.UI.renameWindowHeight)
        .preferredColorScheme(jobManager.colorScheme)
        .onAppear {
            print("🔘 RenameWizardView appeared! coordinator.viewModel.lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
            Task { 
                await coordinator.viewModel.initialize()
                coordinator.updateFromViewModel()
                print("🔘 After wizard initialization: coordinator.viewModel.lastRenameOperationId: \(String(describing: coordinator.viewModel.lastRenameOperationId))")
            }
        }
        .onChange(of: coordinator.viewModel.filesToRename) { _, _ in
            coordinator.updateFromViewModel()
        }
        .onChange(of: coordinator.viewModel.validationReport) { _, _ in
            coordinator.updateFromViewModel()
        }
        .onChange(of: coordinator.viewModel.poseCountValidation) { _, _ in
            coordinator.updateFromViewModel()
        }
        .sheet(isPresented: $coordinator.showingImagePreview) {
            if let operation = coordinator.selectedImageOperation {
                ImagePreviewView(
                    imageURL: operation.sourceURL,
                    allImageURLs: coordinator.previewImageURLs.isEmpty ? nil : coordinator.previewImageURLs,
                    initialIndex: coordinator.previewStartIndex
                )
            }
        }
    }
    
    // MARK: - Header with Progress
    private var wizardHeader: some View {
        VStack(spacing: 12) {
            // Title
            HStack {
                Image(systemName: "pencil.and.outline")
                    .font(.title2)
                    .foregroundColor(Constants.Colors.brandTint)
                
                Text("Rename Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            
            // Step Progress Indicator
            stepProgressIndicator
        }
        .padding()
        .background(Constants.Colors.surface)
    }
    
    private var stepProgressIndicator: some View {
        HStack(spacing: 0) {
            ForEach(RenameWizardStep.allCases, id: \.self) { step in
                // Skip issues step if no issues
                if step == .resolveIssues && !coordinator.shouldShowIssuesStep() {
                    EmptyView()
                } else {
                    stepIndicator(for: step)
                    
                    // Connector line (except for last step)
                    if step != RenameWizardStep.allCases.last && 
                       !(step == .preview && !coordinator.shouldShowIssuesStep()) {
                        stepConnector(isActive: coordinator.currentStep.rawValue > step.rawValue)
                    }
                }
            }
        }
    }
    
    private func stepIndicator(for step: RenameWizardStep) -> some View {
        let isActive = coordinator.currentStep == step
        let isCompleted = coordinator.currentStep.rawValue > step.rawValue
        let isAccessible = step.rawValue <= coordinator.currentStep.rawValue
        
        return Button(action: {
            if isAccessible {
                coordinator.goToStep(step)
            }
        }) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isActive ? Constants.Colors.brandTint : 
                              isCompleted ? Constants.Colors.successGreen : 
                              Color.secondary.opacity(0.3))
                        .frame(width: 32, height: 32)
                    
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Image(systemName: step.icon)
                            .foregroundColor(isActive ? .white : .secondary)
                            .font(.system(size: 12))
                    }
                }
                
                Text(step.title)
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundColor(isActive ? Constants.Colors.brandTint : .secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAccessible)
    }
    
    private func stepConnector(isActive: Bool) -> some View {
        Rectangle()
            .fill(isActive ? Constants.Colors.successGreen : Color.secondary.opacity(0.3))
            .frame(width: 40, height: 2)
            .padding(.top, 16)
    }
    
    // MARK: - Current Step Content
    @ViewBuilder
    private var currentStepView: some View {
        switch coordinator.currentStep {
        case .setup:
            RenameSetupStepView(coordinator: coordinator)
        case .preview:
            RenamePreviewStepView(coordinator: coordinator)
        case .resolveIssues:
            RenameIssuesStepView(coordinator: coordinator)
        case .execute:
            RenameExecuteStepView(coordinator: coordinator)
        }
    }
    
    // MARK: - Navigation Footer
    private var navigationFooter: some View {
        HStack {
            // Issue indicator (if any)
            if coordinator.issueCount > 0 && coordinator.currentStep != .resolveIssues {
                Label("\(coordinator.issueCount) issues found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(Constants.Colors.warningOrange)
                    .font(.caption)
            }
            
            Spacer()
            
            // Navigation buttons
            HStack(spacing: 12) {
                if coordinator.canGoBack {
                    Button("← Back") {
                        coordinator.goBack()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                }
                
                if coordinator.canProceedToNext {
                    Button(nextButtonTitle) {
                        coordinator.goToNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                }
            }
        }
        .padding()
        .background(Constants.Colors.surface)
    }
    
    private var nextButtonTitle: String {
        switch coordinator.currentStep {
        case .setup:
            return "Continue →"
        case .preview:
            return coordinator.hasUnresolvedIssues ? "Fix Issues →" : "Rename Files →"
        case .resolveIssues:
            return "Rename Files →"
        case .execute:
            return "Done"
        }
    }
}

// MARK: - Preview
#if DEBUG
struct RenameWizardView_Previews: PreviewProvider {
    static var previews: some View {
        RenameWizardView(
            jobFolder: URL(fileURLWithPath: "/tmp/test"),
            jobManager: JobManager()
        )
    }
}
#endif
