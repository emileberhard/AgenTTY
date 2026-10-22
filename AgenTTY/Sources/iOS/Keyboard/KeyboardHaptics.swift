import SwiftUI
import UIKit

@MainActor
enum KeyboardHapticEvent {
    case keyCharacter
    case keyModifier
    case keyAction
    case keyRepeat
    case directionStepTick
    case spacebarQuickMenuPop
    case directionSpeedLevelOne
    case directionSpeedLevelTwo
    case directionSpeedLevelThree
    case modifierSlideLockActivation
    case modifierSlideLockConfirmationLead
    case modifierSlideLockConfirmation
    case selectionChanged
    case touchSelectionStart
    case dictationStartTouchDown
    case dictationStopTouchDown
}

@MainActor
final class AppHaptics {
    static let shared = AppHaptics()

    private struct Generators {
        let medium: UIImpactFeedbackGenerator
        let heavy: UIImpactFeedbackGenerator
        let rigid: UIImpactFeedbackGenerator
        let selection: UISelectionFeedbackGenerator

        init(view: UIView) {
            medium = UIImpactFeedbackGenerator(style: .medium, view: view)
            heavy = UIImpactFeedbackGenerator(style: .heavy, view: view)
            rigid = UIImpactFeedbackGenerator(style: .rigid, view: view)
            selection = UISelectionFeedbackGenerator(view: view)
        }
    }

    private static let keepWarmInterval: TimeInterval = 0.75
    private static let directionStepTickIntensity: CGFloat = 0.30
    private static let directionSpeedLevelOneIntensity: CGFloat = 0.90
    private static let directionSpeedLevelTwoIntensity: CGFloat = 1.00
    private static let directionSpeedLevelThreeIntensity: CGFloat = 1.00

    private weak var attachedView: UIView?
    private var generators: Generators?
    private var isInteractiveSessionActive = false
    private var keepWarmTimer: Timer?

    private init() {}

    func attach(to view: UIView) {
        guard attachedView !== view else { return }
        attachedView = view
        if isInteractiveSessionActive {
            generators = Generators(view: view)
            warmAllGenerators()
            startKeepWarmTimer()
        } else {
            generators = nil
        }
    }

    func detach(from view: UIView) {
        guard attachedView === view else { return }
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
        generators = nil
        attachedView = nil
    }

    func beginInteractiveSession() {
        isInteractiveSessionActive = true
        if generators == nil, let attachedView {
            generators = Generators(view: attachedView)
        }
        guard generators != nil else { return }
        warmAllGenerators()
        startKeepWarmTimer()
    }

