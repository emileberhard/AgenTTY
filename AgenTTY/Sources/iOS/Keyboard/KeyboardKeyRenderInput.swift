import Foundation

struct KeyButtonRenderInput: Equatable {
    let displayLabel: String
    let isInputEnabled: Bool
    /// False while no live host transport exists, which gates the spacebar
    /// quick shell switcher and any other host-dependent key affordance.
    let isHostInteractionAvailable: Bool
    let pressCancellationGeneration: UInt64
    let visualInvalidationGeneration: UInt64
    let isModifierActive: Bool
    let isModifierLocked: Bool
    let isDictationProcessing: Bool
    let isDictationCaptureActive: Bool
    let isDictationButtonActive: Bool
}
