import SwiftUI

struct RebuildModeView: View {
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: Constants.UI.smallIconSize))
                    .foregroundColor(Constants.Colors.brandTint)
                Text("Re-Build")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 16) {
                Button {
                    openWindow(id: "rebuildFullTeams")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "person.3.sequence")
                            .font(.system(size: 28))
                            .foregroundColor(Constants.Colors.brandTint)
                        Text("Full Teams (Ind & SM)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Constants.Colors.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .foregroundColor(Constants.Colors.textPrimary)
                    .background(Constants.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                            .stroke(Constants.Colors.cardBorder, lineWidth: 1)
                    )
                    .cornerRadius(Constants.UI.cornerRadius)
                }
                .buttonStyle(.plain)
                
                Button {
                    openWindow(id: "rebuildSmOnly")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.person.crop")
                            .font(.system(size: 28))
                            .foregroundColor(Constants.Colors.brandTint)
                        Text("SMs Only")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Constants.Colors.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .foregroundColor(Constants.Colors.textPrimary)
                    .background(Constants.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                            .stroke(Constants.Colors.cardBorder, lineWidth: 1)
                    )
                    .cornerRadius(Constants.UI.cornerRadius)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}


