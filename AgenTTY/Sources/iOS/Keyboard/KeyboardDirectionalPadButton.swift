import Foundation
import SwiftUI

private enum DirectionPadDirection: Hashable {
    case up
    case down
    case left
    case right

    var action: KeyAction {
        switch self {
        case .up: .arrowUp
        case .down: .arrowDown
        case .left: .arrowLeft
        case .right: .arrowRight
        }
    }

    var chevronName: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    func offset(distance: CGFloat) -> CGSize {
        switch self {
        case .up: CGSize(width: 0, height: -distance)
        case .down: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        case .right: CGSize(width: distance, height: 0)
        }
    }
}

private enum DirectionPadSpeedTier: Int, Comparable {
    case first = 1
    case second = 2
    case third = 3

    private static let minimumBaseRatePerSecond: Double = 1.0
    private static let maximumBaseRatePerSecond: Double = 11.0
    private static let midpointBaseRatePerSecond: Double =
        (minimumBaseRatePerSecond + maximumBaseRatePerSecond) / 2

    static func < (lhs: DirectionPadSpeedTier, rhs: DirectionPadSpeedTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var baseRatePerSecond: Double {
        switch self {
        case .first:
            return Self.minimumBaseRatePerSecond
        case .second:
            return Self.midpointBaseRatePerSecond
        case .third:
            return Self.maximumBaseRatePerSecond
        }
    }
}

private struct DirectionPadDirectionResolution {
    let direction: DirectionPadDirection
    let distanceFromCenter: CGFloat
}

private enum DirectionPadRepeatMode {
    case waitingInitialDelay
    case active
}

struct DirectionalPadKeyButton: View {
    let definition: KeyDefinition
    let width: CGFloat
    let keyHeight: CGFloat
    let keyboardState: KeyboardState
    let inputRouter: TerminalInputRouter
    let visualInvalidationGeneration: UInt64

    @State private var isPressed = false
    @State private var activeDirection: DirectionPadDirection?
    @State private var activeDirectionDistanceFromCenter: CGFloat = 0
    @State private var activeSpeedTier: DirectionPadSpeedTier?
    @State private var repeatMode: DirectionPadRepeatMode?
    @State private var repeatEngine = KeyboardRepeatEngine()
    private let cornerRadius: CGFloat = 5
    private let expandedScale: CGFloat = 0.85
    private let deadZoneRadiusBase: CGFloat = 30
    private let maxDistanceForRateGainBase: CGFloat = 150
    private let speedTierPullDistanceMultiplier: CGFloat = 1.20
    private let repeatInitialDelay: TimeInterval = 1.0
    private let maximumChevronCount = 3
    private let chevronTrailSpacingBase: CGFloat = 16
    private let secondChevronThreshold: CGFloat = 1.0 / 3.0
    private let thirdChevronThreshold: CGFloat = 2.0 / 3.0
    private let repeatAccelerationCurve = RepeatAccelerationCurve(
        rampDuration: 10,
        curveFactor: 2.4,
        maximumMultiplier: 10
    )

    private let armSpreadBase: CGFloat = 62
    private let expandedDiameterBase: CGFloat = 185
    private let expandedStrokeLineWidthBase: CGFloat = 1
    private let expandedOuterShadowRadiusBase: CGFloat = 12
    private let expandedOuterShadowYOffsetBase: CGFloat = 7
    private let idleChevronFontSizeBase: CGFloat = 18
    private let inactiveChevronFontSizeBase: CGFloat = 45
    private let activeChevronFontSizeBase: CGFloat = 52
    private let activeChevronGlowRadiusBase: CGFloat = 8

    private let shapeSwapSpeed: Animation = .easeOut(duration: 0.04)
    private let expandSpeed: Animation = .snappy(duration: 0.15)

