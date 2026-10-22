import SwiftUI
import UIKit

@safe
struct ShellIndicatorView: View {
    @Environment(ShellIndicatorState.self) private var shellState

    private enum ChipTypography {
        static let maxPointSize: CGFloat = 9
        static let minPointSize: CGFloat = 7
        static let minimumScaleFactor: CGFloat = minPointSize / maxPointSize
        static let uiFont = UIFont.systemFont(ofSize: maxPointSize, weight: .regular)
    }

    static let dotDiameter: CGFloat = 8.5
    static let chipVerticalPadding: CGFloat = 3
    static let chipStrokeLineWidth: CGFloat = 1
    /// Shared strip-height metric used for both shelf positioning and local layout.
    static var shelfCenteringHeight: CGFloat {
        max(
            dotDiameter,
            ChipTypography.uiFont.lineHeight + (chipVerticalPadding * 2) + chipStrokeLineWidth
        )
    }

    private let dotSize: CGFloat = Self.dotDiameter
    private let dotSpacing: CGFloat = 6
    private let horizontalEdgeInset: CGFloat = 35
    private let horizontalLabelPadding: CGFloat = 5
    private let centerContentGap: CGFloat = 8
    private let sideChipMinimumWidth: CGFloat = 95
    private let chipStrokeOpacity: CGFloat = 0.55
    private let chipForegroundOpacity: CGFloat = 0.82

    var body: some View {
        let displayedWindowCount = max(1, shellState.windowCount)
        let centerReservedWidth = dotClusterBaseWidth(windowCount: displayedWindowCount) + (centerContentGap * 2)

        HStack(spacing: 0) {
            indicatorLane(
                shellState.activeWorkingDirectoryLabel,
                iconName: "folder",
                isLeadingSide: true
            )

            dotIndicators(displayedWindowCount: displayedWindowCount)
                .frame(width: centerReservedWidth, alignment: .center)

            indicatorLane(
                shellState.activeGitBranchLabel,
                iconName: "arrow.triangle.branch",
                isLeadingSide: false
            )
        }
        .frame(height: stripHeight)
        .padding(.horizontal, horizontalEdgeInset)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.2), value: shellState.activeWorkingDirectoryLabel)
        .animation(.easeInOut(duration: 0.2), value: shellState.activeGitBranchLabel)
    }

    private var stripHeight: CGFloat {
        Self.shelfCenteringHeight
    }

    @ViewBuilder
    private func dotIndicators(displayedWindowCount: Int) -> some View {
        let displayedActivePosition = min(
            max(0, shellState.activePosition),
            displayedWindowCount - 1
        )
        HStack(spacing: dotSpacing) {
            ForEach(0..<displayedWindowCount, id: \.self) { position in
                let isActive = position == displayedActivePosition
                let hasUnread = shellState.unreadPositions.contains(position)

                ShellDot(
                    isActive: isActive,
                    hasUnread: hasUnread,
                    fullSize: dotSize,
                    smallSize: dotSize * 0.7
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shellState.windowCount)
        .animation(.easeOut(duration: 0.15), value: shellState.activePosition)
        .animation(.easeInOut(duration: 0.2), value: shellState.unreadPositions)
    }

    private func dotClusterBaseWidth(windowCount: Int) -> CGFloat {
        let safeWindowCount = max(1, windowCount)
        guard safeWindowCount > 1 else { return dotSize }
        let inactiveDotSize = dotSize * 0.7
        return dotSize + (CGFloat(safeWindowCount - 1) * (inactiveDotSize + dotSpacing))
    }

    @ViewBuilder
    private func indicatorLane(_ text: String, iconName: String, isLeadingSide: Bool) -> some View {
        HStack(spacing: 0) {
            if UIDevice.current.userInterfaceIdiom == .pad {
                if isLeadingSide {
                    Spacer(minLength: 0)
                    indicatorLabel(text, iconName: iconName)
                        .padding(.trailing, 20)
                } else {
                    indicatorLabel(text, iconName: iconName)
                        .padding(.leading, 20)
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
                indicatorLabel(text, iconName: iconName)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: isLeadingSide ? .trailing : .leading)
    }

    @ViewBuilder
    private func indicatorLabel(_ text: String, iconName: String) -> some View {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = normalizedText.isEmpty ? " " : normalizedText
        let isVisible = !normalizedText.isEmpty
        let iconPointSize = ChipTypography.maxPointSize - 1

        // Base layer: non-greedy, establishes the width of the chip based on content.
        // It shrinks properly because it is a standard HStack and respects the parent lane's max width proposal.
        // We use spacing: 3 to match the exact 3pt minimum gap between the icon and the text in the overlay
        // (compensating for the optical padding built into SF Symbols).
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: iconPointSize, weight: .bold, design: .default))
            Text(displayText)
                .font(.system(size: ChipTypography.maxPointSize, weight: .bold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(ChipTypography.minimumScaleFactor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, Self.chipVerticalPadding)
        .opacity(0) // Hide the sizing template
        .frame(minWidth: sideChipMinimumWidth)
        .background {
            Capsule(style: .continuous)
                .fill(AppTheme.terminalBackground)
        }
        .overlay {
            // Flexible layout: bounded entirely by the size established by the base layer above.
            HStack(spacing: 0) {
                Image(systemName: iconName)
                    .font(.system(size: iconPointSize, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.primaryText.opacity(chipForegroundOpacity))

                Spacer(minLength: 3)

                Text(displayText)
                    .font(.system(size: ChipTypography.maxPointSize, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(ChipTypography.minimumScaleFactor)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.primaryText.opacity(chipForegroundOpacity))

                // minLength: 0 combined with the .padding(.horizontal, 7) on the container
                // guarantees exactly 7pt minimum space from the end of the text to the right wall.
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(AppTheme.primaryText.opacity(chipStrokeOpacity), lineWidth: Self.chipStrokeLineWidth)
        }
        .opacity(isVisible ? 1 : 0)
        .padding(.horizontal, horizontalLabelPadding)
    }
}

private struct ShellDot: View {
    let isActive: Bool
    let hasUnread: Bool
    let fullSize: CGFloat
    let smallSize: CGFloat

    @State private var isPulsed = false

    var body: some View {
        let scale = hasUnread && isPulsed ? fullSize / smallSize : 1.0

        Circle()
            .fill(
                hasUnread
                    ? Color.red
                    : (isActive ? AppTheme.primaryText : AppTheme.primaryText.opacity(0.3))
            )
            .frame(width: isActive ? fullSize : smallSize, height: isActive ? fullSize : smallSize)
            .scaleEffect(scale)
            .animation(.easeInOut(duration: 0.3), value: isPulsed)
            .onChange(of: hasUnread) {
                isPulsed = false
            }
            .task(id: hasUnread) {
                guard hasUnread else { return }
                while !Task.isCancelled {
                    isPulsed = true
                    try? await Task.sleep(for: .seconds(0.3))
                    guard !Task.isCancelled else { return }
                    isPulsed = false
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                }
            }
    }
}
