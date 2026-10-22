import SwiftUI

enum SpacebarQuickShellOverlayLayout {
    static let cardHeight: CGFloat = 56
    static let cardSpacing: CGFloat = 8
    static let containerPadding: CGFloat = 5
    static let cardCornerRadius: CGFloat = 16
    static let maxColumns = 2
    static let singleColumnCardWidth: CGFloat = 236
    static let multiColumnCardWidth: CGFloat = 166
    static let gapFromSpacebar: CGFloat = 42
    static let openAnimation: Animation = .spring(duration: 0.32, bounce: 0.24)
    static let closeAnimation: Animation = .spring(duration: 0.18, bounce: 0.04)
    static let hiddenScaleX: CGFloat = 0.78
    static let hiddenScaleY: CGFloat = 0.64
    static let hiddenRiseOffset: CGFloat = 18
    static let highlightSelectionAnimation: Animation = .spring(duration: 0.2, bounce: 0.18)
    static let glassHoverAnimation: Animation = .spring(duration: 0.2, bounce: 0.16)
    static let hoverHaloDistance: CGFloat = 20
    static let maxHoverGlassExpansion: CGFloat = 2.1

    static func columnCount(for shellCount: Int) -> Int {
        min(maxColumns, max(shellCount, 1))
    }

    static func rowCount(for shellCount: Int) -> Int {
        let columns = columnCount(for: shellCount)
        let normalizedShellCount = max(shellCount, 1)
        return Int(ceil(Double(normalizedShellCount) / Double(columns)))
    }

    static func cardWidth(for shellCount: Int) -> CGFloat {
        shellCount <= 1 ? singleColumnCardWidth : multiColumnCardWidth
    }

    static func contentWidth(for shellCount: Int) -> CGFloat {
        let columns = columnCount(for: shellCount)
        let spacingCount = max(columns - 1, 0)
        return (CGFloat(columns) * cardWidth(for: shellCount)) + (CGFloat(spacingCount) * cardSpacing)
    }

    static func contentHeight(for shellCount: Int) -> CGFloat {
        let rows = rowCount(for: shellCount)
        let spacingCount = max(rows - 1, 0)
        return (CGFloat(rows) * cardHeight) + (CGFloat(spacingCount) * cardSpacing)
    }

    static func totalSize(for shellCount: Int) -> CGSize {
        CGSize(
            width: contentWidth(for: shellCount) + (containerPadding * 2),
            height: contentHeight(for: shellCount) + (containerPadding * 2)
        )
    }

    static func menuRect(keyWidth: CGFloat, shellCount: Int) -> CGRect {
        let size = totalSize(for: shellCount)
        let minX = (keyWidth - size.width) / 2
        let minY = -(gapFromSpacebar + size.height)
        return CGRect(origin: CGPoint(x: minX, y: minY), size: size)
    }

    static func cardFrames(keyWidth: CGFloat, shellCount: Int) -> [CGRect] {
        guard shellCount > 0 else { return [] }

        let menuRect = menuRect(keyWidth: keyWidth, shellCount: shellCount)
        let columns = columnCount(for: shellCount)
        let rows = rowCount(for: shellCount)
        let cardWidth = cardWidth(for: shellCount)
        let originX = menuRect.minX + containerPadding
        let originY = menuRect.minY + containerPadding

        var frames: [CGRect] = []
        frames.reserveCapacity(shellCount)

        for index in 0..<shellCount {
            let rowFromBottom = index / columns
            let column = index % columns
            let row = (rows - 1) - rowFromBottom
            let x = originX + (CGFloat(column) * (cardWidth + cardSpacing))
            let y = originY + (CGFloat(row) * (cardHeight + cardSpacing))
            frames.append(CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
        }

        return frames
    }

    static func localCardFrame(index: Int, shellCount: Int) -> CGRect {
        guard index >= 0 else { return .zero }
        let columns = columnCount(for: shellCount)
        let rows = rowCount(for: shellCount)
        let cardWidth = cardWidth(for: shellCount)
        let rowFromBottom = index / columns
        let column = index % columns
        let row = (rows - 1) - rowFromBottom
        let x = containerPadding + (CGFloat(column) * (cardWidth + cardSpacing))
        let y = containerPadding + (CGFloat(row) * (cardHeight + cardSpacing))
        return CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
    }

    static func shellIndex(forRow row: Int, column: Int, shellCount: Int) -> Int? {
        guard shellCount > 0 else { return nil }

        let columns = columnCount(for: shellCount)
        let rows = rowCount(for: shellCount)
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }

        let rowFromBottom = (rows - 1) - row
        let index = (rowFromBottom * columns) + column
        guard index < shellCount else { return nil }
        return index
    }