    private var deadZoneRadius: CGFloat { deadZoneRadiusBase * expandedScale }
    private var maxDistanceForRateGain: CGFloat {
        maxDistanceForRateGainBase * expandedScale * speedTierPullDistanceMultiplier
    }
    private var chevronTrailSpacing: CGFloat { chevronTrailSpacingBase * expandedScale }
    private var armSpread: CGFloat { armSpreadBase * expandedScale }
    private var expandedDiameter: CGFloat { expandedDiameterBase * expandedScale }
    private var expandedStrokeLineWidth: CGFloat { expandedStrokeLineWidthBase * expandedScale }
    private var expandedOuterShadowRadius: CGFloat { expandedOuterShadowRadiusBase * expandedScale }
    private var expandedOuterShadowYOffset: CGFloat { expandedOuterShadowYOffsetBase * expandedScale }
    private var idleChevronFontSize: CGFloat { idleChevronFontSizeBase * expandedScale }
    private var inactiveChevronFontSize: CGFloat { inactiveChevronFontSizeBase * expandedScale }
    private var activeChevronFontSize: CGFloat { activeChevronFontSizeBase * expandedScale }
    private var activeChevronGlowRadius: CGFloat { activeChevronGlowRadiusBase * expandedScale }

    var body: some View {
        let _ = visualInvalidationGeneration

        ZStack {
            if isPressed {
                Circle()
                    .fill(.clear)
                    .glassEffect(AppTheme.glass(.clear), in: .circle)
                    .overlay(Circle().stroke(AppTheme.surfaceOrnamentStroke, lineWidth: expandedStrokeLineWidth))
                    .frame(width: expandedDiameter, height: expandedDiameter)
                    .shadow(
                        color: .black.opacity(0.24),
                        radius: expandedOuterShadowRadius,
                        x: 0,
                        y: expandedOuterShadowYOffset
                    )

                expandedArrows
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(idleBackground)
                    .shadow(color: AppTheme.keyShadow, radius: 0, x: 0, y: 1)
                    .frame(width: width, height: keyHeight)

                idleChevrons
            }
        }
        .frame(width: width, height: keyHeight)
        .contentShape(.rect)
        .zIndex(VisualLayering.KeyboardKeys.dpadExpanded)
        .animation(shapeSwapSpeed, value: isPressed)
        .animation(expandSpeed, value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged(handleDragChanged)
                .onEnded { _ in endPress() }
        )
        .animation(.interpolatingSpring(stiffness: 400, damping: 22), value: activeDirection)
        .onChange(of: keyboardState.pressCancellationGeneration) { _, _ in
            cancelPressForLifecycleDeactivation()
        }
        .onDisappear {
            cancelPressForViewDisappearance()
        }
    }

    // MARK: - Idle

    private let idleArmSpread: CGFloat = 8

    private var idleChevrons: some View {
        Image(systemName: "dpad")
            .font(.system(size: idleChevronFontSize, weight: .semibold, design: .default))
            .foregroundStyle(AppTheme.primaryText)
    }

    // MARK: - Expanded Arrows

    private var expandedArrows: some View {
        ZStack {
            ForEach(
                [DirectionPadDirection.up, .down, .left, .right],
                id: \.self
            ) { direction in
                directionArrow(direction)
                    .offset(direction.offset(distance: armSpread))
            }
        }
    }

    private func directionArrow(_ direction: DirectionPadDirection) -> some View {
        let isActive = direction == activeDirection
        let chevronCount = isActive ? activeDirectionChevronCount : 1
        return ZStack {
            ForEach(Array((0..<chevronCount).reversed()), id: \.self) { index in
                Image(systemName: direction.chevronName)
                    .font(.system(size: isActive ? activeChevronFontSize : inactiveChevronFontSize, weight: .heavy))
                    .offset(chevronTrailOffset(for: direction, index: index, isActive: isActive))
                    .opacity(chevronOpacity(for: index, isActive: isActive))
            }
        }
            .foregroundStyle(isActive ? AppTheme.dpadActiveArrow : AppTheme.dpadInactiveArrow)
            .scaleEffect(isActive ? 1.15 : 1.0)
            .shadow(color: isActive ? AppTheme.dpadActiveGlow : .clear, radius: activeChevronGlowRadius)
            .allowsHitTesting(false)
    }

