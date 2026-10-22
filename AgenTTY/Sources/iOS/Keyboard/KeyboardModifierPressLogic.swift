import Foundation

@MainActor
enum ModifierPressLogic {
    static func begin(_ modifier: ModifierKey, keyboardState: KeyboardState, pressStartTime: inout TimeInterval?) {
        pressStartTime = ProcessInfo.processInfo.systemUptime
        keyboardState.beginModifierHold(modifier)
    }

    static func shouldRunTapAction(
        _ modifier: ModifierKey,
        keyboardState: KeyboardState,
        pressStartTime: inout TimeInterval?
    ) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let pressDuration = pressStartTime.map { now - $0 } ?? .infinity
        pressStartTime = nil
        let quickTapThreshold = modifier.policy.quickTapThreshold

        let usedAsModifier = keyboardState.endModifierHold(modifier)
        let isQuickTap = pressDuration < quickTapThreshold
        return !usedAsModifier && isQuickTap
    }
}
