import SwiftUI

// MARK: - Modern Operation Button
struct ModernOperationButton: View {
    let operation: Operation
    let status: OperationStatus
    let isHovered: Bool
    let action: () -> Void
    
    private var isDisabled: Bool {
        status.isActive
    }
    
    private var statusColor: Color {
        status.color
    }
    
    private var progressValue: Double? {
        if case .running(let progress) = status {
            return progress
        }
        return nil
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                iconSection
                textSection
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 15)
            .background(cardBackground)
            .scaleEffect(isHovered && !isDisabled ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: Constants.UI.animationDuration), value: isHovered)
    }
    
    // MARK: - Subviews
    private var iconSection: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(iconBackgroundGradient)
                .frame(width: 56, height: 56)
            
            // Progress ring if running
            if let progress = progressValue {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(statusColor, lineWidth: 3)
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: progress)
            }
            
            // Icon
            Image(systemName: operation.iconName)
                .font(.system(size: Constants.UI.mediumIconSize))
                .foregroundColor(isHovered && !isDisabled ? .white : statusColor)
        }
    }
    
    private var textSection: some View {
        VStack(spacing: 4) {
            Text(operation.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            statusText
        }
    }
    
    private var statusText: some View {
        Group {
            if case .running(let progress) = status {
                if let progress = progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(statusColor)
                } else {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                        Text("Running...")
                            .font(.system(size: 11))
                            .foregroundColor(statusColor)
                    }
                }
            } else {
                Text(status.description)
                    .font(.system(size: 11))
                    .foregroundColor(status == .ready ? .secondary : statusColor)
            }
        }
    }
    
    // MARK: - Computed Properties
    private var iconBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: isHovered && !isDisabled ?
                [statusColor, statusColor.opacity(0.7)] :
                [statusColor.opacity(0.2), statusColor.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Constants.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isHovered && !isDisabled ? statusColor.opacity(0.5) : Constants.Colors.cardBorder,
                        lineWidth: isHovered && !isDisabled ? 2 : 1
                    )
            )
            .shadow(
                color: isHovered && !isDisabled ? statusColor.opacity(0.3) : .clear,
                radius: 10
            )
    }
}

// MARK: - Preview
#if DEBUG
struct ModernOperationButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ModernOperationButton(
                operation: .renameFiles,
                status: .ready,
                isHovered: false,
                action: {}
            )
            
            ModernOperationButton(
                operation: .sortIntoTeams,
                status: .running(progress: 0.65),
                isHovered: false,
                action: {}
            )
            
            ModernOperationButton(
                operation: .createSPACSV,
                status: .completed(Date()),
                isHovered: true,
                action: {}
            )
            
            ModernOperationButton(
                operation: .sortTeamPhotos,
                status: .error("Test error"),
                isHovered: false,
                action: {}
            )
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