    private var activeDirectionChevronCount: Int {
        guard activeDirection != nil else { return 1 }
        let progress = activeDirectionDistanceProgress
        if progress < secondChevronThreshold {
            return 1
        }
        if progress < thirdChevronThreshold {
            return 2
        }
        return maximumChevronCount
    }

    private var activeDirectionDistanceProgress: CGFloat {
        guard activeDirection != nil else { return 0 }
        return distanceProgress(for: activeDirectionDistanceFromCenter)
    }

    private func chevronTrailOffset(
        for direction: DirectionPadDirection,
        index: Int,
        isActive: Bool
    ) -> CGSize {
        guard isActive else { return .zero }
        let step = CGFloat(index) * chevronTrailSpacing
        switch direction {
        case .up:
            return CGSize(width: 0, height: -step)
        case .down:
            return CGSize(width: 0, height: step)
        case .left:
            return CGSize(width: -step, height: 0)
        case .right:
            return CGSize(width: step, height: 0)
        }
    }

    private func chevronOpacity(for index: Int, isActive: Bool) -> Double {
        guard isActive else { return 1 }
        switch index {
        case 0:
            return 1
        case 1:
            return 0.8
        default:
            return 0.6
        }
    }

    // MARK: - Gesture Handling

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard keyboardState.isInputEnabled else { return }

        if !isPressed {
            beginPress()
        }
        updateActiveDirection(for: value.location)
    }

    private func beginPress() {
        guard keyboardState.isInputEnabled else { return }
        isPressed = true
        activeDirection = nil
        activeDirectionDistanceFromCenter = 0
        activeSpeedTier = nil
        inputRouter.setDirectionalPadInteractionActive(true)
        KeyboardHaptics.keyTap(style: definition.style)
    }

    private func updateActiveDirection(for location: CGPoint) {
        guard keyboardState.isInputEnabled else {
            stopRepeatTimer()
            return
        }

        let resolution = directionResolution(for: location)
        guard let resolution else {
            activeDirection = nil
            activeDirectionDistanceFromCenter = 0
            activeSpeedTier = nil
            stopRepeatTimer()
            return
        }

        let nextSpeedTier = speedTier(forDistanceFromCenter: resolution.distanceFromCenter)

        if resolution.direction == activeDirection {
            activeDirectionDistanceFromCenter = resolution.distanceFromCenter
            updateSpeedTier(nextSpeedTier, emitsInitialHaptic: false)
            maybePromoteToImmediateRepeat(for: resolution.direction, speedTier: nextSpeedTier)
            return
        }

        activeDirection = resolution.direction
        activeDirectionDistanceFromCenter = resolution.distanceFromCenter
        activeSpeedTier = nil
        repeatMode = nil
        updateSpeedTier(nextSpeedTier, emitsInitialHaptic: true)
        emitDirectionPress(resolution.direction)
        startRepeatTimer(for: resolution.direction, speedTier: nextSpeedTier)
    }

    private func emitDirectionPress(_ direction: DirectionPadDirection) {
        KeyboardHaptics.directionStepTick()
        inputRouter.handleKeyAction(direction.action, keyboardState: keyboardState)
    }

    private func updateSpeedTier(_ nextSpeedTier: DirectionPadSpeedTier, emitsInitialHaptic: Bool) {
        let previousSpeedTier = activeSpeedTier
        activeSpeedTier = nextSpeedTier

        if let previousSpeedTier {
            guard nextSpeedTier > previousSpeedTier else { return }
            emitSpeedTierHaptic(nextSpeedTier)
            return
        }

        if emitsInitialHaptic {
            emitSpeedTierHaptic(nextSpeedTier)
        }
    }

    private func emitSpeedTierHaptic(_ speedTier: DirectionPadSpeedTier) {
        switch speedTier {
        case .first:
            KeyboardHaptics.directionSpeedLevelOne()
        case .second:
            KeyboardHaptics.directionSpeedLevelTwo()
        case .third:
            KeyboardHaptics.directionSpeedLevelThree()
        }
    }

