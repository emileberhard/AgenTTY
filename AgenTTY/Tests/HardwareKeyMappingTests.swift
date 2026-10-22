import UIKit
import XCTest
@testable import AgenTTY_iOS

final class HardwareKeyMappingTests: XCTestCase {
    @MainActor
    func testCommandBackspaceMapsToControlBackspaceLineDeletion() {
        let mapped = HardwareKeyMapping.commandModifiedMapping(
            keyCode: .keyboardDeleteOrBackspace,
            modifierFlags: .command
        )

        XCTAssertEqual(mapped?.action, .backspace)
        XCTAssertEqual(mapped?.modifiers, Set<ModifierKey>([.ctrl]))
    }

    @MainActor
    func testCommandLetterStillFallsThroughToUIKit() {
        let mapped = HardwareKeyMapping.commandModifiedMapping(
            keyCode: .keyboardW,
            modifierFlags: .command
        )

        XCTAssertNil(mapped)
    }

    @MainActor
    func testNordicMagicKeyboardShiftFourEuroMapsToDollar() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "€",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: .shift
        )

        XCTAssertEqual(character, "$")
    }

    @MainActor
    func testNordicMagicKeyboardFourWithoutShiftStillUsesReportedCharacter() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "4",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: []
        )

        XCTAssertEqual(character, "4")
    }

    @MainActor
    func testShiftFourDollarLayoutsStillUseReportedCharacter() {
        let character = HardwareKeyMapping.printableCharacter(
            characters: "$",
            charactersIgnoringModifiers: "4",
            keyCode: .keyboard4,
            modifierFlags: .shift
        )

        XCTAssertEqual(character, "$")
    }
}
