import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class KeyboardState {
    var layer: KeyboardLayer = .letters
    var shiftState: ShiftState = .lowercase
    private(set) var heldModifiers: Set<ModifierKey> = []
    private(set) var oneShotModifiers: Set<ModifierKey> = []
    private(set) var lockedModifiers: Set<ModifierKey> = []
    private(set) var isInputEnabled = true
    private(set) var isKeyboardHidden = false
    private(set) var pressCancellationGeneration: UInt64 = 0
    private(set) var visualInvalidationGeneration: UInt64 = 0
    private(set) var modifierSlidePreviewBaseText: String?
    private(set) var modifierSlidePreviewTargetText: String = ""
    private(set) var modifierSlidePreviewAnchorX: CGFloat?
    private(set) var modifierSlidePreviewIsLatchedVisible = false
    private(set) var modifierHintElevatedRows: Set<Int> = []
    private(set) var activeKeyCallouts: [ActiveKeyCallout] = []

    @ObservationIgnored
    private var heldModifierUsage: Set<ModifierKey> = []
    @ObservationIgnored
    private var lifecycleUndoCandidateTime: TimeInterval?
    @ObservationIgnored
    private var suppressesNextLifecycleUndo = false
    @ObservationIgnored
    private var slideChordTargetsByKeyID: [String: SlideChordTarget] = [:]
    @ObservationIgnored
    private var hasPendingSpacePress = false
    private static let frameComparisonTolerance: CGFloat = 0.5
    private static let anchorComparisonTolerance: CGFloat = 0.25

    var isShiftActive: Bool {
        isModifierHeld(ModifierKey.shift) || shiftState == .shifted || shiftState == .capsLock
    }

    var isShiftModifierActive: Bool {
        isModifierHeld(ModifierKey.shift) || shiftState == .shifted
    }

    var isUppercase: Bool {
        shiftState == .capsLock || isShiftModifierActive
    }

    var activeModifierKeys: Set<ModifierKey> {
        var active = heldModifiers
        if shiftState == .shifted {
            active.insert(.shift)
        }
        active.formUnion(lockedModifiers)
        active.formUnion(oneShotModifiers)
        return active
    }

    var activeChordModifiers: Set<ModifierKey> {
        activeModifierKeys
    }

    var isModifierSlideChordSessionActive: Bool {
        !heldModifiers.isEmpty
    }

    func isModifierHeld(_ action: KeyAction) -> Bool {
        guard let modifier = action.modifierKey else { return false }
        return isModifierHeld(modifier)
    }

    func isModifierHeld(_ modifier: ModifierKey) -> Bool {
        heldModifiers.contains(modifier)
    }

    func isModifierActive(_ action: KeyAction) -> Bool {
        guard let modifier = action.modifierKey else { return false }
        return isModifierActive(modifier)
    }

    func isModifierActive(_ modifier: ModifierKey) -> Bool {
        if modifier == .shift {
            return isShiftActive
        }
        return heldModifiers.contains(modifier)
            || oneShotModifiers.contains(modifier)
            || lockedModifiers.contains(modifier)
    }

    func isModifierLocked(_ action: KeyAction) -> Bool {
        guard let modifier = action.modifierKey else { return false }
        return isModifierLocked(modifier)
    }

    func isModifierLocked(_ modifier: ModifierKey) -> Bool {
        if modifier == .shift {
            return shiftState == .capsLock
        }
        return lockedModifiers.contains(modifier)
    }

    func shouldHandleModifierAction(_ action: KeyAction) -> Bool {
        action.isChordModifier
    }

    func toggleShift() {
        switch shiftState {
        case .lowercase: shiftState = .shifted
        case .shifted: shiftState = .lowercase
        case .capsLock: shiftState = .lowercase
        }
    }

    func activateCapsLock() {
        shiftState = .capsLock
    }

    func consumeShift() {
        if shiftState == .shifted {
            shiftState = .lowercase
        }
    }

    func handleModifierTap(_ modifier: ModifierKey) {
        switch modifier.policy.tapBehavior {
        case .oneShot:
            toggleOneShotModifier(modifier)
        case .shiftTap:
            handleShiftTap()
        case .oneShotWithSlideLock:
            handleLockableModifierTap(modifier)
        }
    }

    func handleModifierTap(_ action: KeyAction) {
        guard let modifier = action.modifierKey else { return }
        handleModifierTap(modifier)
    }

    func lockModifierFromSlideGesture(_ modifier: ModifierKey) {
        lockModifier(modifier)
    }

    func consumeOneShotModifier(_ action: KeyAction) {
        guard let modifier = action.modifierKey else { return }
        consumeOneShotModifier(modifier)
    }

    func consumeOneShotModifiers(_ modifiers: Set<ModifierKey>) {
        for modifier in modifiers {
            consumeOneShotModifier(modifier)
        }
    }

    func beginModifierHold(_ action: KeyAction) {
        guard let modifier = action.modifierKey else { return }
        beginModifierHold(modifier)
    }

    func beginModifierHold(_ modifier: ModifierKey) {
        guard !heldModifiers.contains(modifier) else { return }
        heldModifierUsage.remove(modifier)
        heldModifiers.insert(modifier)
        setModifierSlidePreview(modifier: modifier, target: nil)
    }

    func markHeldModifierUsage() {
        guard !heldModifiers.isEmpty else { return }
        guard !heldModifiers.isSubset(of: heldModifierUsage) else { return }
        heldModifierUsage.formUnion(heldModifiers)
    }

    func endModifierHold(_ action: KeyAction) -> Bool {
        guard let modifier = action.modifierKey else { return false }
        return endModifierHold(modifier)
    }

    func endModifierHold(_ modifier: ModifierKey) -> Bool {
        guard heldModifiers.contains(modifier) || heldModifierUsage.contains(modifier) else { return false }
        let wasUsed = heldModifierUsage.contains(modifier)
        heldModifiers.remove(modifier)
        heldModifierUsage.remove(modifier)
        if heldModifiers.isEmpty {
            clearModifierSlidePreview()
        }
        return wasUsed
    }

    func toggleSymbols() {
        let nextLayer: KeyboardLayer = switch layer {
        case .letters: .symbols
        case .symbols: .letters
        }
        guard nextLayer != layer else { return }

        layer = nextLayer
        if !modifierHintElevatedRows.isEmpty {
            modifierHintElevatedRows.removeAll()
        }
    }

    func hideKeyboard() {
        suppressLifecycleUndo()
        guard !isKeyboardHidden else { return }
        isKeyboardHidden = true
    }

    func showKeyboard() {
        guard isKeyboardHidden else { return }
        isKeyboardHidden = false
    }

    func handleAppBecameActive() {
        guard !isInputEnabled else { return }
        isInputEnabled = true
    }

    func handleAppWillDeactivate() {
        guard isInputEnabled else { return }
        isInputEnabled = false
        cancelActiveInteractions()
    }

    func invalidateVisualsForThemeChange() {
        visualInvalidationGeneration &+= 1
    }

    func elevateModifierHintRow(_ rowIndex: Int) {
        guard rowIndex >= 0 else { return }
        guard !modifierHintElevatedRows.contains(rowIndex) else { return }
        modifierHintElevatedRows.insert(rowIndex)
    }

    func clearModifierHintRowElevation(_ rowIndex: Int) {
        guard rowIndex >= 0 else { return }
        guard modifierHintElevatedRows.contains(rowIndex) else { return }
        modifierHintElevatedRows.remove(rowIndex)
    }

    func isModifierHintRowElevated(_ rowIndex: Int) -> Bool {
        modifierHintElevatedRows.contains(rowIndex)
    }

    func recordLifecycleUndoCandidate(for action: KeyAction) {
        switch action {
        case .character, .space:
            lifecycleUndoCandidateTime = ProcessInfo.processInfo.systemUptime
        default:
            lifecycleUndoCandidateTime = nil
        }
    }

    func clearLifecycleUndoCandidate() {
        lifecycleUndoCandidateTime = nil
    }

    /// Unmounting `InAppKeyboardView` runs the same deactivation path that
    /// auto-sends a backspace after an accidental home-indicator swipe. Hiding
    /// the keyboard and switching to the system keyboard both unmount it
    /// deliberately, so they must arm this suppression instead of relying on
    /// the incidental ordering of `executeAction` and `onDisappear`.
    func suppressLifecycleUndo() {
        clearLifecycleUndoCandidate()
        suppressesNextLifecycleUndo = true
    }

    func consumeLifecycleUndoCandidate(within window: TimeInterval) -> Bool {
        if suppressesNextLifecycleUndo {
            suppressesNextLifecycleUndo = false
            lifecycleUndoCandidateTime = nil
            return false
        }
        guard let candidateTime = lifecycleUndoCandidateTime else { return false }
        lifecycleUndoCandidateTime = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - candidateTime
        return elapsed <= window
    }

    func beginPendingSpacePress() {
        guard !hasPendingSpacePress else { return }
        hasPendingSpacePress = true
    }

    func takePendingSpacePress() -> Bool {
        guard hasPendingSpacePress else { return false }
        hasPendingSpacePress = false
        return true
    }

    func clearPendingSpacePress() {
        guard hasPendingSpacePress else { return }
        hasPendingSpacePress = false
    }

    struct ActiveKeyCallout: Identifiable, Equatable {
        let id: String
        let rowIndex: Int
    }

    func beginKeyCallout(id: String, rowIndex: Int) {
        if let index = activeKeyCallouts.firstIndex(where: { $0.id == id }) {
            let callout = ActiveKeyCallout(id: id, rowIndex: rowIndex)
            guard activeKeyCallouts[index] != callout else { return }
            activeKeyCallouts[index] = callout
            return
        }
        activeKeyCallouts.append(ActiveKeyCallout(id: id, rowIndex: rowIndex))
    }

    func endKeyCallout(id: String) {
        guard activeKeyCallouts.contains(where: { $0.id == id }) else { return }
        activeKeyCallouts.removeAll { $0.id == id }
    }

    func hasActiveKeyCallout(in rowIndex: Int) -> Bool {
        activeKeyCallouts.contains { $0.rowIndex == rowIndex }
    }

    func updateSlideChordTarget(
        id: String,
        action: KeyAction,
        style: KeyDefinition.KeyStyle,
        label: String,
        frame: CGRect
    ) {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite else {
            return
        }
        guard frame.width > 0, frame.height > 0 else { return }

        if let existing = slideChordTargetsByKeyID[id],
           existing.action == action,
           existing.style == style,
           existing.label == label,
           Self.isApproximatelyEqual(existing.frame, frame) {
            return
        }

        slideChordTargetsByKeyID[id] = SlideChordTarget(id: id, action: action, style: style, label: label, frame: frame)
    }

    func removeSlideChordTarget(id: String) {
        guard slideChordTargetsByKeyID[id] != nil else { return }
        slideChordTargetsByKeyID.removeValue(forKey: id)
    }

    func setModifierSlidePreview(modifier: ModifierKey, target: SlideChordTarget?) {
        let baseText = "\(Self.modifierPreviewLabel(modifier)) +"
        if modifierSlidePreviewBaseText != baseText {
            modifierSlidePreviewBaseText = baseText
        }
        if let target {
            let nextTargetText = Self.targetPreviewLabel(target)
            if modifierSlidePreviewTargetText != nextTargetText {
                modifierSlidePreviewTargetText = nextTargetText
            }
            if !modifierSlidePreviewIsLatchedVisible {
                modifierSlidePreviewIsLatchedVisible = true
            }
            return
        }
        if !modifierSlidePreviewIsLatchedVisible, !modifierSlidePreviewTargetText.isEmpty {
            modifierSlidePreviewTargetText = ""
        }
    }

    func setModifierSlidePreviewAnchorX(_ x: CGFloat?) {
        guard let x else {
            guard modifierSlidePreviewAnchorX != nil else { return }
            modifierSlidePreviewAnchorX = nil
            return
        }
        guard x.isFinite else { return }
        if let current = modifierSlidePreviewAnchorX,
           abs(current - x) <= Self.anchorComparisonTolerance {
            return
        }
        modifierSlidePreviewAnchorX = x
    }

    func clearModifierSlidePreview() {
        guard modifierSlidePreviewBaseText != nil
            || !modifierSlidePreviewTargetText.isEmpty
            || modifierSlidePreviewAnchorX != nil
            || modifierSlidePreviewIsLatchedVisible else {
            return
        }
        modifierSlidePreviewBaseText = nil
        modifierSlidePreviewTargetText = ""
        modifierSlidePreviewAnchorX = nil
        modifierSlidePreviewIsLatchedVisible = false
    }

    func modifierSlideChordTarget(
        at location: CGPoint,
        excludingKeyID: String
    ) -> SlideChordTarget? {
        var bestTarget: SlideChordTarget?
        var bestArea = CGFloat.greatestFiniteMagnitude

        for target in slideChordTargetsByKeyID.values {
            guard target.id != excludingKeyID else { continue }
            guard target.action.supportsModifierSlideChordTarget else { continue }
            guard target.frame.contains(location) else { continue }

            let area = target.frame.width * target.frame.height
            if area < bestArea {
                bestArea = area
                bestTarget = target
            }
        }

        return bestTarget
    }

    private func toggleOneShotModifier(_ modifier: ModifierKey) {
        if oneShotModifiers.contains(modifier) {
            oneShotModifiers.remove(modifier)
        } else {
            oneShotModifiers.insert(modifier)
        }
    }

    private func consumeOneShotModifier(_ modifier: ModifierKey) {
        guard modifier.policy.consumesAfterChordOutput else { return }
        if modifier == .shift {
            consumeShift()
            return
        }
        oneShotModifiers.remove(modifier)
    }

    private func handleShiftTap() {
        toggleShift()
    }

    private func handleLockableModifierTap(_ modifier: ModifierKey) {
        if isModifierLocked(modifier) {
            unlockModifier(modifier)
            return
        }

        if oneShotModifiers.contains(modifier) {
            oneShotModifiers.remove(modifier)
        }
    }

    private func lockModifier(_ modifier: ModifierKey) {
        guard modifier != .shift else {
            activateCapsLock()
            return
        }
        if oneShotModifiers.contains(modifier) {
            oneShotModifiers.remove(modifier)
        }
        guard !lockedModifiers.contains(modifier) else { return }
        lockedModifiers.insert(modifier)
    }

    private func unlockModifier(_ modifier: ModifierKey) {
        guard modifier != .shift else {
            if shiftState == .capsLock {
                shiftState = .lowercase
            }
            return
        }
        if lockedModifiers.contains(modifier) {
            lockedModifiers.remove(modifier)
        }
        if oneShotModifiers.contains(modifier) {
            oneShotModifiers.remove(modifier)
        }
    }

    private func cancelActiveInteractions() {
        pressCancellationGeneration &+= 1
        clearPendingSpacePress()
        clearModifierSlidePreview()
        if !activeKeyCallouts.isEmpty {
            activeKeyCallouts.removeAll()
        }
        if !modifierHintElevatedRows.isEmpty {
            modifierHintElevatedRows.removeAll()
        }
        if !heldModifiers.isEmpty {
            heldModifiers.removeAll()
        }
        if !oneShotModifiers.isEmpty {
            oneShotModifiers.removeAll()
        }
        if !heldModifierUsage.isEmpty {
            heldModifierUsage.removeAll()
        }
        if shiftState == .shifted {
            shiftState = .lowercase
        }
    }

}
