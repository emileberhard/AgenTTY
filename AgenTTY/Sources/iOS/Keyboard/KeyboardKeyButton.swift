import SwiftUI
import UIKit

struct KeyButton: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private struct SpacebarSwipePreviewState: Equatable {
        let windowID: Int?
        let progress: CGFloat
    }

    let definition: KeyDefinition
    let width: CGFloat
    let height: CGFloat
    let rowIndex: Int
    let keyboardState: KeyboardState
    let inputRouter: TerminalInputRouter
    let renderInput: KeyButtonRenderInput
    let spacebarTitle: String
    let activeSpacebarWindowID: Int?
    let spacebarTitleSlideDirection: ShellIndicatorState.ShellTitleSlideDirection
    let spacebarSwipePreviewProgress: CGFloat
    let spacebarSwipeReleaseVelocityX: CGFloat
    let spacebarShellCards: [ShellIndicatorState.SpacebarShellCard]
    let onSpacebarShellCardSelect: ((Int) -> Void)?
    let onSpacebarCharacterLimitChange: ((Int) -> Void)?

    @State private var isPressed = false
    @State private var repeatEngine = KeyboardRepeatEngine()
    @State private var modifierPressStartTime: TimeInterval?
    @State private var modifierLockHintTask: Task<Void, Never>?
    @State private var isModifierLockHintVisible = false
    @State private var isModifierSlideLockArmed = false
    @State private var modifierSlideLockVisualProgress: CGFloat = 0
    @State private var isSpacebarQuickMenuVisible = false
    @State private var highlightedSpacebarShellWindowID: Int?
    @State private var spacebarShellHoverLocation: CGPoint?
    @State private var didTriggerSpacebarLongPress = false
    @State private var spacebarLongPressTask: Task<Void, Never>?
    @State private var lastReportedSpacebarCharacterLimit: Int?
    @State private var modifierSlideChordTarget: KeyboardState.SlideChordTarget?
    @State private var hasEverHoveredChordTarget = false
    @State private var keyFrameInGlobal: CGRect = .zero
    @State private var cachedDisplayedSpacebarTitle = " "
    @State private var renderedSpacebarTitle = " "
    @State private var renderedSpacebarTitleSlideDistance: CGFloat = 0
    @State private var renderedSpacebarWindowID: Int?
    @State private var renderedSpacebarTitleOffset: CGFloat = 0
    @State private var renderedSpacebarTitleVerticalOffset: CGFloat = 0
    @State private var renderedSpacebarTitleScale: CGFloat = 1
    @State private var renderedSpacebarTitleOpacity: Double = 1
    @State private var spacebarTitleAnimationGeneration = 0
    private let baseCornerRadius: CGFloat = 5
    private let outerCornerRadius: CGFloat = 10
    private let spacebarLongPressDuration: TimeInterval = 0.24
    private let lockBadgeFloatGap: CGFloat = 3 * Self.modifierGestureHintScale
    private let lockBadgeFrameSize: CGFloat = 18 * Self.modifierGestureHintScale
    private let lockedKeyBadgeFrameSize: CGFloat = 12
    private let lockedBadgeCornerInset: CGFloat = 1
    private let modifierLockHintAnchorDistance: CGFloat = 25 * Self.modifierGestureHintScale
    private let modifierChordHintAnchorDistance: CGFloat = 30 * Self.modifierGestureHintScale
    private let modifierLockHintLift: CGFloat = 11 * Self.modifierGestureHintScale
    private let modifierChordHintDrop: CGFloat = 13 * Self.modifierGestureHintScale
    private let modifierSlideLockArmThreshold: CGFloat = 22
    private let modifierSlideLockCancelThreshold: CGFloat = 16
    private let modifierSlideLockMaxVisualDistance: CGFloat = 52
    private let modifierLockHintHoldDelay: TimeInterval = 0.18
    private let modifierLockHintAppearYOffset: CGFloat = 8
    private let modifierLockHintSymbolScale: CGFloat = 1.3 * Self.modifierGestureHintScale
    private let modifierLockHintAppearAnimation: Animation = .spring(duration: 0.28, bounce: 0.18)
    private let modifierLockHintDisappearAnimation: Animation = .easeOut(duration: 0.12)
    private static let modifierGestureHintScale: CGFloat = 1.5
    private static let spacebarTitleUIFont = ShellIndicatorTextStyle.uiFont
    private static let spacebarTitleMaximumLines = 2
    private static let spacebarTitleHorizontalPadding: CGFloat = 10
    private static let minimumSpacebarTitleCharacterLimit = 12
    private static let maximumSpacebarTitleCharacterLimit = 120
    private static let spacebarTitleWidthSample = "abcdefghijklmnopqrstuvwxyz0123456789 _./:-"
    private static let keyFrameComparisonTolerance: CGFloat = 0.5
    private static let controlKeySymbol = "\u{2303}"
    private static let optionKeySymbol = "\u{2325}"

    private var displayLabel: String { renderInput.displayLabel }

    var body: some View {
        Group {
            if isSpacebarKey {
                spacebarShellSwitcherKey
            } else {
                interactiveKey
            }
        }
        .onAppear {
            reportSpacebarCharacterLimitIfNeeded()
            synchronizeDisplayedSpacebarTitleCache()
            synchronizeSpacebarTitleTransitionState(animated: false)
            refreshRenderedSpacebarTitleSlideDistance()
        }
        .onChange(of: width) { _, _ in
            reportSpacebarCharacterLimitIfNeeded()
            synchronizeDisplayedSpacebarTitleCache()
            refreshRenderedSpacebarTitleSlideDistance()
        }
        .onChange(of: definition) { oldDefinition, newDefinition in
            handleDefinitionChange(from: oldDefinition, to: newDefinition)
        }
        .onChange(of: requiresGlobalFrameTracking) { _, isTracking in
            handleGlobalFrameTrackingChange(isTracking)
        }
        .onChange(of: height) { _, _ in
            reportSpacebarCharacterLimitIfNeeded()
        }
        .onChange(of: spacebarTitle) { _, _ in
            synchronizeDisplayedSpacebarTitleCache()
        }
        .onChange(of: renderedSpacebarTitle) { _, _ in
            refreshRenderedSpacebarTitleSlideDistance()
        }
        .onChange(of: spacebarTitleTransitionInputToken) { _, _ in
            synchronizeSpacebarTitleTransitionState(animated: true)
        }
        .onChange(of: spacebarSwipePreviewState) { _, _ in
            synchronizeSpacebarTitleSwipePreviewState()
        }
        .scaleEffect(buttonScale)
        .zIndex(keyZIndex)
        // Press-down must be instant like the system keyboard; only release eases.
        .animation(isPressed ? nil : .snappy(duration: 0.04), value: isPressed)
        .animation(
            .snappy(duration: 0.09),
            value: renderInput.isDictationButtonActive
        )
        .background(keyFrameReporter)
    }

    @ViewBuilder
    private var keyContent: some View {
        if definition.action == .dictation {
            if renderInput.isDictationProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(AppTheme.primaryText)
            } else {
                Image(systemName: renderInput.isDictationCaptureActive ? "stop.fill" : "mic")
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .contentTransition(.symbolEffect(.replace))
            }
        } else if definition.action == .ctrl {
            controlKeyLegend
        } else if definition.action == .alt {
            optionKeyLegend
        } else if definition.action == .tab {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 17, weight: .medium, design: .default))
        } else if definition.action == .space {
            ZStack {
                Text(renderedSpacebarTitle)
                    .font(ShellIndicatorTextStyle.font)
                    .lineLimit(Self.spacebarTitleMaximumLines)
                    .minimumScaleFactor(ShellIndicatorTextStyle.minimumScaleFactor)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .padding(.horizontal, Self.spacebarTitleHorizontalPadding)
                    .offset(
                        x: renderedSpacebarTitleOffset,
                        y: renderedSpacebarTitleVerticalOffset
                    )
                    .scaleEffect(renderedSpacebarTitleScale)
                    .opacity(renderedSpacebarTitleOpacity)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .clipped()
        } else {
            Text(displayLabel)
                .font(.system(size: fontSize, weight: fontWeight, design: fontDesign))
        }
    }

    private var controlKeyLegend: some View {
        modifierCornerLegend(
            text: "control",
            symbol: Self.controlKeySymbol,
            symbolSize: 17,
            textSize: 10
        )
    }

    private var optionKeyLegend: some View {
        modifierCornerLegend(
            text: "option",
            symbol: Self.optionKeySymbol,
            symbolSize: 16,
            textSize: 10
        )
    }

    private func modifierCornerLegend(
        text: String,
        symbol: String,
        symbolSize: CGFloat,
        textSize: CGFloat
    ) -> some View {
        ZStack {
            Text(symbol)
                .font(.system(size: symbolSize, weight: .semibold, design: .default))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 5)
                .padding(.trailing, 6)

            Text(text)
                .font(.system(size: textSize, weight: .semibold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 4)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spacebarTitleTransitionInputToken: String {
        guard definition.action == .space else { return "non-space" }
        let windowIdentifier = activeSpacebarWindowID.map(String.init) ?? "none"
        let directionIdentifier: String
        switch spacebarTitleSlideDirection {
        case .none:
            directionIdentifier = "none"
        case .forward:
            directionIdentifier = "forward"
        case .backward:
            directionIdentifier = "backward"
        }
        return "\(windowIdentifier)|\(cachedDisplayedSpacebarTitle)|\(directionIdentifier)"
    }

    private var spacebarSwipePreviewState: SpacebarSwipePreviewState {
        guard definition.action == .space else {
            return SpacebarSwipePreviewState(windowID: nil, progress: 0)
        }
        return SpacebarSwipePreviewState(
            windowID: activeSpacebarWindowID,
            progress: spacebarSwipePreviewProgress
        )
    }

    private var spacebarTitleEntryAnimation: Animation {
        .spring(duration: 0.24, bounce: 0.04)
    }

    private var spacebarTitleEntryMinimumAnimatedOpacity: Double {
        0.3
    }

    private func spacebarTitleFullSlideDistance(for title: String) -> CGFloat {
        let lines = title.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let widestVisibleLine = lines
            .map { Self.spacebarTitleWidth(of: $0) }
            .max() ?? 0
        return (width * 0.5) + (widestVisibleLine * 0.5) + (Self.spacebarTitleHorizontalPadding * 2) + 20
    }

    private func synchronizeDisplayedSpacebarTitleCache() {
        guard definition.action == .space else { return }
        let nextTitle = formattedSpacebarTitle(spacebarTitle)
        guard nextTitle != cachedDisplayedSpacebarTitle else { return }
        cachedDisplayedSpacebarTitle = nextTitle
    }

    private func refreshRenderedSpacebarTitleSlideDistance() {
        guard definition.action == .space else { return }
        let nextDistance = spacebarTitleFullSlideDistance(for: renderedSpacebarTitle)
        guard abs(nextDistance - renderedSpacebarTitleSlideDistance) > 0.5 else { return }
        renderedSpacebarTitleSlideDistance = nextDistance
    }

    private func spacebarTitleExitAnimation(
        currentOffset: CGFloat,
        outgoingOffset: CGFloat
    ) -> Animation {
        let remainingDistance = abs(outgoingOffset - currentOffset)
        let fullDistance = max(abs(outgoingOffset), 1)
        let normalizedRemaining = min(max(remainingDistance / fullDistance, 0), 1)
        let fallbackDuration = max(0.09, 0.18 * Double(normalizedRemaining))

        let outgoingDirectionSign: CGFloat = outgoingOffset < 0 ? -1 : 1
        let projectedVelocity = spacebarSwipeReleaseVelocityX * outgoingDirectionSign
        guard projectedVelocity > 0, remainingDistance > 0 else {
            return .easeOut(duration: fallbackDuration)
        }

        let normalizedVelocity = max(min(projectedVelocity / remainingDistance, 8), 0)
        if normalizedVelocity < 0.05 {
            return .easeOut(duration: fallbackDuration)
        }

        return .interpolatingSpring(
            mass: 1,
            stiffness: 280,
            damping: 34,
            initialVelocity: normalizedVelocity
        )
    }

    private func synchronizeSpacebarTitleTransitionState(animated: Bool) {
        guard definition.action == .space else { return }

        let nextTitle = cachedDisplayedSpacebarTitle
        let nextWindowID = activeSpacebarWindowID
        let didChangeTitleIdentity =
            renderedSpacebarTitle != nextTitle || renderedSpacebarWindowID != nextWindowID
        guard didChangeTitleIdentity else { return }

        spacebarTitleAnimationGeneration += 1
        let animationGeneration = spacebarTitleAnimationGeneration

        guard animated, !accessibilityReduceMotion else {
            renderedSpacebarTitleOffset = 0
            renderedSpacebarTitleVerticalOffset = 0
            renderedSpacebarTitleScale = 1
            renderedSpacebarTitleOpacity = 1
            renderedSpacebarTitle = nextTitle
            renderedSpacebarWindowID = nextWindowID
            return
        }

        guard spacebarTitleSlideDirection != .none else {
            animateSpacebarTitleReplacement(
                nextTitle: nextTitle,
                nextWindowID: nextWindowID,
                animationGeneration: animationGeneration
            )
            return
        }

        renderedSpacebarTitleVerticalOffset = 0
        renderedSpacebarTitleScale = 1

        let outgoingDistance = max(
            renderedSpacebarTitleSlideDistance,
            spacebarTitleFullSlideDistance(for: renderedSpacebarTitle)
        )
        let incomingDistance = spacebarTitleFullSlideDistance(for: nextTitle)
        let outgoingOffset = spacebarTitleSlideDirection == .forward ? -outgoingDistance : outgoingDistance
        let incomingOffset = spacebarTitleSlideDirection == .forward ? incomingDistance : -incomingDistance
        let exitAnimation = spacebarTitleExitAnimation(
            currentOffset: renderedSpacebarTitleOffset,
            outgoingOffset: outgoingOffset
        )

        withAnimation(exitAnimation, completionCriteria: .logicallyComplete) {
            renderedSpacebarTitleOffset = outgoingOffset
            renderedSpacebarTitleOpacity = 0.65
        } completion: {
            guard animationGeneration == spacebarTitleAnimationGeneration else { return }
            renderedSpacebarTitle = nextTitle
            renderedSpacebarWindowID = nextWindowID
            renderedSpacebarTitleSlideDistance = incomingDistance
            renderedSpacebarTitleOffset = incomingOffset
            renderedSpacebarTitleVerticalOffset = 0
            renderedSpacebarTitleScale = 1
            renderedSpacebarTitleOpacity = spacebarTitleEntryMinimumAnimatedOpacity
            withAnimation(spacebarTitleEntryAnimation) {
                renderedSpacebarTitleOffset = 0
                renderedSpacebarTitleOpacity = 1
            }
        }
    }

    private func animateSpacebarTitleReplacement(
        nextTitle: String,
        nextWindowID: Int?,
        animationGeneration: Int
    ) {
        let currentTitleIsEmpty = renderedSpacebarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let nextTitleIsEmpty = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if currentTitleIsEmpty {
            renderedSpacebarTitle = nextTitle
            renderedSpacebarWindowID = nextWindowID
            renderedSpacebarTitleOffset = 0
            renderedSpacebarTitleVerticalOffset = nextTitleIsEmpty ? 0 : 2
            renderedSpacebarTitleScale = nextTitleIsEmpty ? 1 : 0.985
            renderedSpacebarTitleOpacity = nextTitleIsEmpty ? 1 : 0
            withAnimation(.smooth(duration: 0.22)) {
                renderedSpacebarTitleVerticalOffset = 0
                renderedSpacebarTitleScale = 1
                renderedSpacebarTitleOpacity = 1
            }
            return
        }

        withAnimation(.easeOut(duration: 0.1), completionCriteria: .logicallyComplete) {
            renderedSpacebarTitleVerticalOffset = -1
            renderedSpacebarTitleScale = 0.99
            renderedSpacebarTitleOpacity = 0
        } completion: {
            guard animationGeneration == spacebarTitleAnimationGeneration else { return }
            renderedSpacebarTitle = nextTitle
            renderedSpacebarWindowID = nextWindowID
            renderedSpacebarTitleOffset = 0
            renderedSpacebarTitleVerticalOffset = nextTitleIsEmpty ? 0 : 2
            renderedSpacebarTitleScale = nextTitleIsEmpty ? 1 : 0.985
            renderedSpacebarTitleOpacity = nextTitleIsEmpty ? 1 : 0
            withAnimation(.smooth(duration: 0.22)) {
                renderedSpacebarTitleVerticalOffset = 0
                renderedSpacebarTitleScale = 1
                renderedSpacebarTitleOpacity = 1
            }
        }
    }

    private func synchronizeSpacebarTitleSwipePreviewState() {
        guard definition.action == .space else { return }
        guard spacebarTitleSlideDirection == .none else { return }
        guard renderedSpacebarWindowID == activeSpacebarWindowID else { return }

        let clampedProgress = max(min(spacebarSwipePreviewProgress, 1), -1)
        if clampedProgress == 0 {
            guard renderedSpacebarTitleOffset != 0 || renderedSpacebarTitleOpacity != 1 else { return }
            withAnimation(.spring(duration: 0.22, bounce: 0.18)) {
                renderedSpacebarTitleOffset = 0
                renderedSpacebarTitleOpacity = 1
            }
            return
        }

        let slideDistance = max(renderedSpacebarTitleSlideDistance, 1)
        let targetOffset = slideDistance * clampedProgress
        let targetOpacity = 1 - (1 - 0.7) * Double(abs(clampedProgress))
        renderedSpacebarTitleOffset = targetOffset
        renderedSpacebarTitleOpacity = targetOpacity
    }

    private func formattedSpacebarTitle(_ rawTitle: String) -> String {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return " "
        }
        return balancedSpacebarTitle(trimmedTitle)
    }

    private func balancedSpacebarTitle(_ title: String) -> String {
        let normalizedTitle = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return " " }

        let maxLineWidth = max(0, width - (Self.spacebarTitleHorizontalPadding * 2))
        guard maxLineWidth > 0 else { return normalizedTitle }

        if Self.spacebarTitleWidth(of: normalizedTitle) <= maxLineWidth {
            return normalizedTitle
        }

        let words = normalizedTitle.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return normalizedTitle }

        var bestSplit: (index: Int, score: CGFloat)?
        for splitIndex in 1..<words.count {
            let firstLine = words[..<splitIndex].joined(separator: " ")
            let secondLine = words[splitIndex...].joined(separator: " ")

            let firstWidth = Self.spacebarTitleWidth(of: firstLine)
            let secondWidth = Self.spacebarTitleWidth(of: secondLine)
            let overflowPenalty = max(0, firstWidth - maxLineWidth) + max(0, secondWidth - maxLineWidth)
            let balanceDistance = abs(firstWidth - secondWidth)
            let score = balanceDistance + (overflowPenalty * 4)

            if let bestSplit, score >= bestSplit.score {
                continue
            }
            bestSplit = (index: splitIndex, score: score)
        }

        guard let bestSplit else { return normalizedTitle }
        let firstLine = words[..<bestSplit.index].joined(separator: " ")
        let secondLine = words[bestSplit.index...].joined(separator: " ")
        return "\(firstLine)\n\(secondLine)"
    }

    private static func spacebarTitleWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: spacebarTitleUIFont]).width
    }

    @ViewBuilder
    private var keyFrameReporter: some View {
        if requiresGlobalFrameTracking {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateKeyFrame(proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        updateKeyFrame(frame)
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private var keyVisual: some View {
        keyContent
            .foregroundStyle(keyForegroundColor)
            .frame(width: width, height: height)
            .background(
                UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                    .fill(backgroundColor)
                    .overlay(
                        Group {
                            if isLockedModifier {
                                UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                                    .strokeBorder(strokeColor.opacity(strokeOpacity), lineWidth: strokeLineWidth)
                            } else {
                                UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                                    .stroke(strokeColor.opacity(strokeOpacity), lineWidth: strokeLineWidth)
                            }
                        }
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isLockedModifier {
                    lockBadge
                        .padding(.top, lockedBadgeCornerInset)
                        .padding(.trailing, lockedBadgeCornerInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                modifierLockHintBadge
                    .offset(
                        y: -modifierLockHintBaseOffset
                            + (shouldShowModifierLockHint ? 0 : modifierLockHintAppearYOffset)
                    )
                    .scaleEffect(shouldShowModifierLockHint ? 1 : 0.92, anchor: .bottom)
                    .opacity(shouldShowModifierLockHint ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!shouldShowModifierLockHint)
            }
            .overlay(alignment: .bottom) {
                modifierChordHintBadge
                    .offset(
                        y: modifierChordHintBaseOffset
                            - (shouldShowModifierLockHint ? 0 : modifierLockHintAppearYOffset)
                    )
                    .scaleEffect(shouldShowModifierLockHint ? 1 : 0.92, anchor: .top)
                    .opacity(shouldShowModifierLockHint ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!shouldShowModifierLockHint)
            }
    }

    private var interactiveKey: some View {
        keyVisual
            .overlay {
                if shouldShowKeyCallout, let calloutLabel {
                    KeyPressCallout(
                        label: calloutLabel,
                        keyWidth: width,
                        keyHeight: height
                    )
                    .offset(y: KeyPressCallout.overlayCenterYOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
            .allowsHitTesting(definition.action != .dictation || !renderInput.isDictationProcessing)
            .gesture(
                ImmediateKeyTouchGesture(
                    onBegan: { value in
                        beginPress()
                        handleKeyDragChanged(value)
                    },
                    onChanged: { value in
                        handleKeyDragChanged(value)
                    },
                    onEnded: { _ in
                        endPress()
                    },
                    onCancelled: {
                        cancelPress()
                    }
                )
            )
            .onChange(of: renderInput.pressCancellationGeneration) { _, _ in
                cancelPress()
            }
            .onDisappear {
                cancelPress()
                keyboardState.removeSlideChordTarget(id: definition.id)
            }
    }

    private var currentCornerRadius: CGFloat {
        baseCornerRadius
    }

    private var spacebarFillColor: Color {
        return isPressed ? AppTheme.keySpacePressed : AppTheme.keySpaceIdle
    }

    private var spacebarVisualOpacity: Double {
        isSpacebarQuickMenuVisible ? 0.15 : 1.0
    }

    private var spacebarBackground: some View {
        RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous)
            .fill(spacebarFillColor)
            .overlay(
                RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous)
                    .stroke(AppTheme.keyStroke.opacity(isPressed ? 0.52 : 0.36), lineWidth: 1)
            )
    }

    private var spacebarVisual: some View {
        keyContent
            .foregroundStyle(AppTheme.primaryText)
            .frame(width: width, height: height)
            .background(spacebarBackground)
            .opacity(spacebarVisualOpacity)
            .scaleEffect(isSpacebarQuickMenuVisible ? 0.92 : 1.0)
    }

    private var spacebarShellSwitcherKey: some View {
        spacebarVisual
            .gesture(
                ImmediateKeyTouchGesture(
                    onBegan: { value in
                        handleSpacebarDragChanged(value)
                    },
                    onChanged: { value in
                        handleSpacebarDragChanged(value)
                    },
                    onEnded: { value in
                        handleSpacebarDragEnded(value)
                    },
                    onCancelled: {
                        cancelPress()
                    }
                )
            )
            .overlay(alignment: .bottom) {
                if isSpacebarQuickMenuVisible {
                    spacebarQuickMenuOverlayContent
                        .offset(y: -(height + spacebarOverlayGapFromSpacebar))
                        .transition(spacebarOverlayVisibilityTransition)
                }
            }
            .allowsHitTesting(renderInput.isInputEnabled)
            .onChange(of: renderInput.pressCancellationGeneration) { _, _ in
                cancelPress()
            }
            .onChange(of: renderInput.isHostInteractionAvailable) { _, isAvailable in
                // Losing the host mid-hold must close the switcher instead of
                // leaving tappable cards for shells we can no longer reach.
                if !isAvailable {
                    hideSpacebarQuickMenu()
                }
            }
            .onDisappear {
                cancelPress()
                keyboardState.removeSlideChordTarget(id: definition.id)
            }
    }

    private func handleSpacebarDragChanged(_ value: ImmediateKeyTouchValue) {
        guard keyboardState.isInputEnabled else { return }

        if isSpacebarQuickMenuVisible {
            cancelSpacebarLongPressTask()
            spacebarShellHoverLocation = value.location
            updateHighlightedSpacebarShellWindowID(for: value.location)
            return
        }

        if !isPressed {
            keyboardState.clearLifecycleUndoCandidate()
            keyboardState.beginPendingSpacePress()
            isPressed = true
            KeyboardHaptics.keyTap(style: .space)
        }

        if spacebarLongPressTask == nil {
            startSpacebarLongPressTask()
        }
    }

    private func handleKeyDragChanged(_ value: ImmediateKeyTouchValue) {
        guard definition.action.isChordModifier else { return }
        guard isPressed else { return }

        guard keyboardState.isInputEnabled else { return }

        let slideChordTarget: KeyboardState.SlideChordTarget?
        if keyFrameInGlobal.width > 0, keyFrameInGlobal.height > 0 {
            let dragLocation = value.globalLocation
            let isInsideHeldModifierKey = keyFrameInGlobal.contains(dragLocation)
            let isAboveHeldModifierKey = dragLocation.y < keyFrameInGlobal.minY
            let shouldSuppressChordTargeting = isInsideHeldModifierKey || (isAboveHeldModifierKey && !hasEverHoveredChordTarget)
            if shouldSuppressChordTargeting {
                slideChordTarget = nil
            } else {
                slideChordTarget = keyboardState.modifierSlideChordTarget(
                    at: dragLocation,
                    excludingKeyID: definition.id
                )
            }
        } else {
            slideChordTarget = nil
        }
        updateModifierSlideChordTarget(slideChordTarget)

        if modifierSlideChordTarget != nil {
            isModifierSlideLockArmed = false
            modifierSlideLockVisualProgress = 0
            hideModifierLockHint()
        }

        guard !hasEverHoveredChordTarget else { return }

        let visualProgress = modifierSlideProgress(from: value.translation.height)
        modifierSlideLockVisualProgress = visualProgress

        if isModifierSlideLockArmed {
            guard value.translation.height > -modifierSlideLockCancelThreshold else { return }
            isModifierSlideLockArmed = false
            modifierSlideLockVisualProgress = 0
            hideModifierLockHint()
            return
        }

        guard value.translation.height <= -modifierSlideLockArmThreshold else { return }

        isModifierSlideLockArmed = true
        modifierLockHintTask?.cancel()
        modifierLockHintTask = nil
        withAnimation(modifierLockHintAppearAnimation) {
            isModifierLockHintVisible = true
        }
        KeyboardHaptics.modifierSlideLockActivation()
    }

    private func handleDefinitionChange(from oldDefinition: KeyDefinition, to newDefinition: KeyDefinition) {
        guard oldDefinition != newDefinition else { return }

        cancelPress()
        // cancelPress ends the NEW definition's callout;
        // a press that was live under the old definition must clear too.
        keyboardState.endKeyCallout(id: oldDefinition.id)
        keyboardState.removeSlideChordTarget(id: oldDefinition.id)

        guard keyFrameInGlobal.width > 0, keyFrameInGlobal.height > 0 else { return }

        synchronizeSlideChordTargetRegistration(for: newDefinition, frame: keyFrameInGlobal)
    }

    private func handleGlobalFrameTrackingChange(_ isTracking: Bool) {
        if isTracking {
            guard keyFrameInGlobal.width > 0, keyFrameInGlobal.height > 0 else { return }
            synchronizeSlideChordTargetRegistration(for: definition, frame: keyFrameInGlobal)
            return
        }

        keyboardState.removeSlideChordTarget(id: definition.id)
    }

    private func updateKeyFrame(_ frame: CGRect) {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite else {
            return
        }
        guard !keyFrameInGlobal.isApproximatelyEqual(to: frame, tolerance: Self.keyFrameComparisonTolerance) else {
            return
        }

        keyFrameInGlobal = frame
        synchronizeSlideChordTargetRegistration(for: definition, frame: frame)
        if definition.action.isChordModifier,
           let modifier = definition.action.modifierKey,
           keyboardState.isModifierHeld(modifier) {
            keyboardState.setModifierSlidePreviewAnchorX(frame.midX)
        }
    }

    private func synchronizeSlideChordTargetRegistration(for definition: KeyDefinition, frame: CGRect) {
        if definition.action.supportsModifierSlideChordTarget {
            keyboardState.updateSlideChordTarget(
                id: definition.id,
                action: definition.action,
                style: definition.style,
                label: displayLabel,
                frame: frame
            )
        } else {
            keyboardState.removeSlideChordTarget(id: definition.id)
        }
    }

    private func updateModifierSlideChordTarget(_ nextTarget: KeyboardState.SlideChordTarget?) {
        let previousID = modifierSlideChordTarget?.id
        let nextID = nextTarget?.id
        guard previousID != nextID else { return }

        modifierSlideChordTarget = nextTarget
        if let modifier = definition.action.modifierKey {
            keyboardState.setModifierSlidePreview(modifier: modifier, target: nextTarget)
        }
        if nextTarget != nil {
            hasEverHoveredChordTarget = true
            KeyboardHaptics.selectionChanged()
        }
    }

    private func handleSpacebarDragEnded(_: ImmediateKeyTouchValue) {
        cancelSpacebarLongPressTask()
        isPressed = false

        if isSpacebarQuickMenuVisible {
            let selectedWindowID = highlightedSpacebarShellWindowID
            hideSpacebarQuickMenu()
            if let selectedWindowID {
                commitSpacebarShellSelection(windowID: selectedWindowID)
            }
            return
        }

        if didTriggerSpacebarLongPress {
            didTriggerSpacebarLongPress = false
            return
        }

        handleSpacebarPrimaryAction()
    }

    private func startSpacebarLongPressTask() {
        cancelSpacebarLongPressTask()
        spacebarLongPressTask = Task.immediate {
            let sleepNanoseconds = UInt64(self.spacebarLongPressDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            await MainActor.run {
                guard self.isPressed else { return }
                guard self.keyboardState.isInputEnabled else { return }
                guard !self.isSpacebarQuickMenuVisible else { return }

                self.presentSpacebarQuickMenuFromLongPress()
            }
        }
    }

    private func cancelSpacebarLongPressTask() {
        spacebarLongPressTask?.cancel()
        spacebarLongPressTask = nil
    }

    private func startModifierLockHintTask() {
        guard definition.action.isChordModifier else { return }
        hideModifierLockHint()

        modifierLockHintTask = Task.immediate {
            let sleepNanoseconds = UInt64(self.modifierLockHintHoldDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            await MainActor.run {
                guard self.isPressed else { return }
                guard self.keyboardState.isInputEnabled else { return }
                guard self.definition.action.isChordModifier else { return }
                guard !self.isModifierSlideLockArmed else { return }
                guard !self.isLockedModifier else { return }
                withAnimation(self.modifierLockHintAppearAnimation) {
                    self.isModifierLockHintVisible = true
                }
            }
        }
    }

    private func hideModifierLockHint() {
        modifierLockHintTask?.cancel()
        modifierLockHintTask = nil
        guard isModifierLockHintVisible else { return }
        withAnimation(modifierLockHintDisappearAnimation) {
            isModifierLockHintVisible = false
        }
    }

    private func hideSpacebarQuickMenu(animated: Bool = true) {
        let updateMenuState = {
            isSpacebarQuickMenuVisible = false
            highlightedSpacebarShellWindowID = nil
            spacebarShellHoverLocation = nil
            didTriggerSpacebarLongPress = false
        }
        if animated {
            withAnimation(SpacebarQuickShellOverlayLayout.closeAnimation, updateMenuState)
            return
        }
        updateMenuState()
    }

    private func reportSpacebarCharacterLimitIfNeeded() {
        guard definition.action == .space else { return }
        guard let onSpacebarCharacterLimitChange else { return }
        let recommendedLimit = Self.recommendedSpacebarTitleCharacterLimit(width: width, height: height)
        guard lastReportedSpacebarCharacterLimit != recommendedLimit else { return }
        lastReportedSpacebarCharacterLimit = recommendedLimit
        onSpacebarCharacterLimitChange(recommendedLimit)
    }

    private static func recommendedSpacebarTitleCharacterLimit(width: CGFloat, height: CGFloat) -> Int {
        let usableWidth = max(0, width - (spacebarTitleHorizontalPadding * 2))
        guard usableWidth > 0 else { return minimumSpacebarTitleCharacterLimit }

        let lineHeight = max(spacebarTitleUIFont.lineHeight, 1)
        let linesByHeight = max(Int(floor(height / lineHeight)), 1)
        let usableLines = min(spacebarTitleMaximumLines, linesByHeight)

        let sampleCount = max(spacebarTitleWidthSample.count, 1)
        let sampleWidth = (spacebarTitleWidthSample as NSString).size(
            withAttributes: [.font: spacebarTitleUIFont]
        ).width
        guard sampleWidth > 0 else { return minimumSpacebarTitleCharacterLimit }

        let averageGlyphWidth = sampleWidth / CGFloat(sampleCount)
        guard averageGlyphWidth > 0 else { return minimumSpacebarTitleCharacterLimit }

        let charactersPerLine = max(Int(floor(usableWidth / averageGlyphWidth)), 1)
        let estimatedLimit = charactersPerLine * usableLines
        return min(max(estimatedLimit, minimumSpacebarTitleCharacterLimit), maximumSpacebarTitleCharacterLimit)
    }

    private func presentSpacebarQuickMenuFromLongPress() {
        guard keyboardState.isInputEnabled else { return }
        guard renderInput.isHostInteractionAvailable else { return }
        guard !isSpacebarQuickMenuVisible else { return }
        guard !spacebarShellCards.isEmpty else { return }
        keyboardState.clearPendingSpacePress()
        isPressed = false
        withAnimation(SpacebarQuickShellOverlayLayout.openAnimation) {
            didTriggerSpacebarLongPress = true
            highlightedSpacebarShellWindowID = nil
            spacebarShellHoverLocation = nil
            isSpacebarQuickMenuVisible = true
        }
        KeyboardHaptics.spacebarQuickMenuPop()
    }

    private func updateHighlightedSpacebarShellWindowID(for touchLocation: CGPoint) {
        let previousWindowID = highlightedSpacebarShellWindowID
        let nextWindowID = spacebarShellWindowID(at: touchLocation)
        guard nextWindowID != previousWindowID else { return }
        highlightedSpacebarShellWindowID = nextWindowID
        if nextWindowID != nil {
            KeyboardHaptics.selectionChanged()
        }
    }

    private func spacebarShellWindowID(at touchLocation: CGPoint) -> Int? {
        guard !spacebarShellCards.isEmpty else { return nil }
        let frames = SpacebarQuickShellOverlayLayout.cardFrames(
            keyWidth: width,
            shellCount: spacebarShellCards.count
        )
        guard frames.count == spacebarShellCards.count else { return nil }

        for (index, frame) in frames.enumerated() where frame.contains(touchLocation) {
            return spacebarShellCards[index].windowID
        }
        return nil
    }

    private func handleSpacebarPrimaryAction() {
        guard keyboardState.isInputEnabled else { return }
        guard keyboardState.takePendingSpacePress() else { return }
        keyboardState.clearLifecycleUndoCandidate()
        inputRouter.handleKeyAction(.space, keyboardState: keyboardState)
        keyboardState.recordLifecycleUndoCandidate(for: .space)
    }

    private func commitSpacebarShellSelection(windowID: Int) {
        guard keyboardState.isInputEnabled else { return }
        guard renderInput.isHostInteractionAvailable else { return }
        guard let onSpacebarShellCardSelect else { return }
        keyboardState.clearLifecycleUndoCandidate()
        KeyboardHaptics.keyTap(style: .action)
        onSpacebarShellCardSelect(windowID)
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.keyLockedModifierIcon)
            .frame(width: lockedKeyBadgeFrameSize, height: lockedKeyBadgeFrameSize)
    }

    private var modifierLockHintProgress: CGFloat {
        max(modifierSlideLockVisualProgress, isModifierSlideLockArmed ? 0.72 : 0)
    }

    private var modifierLockHintBaseOffset: CGFloat {
        lockBadgeFrameSize + lockBadgeFloatGap + modifierLockHintAnchorDistance
    }

    private var modifierChordHintBaseOffset: CGFloat {
        lockBadgeFrameSize + lockBadgeFloatGap + modifierChordHintAnchorDistance
    }

    private var modifierChordHintProgress: CGFloat {
        modifierSlideChordTarget == nil ? 0 : 1
    }

    private var modifierLockHintBadge: some View {
        ModifierGestureHintSymbol(
            icon: .systemImage("lock.fill"),
            arrowName: "arrow.up",
            iconOffset: -(modifierLockHintLift * modifierLockHintSymbolScale),
            directionalOffset: -(7 * modifierLockHintProgress),
            progress: modifierLockHintProgress,
            frameSize: lockBadgeFrameSize,
            symbolScale: modifierLockHintSymbolScale
        )
    }

    private var modifierChordHintBadge: some View {
        ModifierGestureHintSymbol(
            icon: .modifierSymbolPlus(displayLabel),
            arrowName: "arrow.down",
            iconOffset: modifierChordHintDrop * modifierLockHintSymbolScale,
            directionalOffset: 7 * modifierChordHintProgress,
            progress: modifierChordHintProgress,
            frameSize: lockBadgeFrameSize,
            symbolScale: modifierLockHintSymbolScale
        )
    }

    private func beginPress() {
        guard !isPressed else { return }
        guard keyboardState.isInputEnabled else { return }

        if definition.action == .dictation {
            guard !inputRouter.isDictationProcessing else { return }
            keyboardState.clearLifecycleUndoCandidate()
            isPressed = true
            let event: KeyboardHapticEvent = if inputRouter.isDictationCaptureActive {
                .dictationStopTouchDown
            } else {
                .dictationStartTouchDown
            }
            KeyboardHaptics.runFeedbackFirstAction(event) {
                self.executeAction()
            }
            return
        }

        isPressed = true
        if calloutLabel != nil {
            keyboardState.beginKeyCallout(id: definition.id, rowIndex: rowIndex)
        }

        if definition.action.isChordModifier {
            guard let modifier = definition.action.modifierKey else {
                preconditionFailure("modifier action expected a concrete modifier key")
            }
            keyboardState.clearLifecycleUndoCandidate()
            keyboardState.elevateModifierHintRow(rowIndex)
            ModifierPressLogic.begin(
                modifier,
                keyboardState: keyboardState,
                pressStartTime: &modifierPressStartTime
            )
            if keyFrameInGlobal.width > 0, keyFrameInGlobal.height > 0 {
                keyboardState.setModifierSlidePreviewAnchorX(keyFrameInGlobal.midX)
            } else {
                keyboardState.setModifierSlidePreviewAnchorX(nil)
            }
            modifierSlideChordTarget = nil
            hasEverHoveredChordTarget = false
            isModifierSlideLockArmed = false
            modifierSlideLockVisualProgress = 0
            startModifierLockHintTask()
            KeyboardHaptics.keyTap(style: .modifier)
            return
        }

        flushPendingSpacePressIfNeeded()
        // Keep sensory feedback ordered with touch-down before enqueueing bytes.
        KeyboardHaptics.keyTap(style: definition.style)
        executeAction()
        keyboardState.recordLifecycleUndoCandidate(for: definition.action)
        startRepeatTimer()
    }

    private func endPress() {
        guard isPressed else { return }
        isPressed = false
        keyboardState.endKeyCallout(id: definition.id)
        hideModifierLockHint()
        stopRepeatTimer()
        defer { resetPressTracking() }

        guard definition.action.isChordModifier else { return }
        keyboardState.clearModifierHintRowElevation(rowIndex)
        guard let modifier = definition.action.modifierKey else {
            preconditionFailure("modifier action expected a concrete modifier key")
        }
        guard !isModifierSlideLockArmed else {
            _ = keyboardState.endModifierHold(modifier)
            keyboardState.lockModifierFromSlideGesture(modifier)
            KeyboardHaptics.modifierSlideLockConfirmation()
            return
        }

        if let slideChordTarget = modifierSlideChordTarget {
            keyboardState.clearLifecycleUndoCandidate()
            KeyboardHaptics.keyTap(style: slideChordTarget.style)
            inputRouter.handleKeyAction(slideChordTarget.action, keyboardState: keyboardState)
            keyboardState.recordLifecycleUndoCandidate(for: slideChordTarget.action)
            _ = keyboardState.endModifierHold(modifier)
            return
        }

        if ModifierPressLogic.shouldRunTapAction(
            modifier,
            keyboardState: keyboardState,
            pressStartTime: &modifierPressStartTime
        ) {
            keyboardState.handleModifierTap(modifier)
        }
    }

    private func executeAction() {
        guard keyboardState.isInputEnabled else { return }
        inputRouter.handleKeyAction(definition.action, keyboardState: keyboardState)
    }

    private var shouldFlushPendingSpaceOnPress: Bool {
        switch definition.action {
        case .character, .backspace, .enter, .tab, .escape, .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
            return true
        case .space, .dictation, .shift, .ctrl, .alt, .symbolLayer, .directionPad:
            return false
        }
    }

    private func flushPendingSpacePressIfNeeded() {
        guard keyboardState.isInputEnabled else { return }
        guard shouldFlushPendingSpaceOnPress else { return }
        guard keyboardState.takePendingSpacePress() else { return }
        keyboardState.clearLifecycleUndoCandidate()
        inputRouter.handleKeyAction(.space, keyboardState: keyboardState)
        keyboardState.recordLifecycleUndoCandidate(for: .space)
    }

    private func startRepeatTimer() {
        guard let repeatBehavior = definition.action.repeatBehavior else { return }
        stopRepeatTimer()
        repeatEngine.start(
            initialDelay: repeatBehavior.initialDelay,
            hapticMinimumInterval: repeatBehavior.hapticMinimumInterval
        ) { holdDuration in
            guard self.isPressed else { return nil }
            guard self.keyboardState.isInputEnabled else { return nil }

            self.keyboardState.clearLifecycleUndoCandidate()
            self.executeAction()
            let nextInterval = repeatBehavior.interval(forHoldDuration: holdDuration)
            return RepeatTickStep(nextDelay: nextInterval, emitsHaptic: true)
        }
    }

    private func stopRepeatTimer() {
        repeatEngine.stop()
    }

    private func cancelPress() {
        hideModifierLockHint()
        if let modifier = definition.action.modifierKey {
            _ = keyboardState.endModifierHold(modifier)
            keyboardState.clearModifierHintRowElevation(rowIndex)
        }

        isPressed = false
        keyboardState.endKeyCallout(id: definition.id)
        stopRepeatTimer()
        hideSpacebarQuickMenu(animated: false)
        keyboardState.clearPendingSpacePress()
        cancelSpacebarLongPressTask()
        resetPressTracking()
    }

    private func resetPressTracking() {
        modifierPressStartTime = nil
        modifierSlideChordTarget = nil
        hasEverHoveredChordTarget = false
        isModifierSlideLockArmed = false
        modifierSlideLockVisualProgress = 0
    }

    private func modifierSlideProgress(from translationHeight: CGFloat) -> CGFloat {
        let upwardDistance = max(0, -translationHeight)
        let normalized = upwardDistance / modifierSlideLockMaxVisualDistance
        return min(max(normalized, 0), 1)
    }

    private var fontSize: CGFloat {
        switch definition.style {
        case .character:
            if case .character(let c) = definition.action, c.first?.isLetter == true {
                return 22
            }
            if case .character(let c) = definition.action, c == "-" || c == "~" || c == "`" {
                return 20
            }
            return 18
        case .modifier:
            if definition.action == .ctrl {
                return 21
            }
            if definition.action == .escape {
                return 14
            }
            return 19
        case .action: return 20
        case .space: return 13
        }
    }

    private var fontWeight: Font.Weight {
        switch definition.style {
        case .character: return .regular
        case .modifier: return .medium
        case .action: return .medium
        case .space: return .regular
        }
    }

    private var fontDesign: Font.Design {
        switch definition.style {
        case .character, .space: return .default
        case .modifier, .action: return .default
        }
    }

    private var backgroundColor: Color {
        if definition.action == .dictation {
            if renderInput.isDictationProcessing {
                return isPressed ? AppTheme.processingKeyPressed : AppTheme.processingKey
            }
            if renderInput.isDictationCaptureActive {
                return isPressed ? AppTheme.destructiveKeyPressed : AppTheme.destructiveKey
            }
            return isPressed ? AppTheme.actionKeyPressed : AppTheme.actionKey
        }

        if isLockedModifier {
            return isPressed
                ? AppTheme.keyLockedModifierPressed
                : AppTheme.keyLockedModifierIdle
        }

        if renderInput.isModifierActive {
            return isPressed
                ? AppTheme.keyActiveModifierPressed
                : AppTheme.keyActiveModifierIdle
        }

        switch definition.style {
        case .character:
            return isPressed
                ? AppTheme.keyCharacterPressed
                : AppTheme.keyCharacterIdle
        case .modifier:
            return isPressed
                ? AppTheme.keyModifierPressed
                : AppTheme.keyModifierIdle
        case .action:
            return isPressed ? AppTheme.actionKeyPressed : AppTheme.actionKey
        case .space:
            return isPressed
                ? AppTheme.keySpacePressed
                : AppTheme.keySpaceIdle
        }
    }

    private var buttonScale: CGFloat {
        guard definition.action == .dictation else {
            return isPressed ? 0.95 : 1.0
        }

        if renderInput.isDictationProcessing {
            return 1.0
        }

        if renderInput.isDictationCaptureActive {
            return isPressed ? 1.02 : 1.08
        }

        return isPressed ? 0.95 : 1.0
    }

    private var keyForegroundColor: Color {
        isLockedModifier ? AppTheme.keyLockedModifierIcon : AppTheme.primaryText
    }

    private var strokeColor: Color {
        isLockedModifier ? AppTheme.keyLockedModifierStroke : AppTheme.keyStroke
    }

    private var calloutLabel: String? {
        guard case .character(let value) = definition.action else { return nil }
        guard value.count == 1 else { return nil }
        return displayLabel
    }

    private var supportsKeyCallout: Bool {
        calloutLabel != nil
    }

    private var shouldShowKeyCallout: Bool {
        supportsKeyCallout && isPressed && renderInput.isInputEnabled
    }

    private var keyZIndex: Double {
        VisualLayering.KeyboardKeys.resolvedZIndex(
            isSpacebarOverlayVisible: isSpacebarQuickMenuVisible,
            hasActiveKeyCallout: shouldShowKeyCallout
        )
    }

    private var strokeLineWidth: CGFloat {
        isLockedModifier ? 2.5 : 1.0
    }

    private var strokeOpacity: Double {
        if isLockedModifier {
            return isPressed ? 0.95 : 0.88
        }
        return isPressed ? 0.68 : 0.48
    }

    private var shouldShowModifierLockHint: Bool {
        definition.action.isChordModifier
            && isPressed
            && isModifierLockHintVisible
            && renderInput.isInputEnabled
            && !isLockedModifier
    }

    private var isLockedModifier: Bool {
        renderInput.isModifierLocked
    }

    private var cornerRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: baseCornerRadius,
            bottomLeading: isBottomLeftCornerKey ? outerCornerRadius : baseCornerRadius,
            bottomTrailing: isBottomRightCornerKey ? outerCornerRadius : baseCornerRadius,
            topTrailing: baseCornerRadius
        )
    }

    private var isBottomLeftCornerKey: Bool {
        definition.id == "key-#+=" || definition.id == "key-abc-r5"
    }

    private var isBottomRightCornerKey: Bool {
        definition.action == .enter
    }

    private var isSpacebarKey: Bool {
        definition.action == .space
    }

    private var requiresGlobalFrameTracking: Bool {
        definition.action.isChordModifier
            || (definition.action.supportsModifierSlideChordTarget
                && keyboardState.isModifierSlideChordSessionActive)
    }

    private var spacebarOverlayGapFromSpacebar: CGFloat {
        SpacebarQuickShellOverlayLayout.gapFromSpacebar
    }

    private var spacebarQuickMenuOverlayContent: some View {
        SpacebarQuickShellOverlay(
            shellCards: spacebarShellCards,
            highlightedWindowID: highlightedSpacebarShellWindowID,
            hoverLocation: spacebarShellHoverLocation,
            keyWidth: width
        )
    }

    private var spacebarOverlayVisibilityTransition: AnyTransition {
        AnyTransition.modifier(
            active: SpacebarOverlayVisibilityModifier(
                opacity: 0,
                scaleX: 1,
                scaleY: 1,
                riseOffset: spacebarOverlayHiddenRiseOffset
            ),
            identity: SpacebarOverlayVisibilityModifier(
                opacity: 1,
                scaleX: 1,
                scaleY: 1,
                riseOffset: 0
            )
        )
    }

    private var spacebarOverlayHiddenRiseOffset: CGFloat {
        SpacebarQuickShellOverlayLayout.hiddenRiseOffset
    }
}

private struct ImmediateKeyTouchValue {
    let startLocation: CGPoint
    let location: CGPoint
    let globalLocation: CGPoint

    var translation: CGSize {
        CGSize(
            width: location.x - startLocation.x,
            height: location.y - startLocation.y
        )
    }
}

private struct ImmediateKeyRawTouchValue {
    let startGlobalLocation: CGPoint
    let globalLocation: CGPoint
}

private final class ImmediateKeyTouchRecognizer: UIGestureRecognizer {
    enum Phase {
        case began
        case changed
        case ended
        case cancelled
    }

    var touchHandler: ((Phase, ImmediateKeyRawTouchValue) -> Void)?

    private var primaryTouch: UITouch?
    private var startGlobalLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard primaryTouch == nil, let touch = touches.first else { return }
        let globalLocation = touch.location(in: nil)
        primaryTouch = touch
        startGlobalLocation = globalLocation
        // SwiftUI can delay a recognizer's action while system gestures remain
        // possible. Forward raw touch-down before entering the state machine.
        touchHandler?(
            .began,
            ImmediateKeyRawTouchValue(
                startGlobalLocation: globalLocation,
                globalLocation: globalLocation
            )
        )
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = primaryTouch,
              touches.contains(where: { $0 === touch }),
              let startGlobalLocation else { return }
        touchHandler?(
            .changed,
            ImmediateKeyRawTouchValue(
                startGlobalLocation: startGlobalLocation,
                globalLocation: touch.location(in: nil)
            )
        )
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = primaryTouch,
              touches.contains(where: { $0 === touch }),
              let startGlobalLocation else { return }
        touchHandler?(
            .ended,
            ImmediateKeyRawTouchValue(
                startGlobalLocation: startGlobalLocation,
                globalLocation: touch.location(in: nil)
            )
        )
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = primaryTouch,
              touches.contains(where: { $0 === touch }),
              let startGlobalLocation else { return }
        touchHandler?(
            .cancelled,
            ImmediateKeyRawTouchValue(
                startGlobalLocation: startGlobalLocation,
                globalLocation: touch.location(in: nil)
            )
        )
        state = .cancelled
    }

    override func reset() {
        primaryTouch = nil
        startGlobalLocation = nil
        super.reset()
    }
}

private struct ImmediateKeyTouchGesture: UIGestureRecognizerRepresentable {
    final class Coordinator {
        var converter: CoordinateSpaceConverter

        init(converter: CoordinateSpaceConverter) {
            self.converter = converter
        }

        func convert(_ rawValue: ImmediateKeyRawTouchValue) -> ImmediateKeyTouchValue {
            ImmediateKeyTouchValue(
                startLocation: converter.convert(
                    globalPoint: rawValue.startGlobalLocation,
                    to: .local
                ),
                location: converter.convert(
                    globalPoint: rawValue.globalLocation,
                    to: .local
                ),
                globalLocation: rawValue.globalLocation
            )
        }
    }

    let onBegan: (ImmediateKeyTouchValue) -> Void
    let onChanged: (ImmediateKeyTouchValue) -> Void
    let onEnded: (ImmediateKeyTouchValue) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> ImmediateKeyTouchRecognizer {
        let recognizer = ImmediateKeyTouchRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        configure(recognizer, coordinator: context.coordinator)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: ImmediateKeyTouchRecognizer, context: Context) {
        context.coordinator.converter = context.converter
        configure(recognizer, coordinator: context.coordinator)
    }

    private func configure(_ recognizer: ImmediateKeyTouchRecognizer, coordinator: Coordinator) {
        recognizer.touchHandler = { phase, rawValue in
            // The cancelled arm must never touch the coordinate converter:
            // UIKit delivers touchesCancelled synchronously while SwiftUI
            // unregisters the recognizer during subgraph invalidation (for
            // example when hiding the keyboard unmounts the key grid with a
            // finger still down), and converting reads a GeometryProxy
            // attribute of the subgraph being destroyed — an AttributeGraph
            // namespace violation that aborts the process (AGENTTY-33).
            switch phase {
            case .began:
                onBegan(coordinator.convert(rawValue))
            case .changed:
                onChanged(coordinator.convert(rawValue))
            case .ended:
                onEnded(coordinator.convert(rawValue))
            case .cancelled:
                onCancelled()
            }
        }
    }
}