    private func endPress() {
        isPressed = false
        activeDirection = nil
        activeDirectionDistanceFromCenter = 0
        activeSpeedTier = nil
        repeatMode = nil
        inputRouter.setDirectionalPadInteractionActive(false)
        stopRepeatTimer()
    }

    private func directionResolution(for location: CGPoint) -> DirectionPadDirectionResolution? {
        let center = CGPoint(x: width / 2, y: keyHeight / 2)
        let deltaX = location.x - center.x
        let deltaY = location.y - center.y
        let magnitude = hypot(deltaX, deltaY)
        guard magnitude >= deadZoneRadius else { return nil }

        let direction: DirectionPadDirection
        if abs(deltaX) >= abs(deltaY) {
            direction = deltaX >= 0 ? .right : .left
        } else {
            direction = deltaY >= 0 ? .down : .up
        }
        return DirectionPadDirectionResolution(
            direction: direction,
            distanceFromCenter: magnitude
        )
    }

    private func currentDirectionalRate(forHoldDuration holdDuration: TimeInterval) -> Double {
        let speedTier = activeSpeedTier ?? speedTier(forDistanceFromCenter: activeDirectionDistanceFromCenter)
        let baseRate = speedTier.baseRatePerSecond
        let multiplier = repeatAccelerationCurve.multiplier(forHoldDuration: holdDuration)
        return baseRate * multiplier
    }

    private func startRepeatTimer(for direction: DirectionPadDirection, speedTier: DirectionPadSpeedTier) {
        let initialDelay = speedTier >= .second ? 0 : repeatInitialDelay
        startRepeatTimer(for: direction, initialDelay: initialDelay)
    }

    private func startRepeatTimer(for direction: DirectionPadDirection, initialDelay: TimeInterval) {
        stopRepeatTimer()
        repeatMode = initialDelay > 0 ? .waitingInitialDelay : .active
        repeatEngine.start(
            initialDelay: initialDelay,
            hapticMinimumInterval: nil
        ) { holdDuration in
            guard self.activeDirection == direction else { return nil }
            guard self.isPressed else { return nil }
            guard self.keyboardState.isInputEnabled else { return nil }
            self.repeatMode = .active
            let repeatRate = self.currentDirectionalRate(forHoldDuration: holdDuration)
            self.emitDirectionPress(direction)
            return RepeatTickStep(nextDelay: 1 / repeatRate, emitsHaptic: false)
        }
    }

    private func maybePromoteToImmediateRepeat(
        for direction: DirectionPadDirection,
        speedTier: DirectionPadSpeedTier
    ) {
        guard speedTier >= .second else { return }
        guard repeatMode == .waitingInitialDelay else { return }
        startRepeatTimer(for: direction, initialDelay: 0)
    }

    private func stopRepeatTimer() {
        repeatMode = nil
        repeatEngine.stop()
    }

    private func cancelPressForLifecycleDeactivation() {
        isPressed = false
        activeDirection = nil
        activeDirectionDistanceFromCenter = 0
        activeSpeedTier = nil
        repeatMode = nil
        inputRouter.setDirectionalPadInteractionActive(false)
        stopRepeatTimer()
    }

    private func cancelPressForViewDisappearance() {
        isPressed = false
        activeDirection = nil
        activeDirectionDistanceFromCenter = 0
        activeSpeedTier = nil
        repeatMode = nil
        inputRouter.setDirectionalPadInteractionActive(false)
        stopRepeatTimer()
    }

    private func distanceProgress(for distanceFromCenter: CGFloat) -> CGFloat {
        let distanceBeyondTrigger = max(distanceFromCenter - deadZoneRadius, 0)
        guard maxDistanceForRateGain > 0 else { return 1 }
        return min(distanceBeyondTrigger / maxDistanceForRateGain, 1)
    }

    private func speedTier(forDistanceFromCenter distanceFromCenter: CGFloat) -> DirectionPadSpeedTier {
        let progress = distanceProgress(for: distanceFromCenter)
        if progress < secondChevronThreshold {
            return .first
        }
        if progress < thirdChevronThreshold {
            return .second
        }
        return .third
    }

    private var idleBackground: Color {
        AppTheme.dpadIdleBackground
    }
}
