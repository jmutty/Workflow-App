import SwiftUI

// MARK: - Help Tooltip Component
struct HelpTooltipView: View {
    let text: String
    let icon: String
    let maxWidth: CGFloat
    
    @State private var showingHelp = false
    
    init(_ text: String, icon: String = "questionmark.circle", maxWidth: CGFloat = 300) {
        self.text = text
        self.icon = icon
        self.maxWidth = maxWidth
    }
    
    var body: some View {
        Button(action: {
            showingHelp.toggle()
        }) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showingHelp, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: maxWidth)
        }
    }
}

// MARK: - Contextual Help Panel
struct ContextualHelpView: View {
    let step: RenameWizardStep
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                
                Text("Quick Help")
                    .font(.headline)
                
                Spacer()
            }
            
            Text(helpContent.title)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Text(helpContent.description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if !helpContent.tips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tips:")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    ForEach(helpContent.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(tip)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Constants.Colors.cardBorder, lineWidth: 1)
        )
    }
    
    private var helpContent: HelpContent {
        switch step {
        case .setup:
            return HelpContent(
                title: "Choose Your Settings",
                description: "Select where your photos are located and how you want them named.",
                tips: [
                    "Extracted folder contains photos ready for renaming",
                    "CSV naming uses roster data for accurate player names",
                    "The app will automatically detect your CSV file"
                ]
            )
            
        case .preview:
            return HelpContent(
                title: "Review Before Renaming",
                description: "Check the proposed new names before making any changes to your files.",
                tips: [
                    "Click any photo to see it full size",
                    "Use the search box to find specific files",
                    "Orange highlights indicate naming conflicts"
                ]
            )
            
        case .resolveIssues:
            return HelpContent(
                title: "Fix Any Problems",
                description: "Resolve naming conflicts and pose count issues before proceeding.",
                tips: [
                    "Conflicts happen when two files would have the same name",
                    "Pose issues occur when players have too few or too many photos",
                    "You can manually edit names or skip problematic files"
                ]
            )
            
        case .execute:
            return HelpContent(
                title: "Rename Your Files",
                description: "Apply the new names to your photo files. A backup will be created automatically.",
                tips: [
                    "The process creates a backup mapping file",
                    "You can undo the rename operation if needed",
                    "Files are moved, not copied, to save disk space"
                ]
            )
        }
    }
}

// MARK: - Help Content Model
private struct HelpContent {
    let title: String
    let description: String
    let tips: [String]
}

// MARK: - Language Simplification Helpers
struct SimplifiedLanguage {
    // Replace technical terms with plain English
    static func simplify(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "preflight validation", with: "checking for issues")
            .replacingOccurrences(of: "bypass preflight errors", with: "proceed anyway")
            .replacingOccurrences(of: "conflict handling", with: "when names clash")
            .replacingOccurrences(of: "execute rename", with: "rename files")
            .replacingOccurrences(of: "validation report", with: "issue summary")
            .replacingOccurrences(of: "operation status", with: "current step")
            .replacingOccurrences(of: "file processing", with: "working with files")
            .replacingOccurrences(of: "metadata extraction", with: "reading photo information")
            .replacingOccurrences(of: "CSV parsing", with: "reading roster file")
            .replacingOccurrences(of: "batch operation", with: "multiple files at once")
    }
    
    // Provide user-friendly explanations for common terms
    static func explain(_ term: String) -> String {
        switch term.lowercased() {
        case "csv":
            return "A spreadsheet file containing player names and team information"
        case "pose count":
            return "The number of different photos taken of each player"
        case "conflict":
            return "When two files would end up with the same name"
        case "metadata":
            return "Hidden information stored inside photo files"
        case "barcode":
            return "A unique identifier linking photos to roster entries"
        case "source folder":
            return "The folder containing the photos you want to rename"
        case "extracted":
            return "Photos that have been processed and organized"
        case "backup":
            return "A safety copy in case you need to undo changes"
        default:
            return term
        }
    }
}

// MARK: - Preview
#if DEBUG
struct HelpTooltipView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Photo Location")
                HelpTooltipView("Choose the folder containing the photos you want to rename")
                Spacer()
            }
            
            ContextualHelpView(step: .setup)
            
            ContextualHelpView(step: .preview)
        }
        .padding()
    }
}
#endif