    static func hoverProgress(
        for touchLocation: CGPoint?,
        in frame: CGRect,
        isHighlighted: Bool
    ) -> CGFloat {
        guard let touchLocation else { return isHighlighted ? 1 : 0 }

        if frame.contains(touchLocation) {
            let normalizedX = abs(touchLocation.x - frame.midX) / max(frame.width / 2, 1)
            let normalizedY = abs(touchLocation.y - frame.midY) / max(frame.height / 2, 1)
            let edgeDistance = min(max(normalizedX, normalizedY), 1)
            let interiorProgress = 1 - edgeDistance
            return max(isHighlighted ? 0.85 : 0.62, interiorProgress)
        }

        let expandedFrame = frame.insetBy(dx: -hoverHaloDistance, dy: -hoverHaloDistance)
        guard expandedFrame.contains(touchLocation) else { return 0 }

        let outsideX = max(0, abs(touchLocation.x - frame.midX) - (frame.width / 2))
        let outsideY = max(0, abs(touchLocation.y - frame.midY) - (frame.height / 2))
        let outsideDistance = sqrt((outsideX * outsideX) + (outsideY * outsideY))
        let normalizedOutside = min(max(outsideDistance / hoverHaloDistance, 0), 1)
        return (1 - normalizedOutside) * 0.3
    }
}

struct SpacebarQuickShellOverlay: View {
    private struct QuickShellCell: Identifiable {
        let id: Int
        let shellIndex: Int?
    }

    let shellCards: [ShellIndicatorState.SpacebarShellCard]
    let highlightedWindowID: Int?
    let hoverLocation: CGPoint?
    let keyWidth: CGFloat
    @Namespace private var shellGlassNamespace

    var body: some View {
        if !shellCards.isEmpty {
            let shellCount = shellCards.count
            let columnCount = SpacebarQuickShellOverlayLayout.columnCount(for: shellCount)
            let rowCount = SpacebarQuickShellOverlayLayout.rowCount(for: shellCount)
            let cardWidth = SpacebarQuickShellOverlayLayout.cardWidth(for: shellCount)
            let totalSize = SpacebarQuickShellOverlayLayout.totalSize(for: shellCount)
            let cardSpacing = SpacebarQuickShellOverlayLayout.cardSpacing
            let cellCount = rowCount * columnCount
            let cells: [QuickShellCell] = (0..<cellCount).map { index in
                let rowIndex = index / columnCount
                let columnIndex = index % columnCount
                let shellIndex = SpacebarQuickShellOverlayLayout.shellIndex(
                    forRow: rowIndex,
                    column: columnIndex,
                    shellCount: shellCount
                )
                return QuickShellCell(id: index, shellIndex: shellIndex)
            }
            let gridColumns = Array(
                repeating: GridItem(.fixed(cardWidth), spacing: cardSpacing, alignment: .center),
                count: columnCount
            )
            let absoluteCardFrames = SpacebarQuickShellOverlayLayout.cardFrames(
                keyWidth: keyWidth,
                shellCount: shellCount
            )
            GlassEffectContainer(spacing: cardSpacing) {
                LazyVGrid(columns: gridColumns, alignment: .center, spacing: cardSpacing) {
                    ForEach(cells) { (cell: QuickShellCell) in
                        if let shellIndex = cell.shellIndex {
                            let shellCard = shellCards[shellIndex]
                            let isHighlighted = highlightedWindowID == shellCard.windowID
                            let hoverProgress: CGFloat = if shellIndex < absoluteCardFrames.count {
                                SpacebarQuickShellOverlayLayout.hoverProgress(
                                    for: hoverLocation,
                                    in: absoluteCardFrames[shellIndex],
                                    isHighlighted: isHighlighted
                                )
                            } else {
                                isHighlighted ? 1 : 0
                            }

                            SpacebarQuickShellCardView(
                                shellCard: shellCard,
                                isHighlighted: isHighlighted,
                                showSelectionStroke: isHighlighted,
                                hoverProgress: hoverProgress,
                                cardWidth: cardWidth,
                                glassNamespace: shellGlassNamespace
                            )
                        } else {
                            Color.clear
                                .frame(
                                    width: cardWidth,
                                    height: SpacebarQuickShellOverlayLayout.cardHeight
                                )
                                .hidden()
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: SpacebarQuickShellOverlayLayout.contentWidth(for: shellCount), alignment: .leading)
                .padding(SpacebarQuickShellOverlayLayout.containerPadding)
            }
            .frame(
                width: totalSize.width,
                height: totalSize.height,
                alignment: .topLeading
            )
            .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 12)
            .shadow(color: .black.opacity(0.14), radius: 5, x: 0, y: 2)
        }
    }
}

struct SpacebarQuickShellCardView: View {
    let shellCard: ShellIndicatorState.SpacebarShellCard
    let isHighlighted: Bool
    let showSelectionStroke: Bool
    let hoverProgress: CGFloat
    let cardWidth: CGFloat
    let glassNamespace: Namespace.ID

