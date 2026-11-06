import Foundation
import UIKit
import Testing
@testable import AgenTTY_iOS

@Suite
struct HardwareKeyMappingTests {
    @MainActor
    @Test
    func commandBackspaceMapsToControlBackspaceLineDeletion() {
        let mapped = HardwareKeyMapping.commandModifiedMapping(
            keyCode: .keyboardDeleteOrBackspace,
            modifierFlags: .command
        )

        #expect(mapped?.action == .backspace)
        #expect(mapped?.modifiers == Set<ModifierKey>([.ctrl]))
    }

    @MainActor
    @Test
    func commandLetterStillFallsThroughToUIKit() {
        let mapped = HardwareKeyMapping.commandModifiedMapping(
            keyCode: .keyboardW,
            modifierFlags: .command
        )

        #expect(mapped == nil)
    }

    @MainActor
    @Test
    func nordicMagicKeyboardShiftFourEuroMapsToDollar() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "€",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: .shift
        )

        #expect(character == "$")
    }

    @MainActor
    @Test
    func nordicMagicKeyboardFourWithoutShiftStillUsesReportedCharacter() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "4",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: []
        )

        #expect(character == "4")
    }

    @MainActor
    @Test
    func shiftFourDollarLayoutsStillUseReportedCharacter() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "$",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: .shift
        )

        #expect(character == "$")
    }
}