    private func startKeepWarmTimer() {
        guard keepWarmTimer == nil else { return }
        let timer = Timer(timeInterval: Self.keepWarmInterval, repeats: true) { _ in
            Task { @MainActor in
                Self.shared.warmAllGenerators()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepWarmTimer = timer
    }

    func endInteractiveSession() {
        isInteractiveSessionActive = false
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
        generators = nil
    }

    func play(_ event: KeyboardHapticEvent) {
        guard let generators else { return }
        switch event {
        case .keyCharacter:
            playPrepared(generators.rigid, intensity: 0.65)
        case .keyModifier:
            playPrepared(generators.rigid, intensity: 0.50)
        case .keyAction:
            playPrepared(generators.rigid, intensity: 0.62)
        case .keyRepeat:
            playPrepared(generators.rigid, intensity: 0.28)
        case .directionStepTick:
            playPrepared(generators.rigid, intensity: Self.directionStepTickIntensity)
        case .spacebarQuickMenuPop:
            playPrepared(generators.heavy, intensity: 1.0)
        case .directionSpeedLevelOne:
            playPrepared(generators.medium, intensity: Self.directionSpeedLevelOneIntensity)
        case .directionSpeedLevelTwo:
            playPrepared(generators.rigid, intensity: Self.directionSpeedLevelTwoIntensity)
        case .directionSpeedLevelThree:
            playPrepared(generators.heavy, intensity: Self.directionSpeedLevelThreeIntensity)
        case .modifierSlideLockActivation:
            playPrepared(generators.medium, intensity: 0.65)
        case .modifierSlideLockConfirmationLead:
            playPrepared(generators.medium, intensity: 0.68)
        case .modifierSlideLockConfirmation:
            playPrepared(generators.heavy, intensity: 1.0)
        case .selectionChanged:
            generators.selection.selectionChanged()
            generators.selection.prepare()
        case .touchSelectionStart:
            playPrepared(generators.rigid, intensity: 0.42)
        case .dictationStartTouchDown:
            playPrepared(generators.rigid, intensity: 0.32)
        case .dictationStopTouchDown:
            playPrepared(generators.medium, intensity: 0.26)
        }
    }

    func playThenRunAction(
        _ event: KeyboardHapticEvent,
        minimumLeadTimeNanoseconds: UInt64 = 35_000_000,
        action: @escaping @MainActor () -> Void
    ) {
        play(event)
        Task.immediate { @MainActor in
            do {
                try await Task.sleep(nanoseconds: minimumLeadTimeNanoseconds)
            } catch {
                return
            }
            action()
        }
    }

    private func warmAllGenerators() {
        guard let generators else { return }
        generators.medium.prepare()
        generators.heavy.prepare()
        generators.rigid.prepare()
        generators.selection.prepare()
    }

    private func playPrepared(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat? = nil) {
        // No prepare() directly before the fire: without a time gap it gives no
        // latency benefit, and the keep-warm timer already holds readiness.
        if let intensity {
            generator.impactOccurred(intensity: intensity)
        } else {
            generator.impactOccurred()
        }
        generator.prepare()
    }
}

@MainActor
enum KeyboardHaptics {
    private static let modifierSlideLockKaChingDelayNanoseconds: UInt64 = 85_000_000

    static func attach(to view: UIView) {
        AppHaptics.shared.attach(to: view)
    }

    static func detach(from view: UIView) {
        AppHaptics.shared.detach(from: view)
    }

    static func prepare() {
        beginInteractiveSession()
    }

    static func beginInteractiveSession() {
        AppHaptics.shared.beginInteractiveSession()
    }

    static func endInteractiveSession() {
        AppHaptics.shared.endInteractiveSession()
    }

    static func fire(_ event: KeyboardHapticEvent) {
        AppHaptics.shared.play(event)
    }

    static func runFeedbackFirstAction(
        _ event: KeyboardHapticEvent,
        actionDelayNanoseconds: UInt64 = 12_000_000,
        action: @escaping @MainActor () -> Void
    ) {
        AppHaptics.shared.playThenRunAction(
            event,
            minimumLeadTimeNanoseconds: actionDelayNanoseconds,
            action: action
        )
    }

    static func keyTap(style: KeyDefinition.KeyStyle) {
        switch style {
        case .character, .space:
            fire(.keyCharacter)
        case .modifier:
            fire(.keyModifier)
        case .action:
            fire(.keyAction)
        }
    }

    static func keyRepeat() {
        fire(.keyRepeat)
    }

    static func directionStepTick() {
        fire(.directionStepTick)
    }

    static func spacebarQuickMenuPop() {
        fire(.spacebarQuickMenuPop)
    }

    static func directionSpeedLevelOne() {
        fire(.directionSpeedLevelOne)
    }

    static func directionSpeedLevelTwo() {
        fire(.directionSpeedLevelTwo)
    }

    static func directionSpeedLevelThree() {
        fire(.directionSpeedLevelThree)
    }

    static func modifierSlideLockActivation() {
        fire(.modifierSlideLockActivation)
    }

    static func modifierSlideLockConfirmation() {
        fire(.modifierSlideLockConfirmationLead)
        Task.immediate { @MainActor in
            do {
                try await Task.sleep(nanoseconds: modifierSlideLockKaChingDelayNanoseconds)
            } catch {
                return
            }
            fire(.modifierSlideLockConfirmation)
        }
    }

    static func selectionChanged() {
        fire(.selectionChanged)
    }

    static func touchSelectionStart() {
        fire(.touchSelectionStart)
    }

    static func dictationTapStart() {
        fire(.dictationStartTouchDown)
    }

    static func dictationTapStop() {
        fire(.dictationStopTouchDown)
    }
}

struct KeyboardHapticHostView: UIViewRepresentable {
    final class HostView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                KeyboardHaptics.detach(from: self)
            } else {
                KeyboardHaptics.attach(to: self)
            }
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    static func dismantleUIView(_ uiView: HostView, coordinator: Void) {
        KeyboardHaptics.detach(from: uiView)
    }
}