    private var cardCornerRadius: CGFloat {
        SpacebarQuickShellOverlayLayout.cardCornerRadius
    }

    private var effectiveHoverProgress: CGFloat {
        min(max(hoverProgress, 0), 1)
    }

    private var glassExpansion: CGFloat {
        SpacebarQuickShellOverlayLayout.maxHoverGlassExpansion * effectiveHoverProgress
    }

    private var glassIdentifier: String {
        "spacebar-shell-card-\(shellCard.windowID)"
    }

    private var fillOpacity: Double {
        if shellCard.isActive || isHighlighted {
            return 0.08
        }
        return 0.04
    }

    private var strokeOpacity: Double {
        let activeBase = shellCard.isActive ? 0.3 : 0.2
        let highlightedBoost = isHighlighted ? 0.24 : 0
        let hoverBoost = Double(effectiveHoverProgress) * 0.34
        return min(0.9, activeBase + highlightedBoost + hoverBoost)
    }

    private var strokeLineWidth: CGFloat {
        0.9 + (0.9 * effectiveHoverProgress) + (isHighlighted ? 0.28 : 0)
    }

    private var selectedStrokeOpacity: Double {
        guard showSelectionStroke else { return 0 }
        return 0.82 + (Double(effectiveHoverProgress) * 0.18)
    }

    private var selectedStrokeLineWidth: CGFloat {
        guard showSelectionStroke else { return 0 }
        return 2.0 + (0.8 * effectiveHoverProgress)
    }

    private var selectedStrokeGlowOpacity: Double {
        guard showSelectionStroke else { return 0 }
        return 0.24 + (Double(effectiveHoverProgress) * 0.24)
    }

    private var selectedStrokeGlowRadius: CGFloat {
        guard showSelectionStroke else { return 0 }
        return 3 + (2 * effectiveHoverProgress)
    }

    private var contentScale: CGFloat {
        1 + (0.02 * effectiveHoverProgress)
    }

    private var textOpacity: Double {
        min(1, 0.92 + (Double(effectiveHoverProgress) * 0.08))
    }

    private var textGlowOpacity: Double {
        0.02 + (Double(effectiveHoverProgress) * 0.26)
    }

    private var textGlowRadius: CGFloat {
        0.8 + (3 * effectiveHoverProgress)
    }

    private var shellIndexText: String {
        String(shellCard.position + 1)
    }

    var body: some View {
        Group {
            if shellCard.isCreatePlaceholder {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText.opacity(textOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(shellIndexText)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText.opacity(textOpacity))
                        .frame(width: 20, alignment: .leading)
                        .padding(.leading, 4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(shellCard.title)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText.opacity(textOpacity))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.82)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .scaleEffect(contentScale)
        .shadow(color: AppTheme.primaryText.opacity(textGlowOpacity), radius: textGlowRadius, x: 0, y: 0)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: cardWidth, height: SpacebarQuickShellOverlayLayout.cardHeight, alignment: .leading)
        .glassEffect(
            AppTheme.glass(.regular),
            in: SpacebarQuickShellCardGlassShape(
                cornerRadius: cardCornerRadius,
                expansion: glassExpansion
            )
        )
        .glassEffectID(glassIdentifier, in: glassNamespace)
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AppTheme.primaryText.opacity(fillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.primaryText.opacity(strokeOpacity),
                    lineWidth: strokeLineWidth
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.primaryText.opacity(selectedStrokeOpacity),
                    lineWidth: selectedStrokeLineWidth
                )
                .shadow(
                    color: AppTheme.primaryText.opacity(selectedStrokeGlowOpacity),
                    radius: selectedStrokeGlowRadius,
                    x: 0,
                    y: 0
                )
        }
        .animation(
            SpacebarQuickShellOverlayLayout.highlightSelectionAnimation,
            value: isHighlighted
        )
        .animation(
            SpacebarQuickShellOverlayLayout.glassHoverAnimation,
            value: effectiveHoverProgress
        )
    }
}

nonisolated struct SpacebarQuickShellCardGlassShape: Shape {
    let cornerRadius: CGFloat
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let expandedRect = rect.insetBy(dx: -expansion, dy: -expansion)
        let adjustedCornerRadius = cornerRadius + (expansion * 0.78)
        return RoundedRectangle(cornerRadius: adjustedCornerRadius, style: .continuous)
            .path(in: expandedRect)
    }
}

// iOS-style key press callout: wide bubble on top, straight diagonal "shoulders" narrowing
// down to a key-width section that exactly covers the pressed key — eliminating the bottom seam.
