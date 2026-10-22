import UIKit

/// Translates a single `UIKey` event from the responder chain into a `KeyAction`
/// plus the modifier set that the existing terminal byte encoder understands.
///
/// Only used on the iPad hardware-keyboard path. iPhone keeps the virtual-keyboard
/// pipeline; the surface never claims first responder there, so this mapper is
/// dormant on iPhone.
@MainActor
enum HardwareKeyMapping {
    struct Mapped {
        let action: KeyAction
        let modifiers: Set<ModifierKey>
    }

    /// Returns nil to let the press fall through to UIKit's default handling.
    /// In particular: Cmd-modified chords (other than Cmd+V, which is bound via
    /// `keyCommands` → `paste(_:)`, and Cmd+Backspace, which mirrors
    /// Ctrl+Backspace line deletion) and modifier-only key-downs.
    static func map(_ key: UIKey) -> Mapped? {
        let modifiers = modifierSet(for: key.modifierFlags)

        if let commandMapped = commandModifiedMapping(
            keyCode: key.keyCode,
            modifierFlags: key.modifierFlags
        ) {
            return commandMapped
        }

        // Cmd is reserved for `UIKeyCommand` shortcuts and system menu chords.
        // Letting it fall through means standard Cmd+W / Cmd+Tab / etc. keep working.
        if key.modifierFlags.contains(.command) { return nil }

        if let action = nonPrintableAction(for: key.keyCode, modifiers: modifiers) {
            return Mapped(action: action, modifiers: modifiers)
        }

        // Bind the upper-left `§` key on Nordic Magic Keyboards to Escape. The
        // physical key sits where vim users expect Escape; the literal `§` glyph
        // is virtually never typed in a terminal session.
        if key.charactersIgnoringModifiers == "§" {
            return Mapped(action: .escape, modifiers: [])
        }

        // Nordic ISO `<`/`>` key (between left-shift and `Z`) → always emit `/`.
        // Match by glyph (iPad Magic Keyboard reports this physical key under a
        // keyCode that does not resolve to `.keyboardNonUSBackslash` reliably,
        // so matching by character is the robust path).
        let glyph = key.charactersIgnoringModifiers
        if glyph == "<" || glyph == ">" {
            return Mapped(action: .character("/"), modifiers: [])
        }

        // Nordic `¨`/`~` key (right of `Å`) → always emit `~`, bypassing the
        // iPadOS dead-key composition that would otherwise swallow the press
        // and combine it with the next character. Matches the maintainer's macOS remap.
        if key.keyCode == .keyboardCloseBracket {
            return Mapped(action: .character("~"), modifiers: [])
        }

        guard let raw = printableCharacter(
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            keyCode: key.keyCode,
            modifierFlags: key.modifierFlags
        ) else {
            return nil
        }

        return Mapped(action: .character(raw), modifiers: modifiers)
    }

    static func commandModifiedMapping(
        keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags
    ) -> Mapped? {
        guard modifierFlags.contains(.command),
              !modifierFlags.contains(.control),
              !modifierFlags.contains(.alternate),
              keyCode == .keyboardDeleteOrBackspace else {
            return nil
        }

        return Mapped(action: .backspace, modifiers: [.ctrl])
    }

    static func printableCharacter(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags
    ) -> String? {
        if keyCode == .keyboard4,
           characters == "€",
           charactersIgnoringModifiers == "4",
           modifierFlags.contains(.shift),
           !modifierFlags.contains(.alternate),
           !modifierFlags.contains(.control) {
            return "$"
        }

        // Prefer `characters` so cased/IME-composed input flows through. Fall back
        // to `charactersIgnoringModifiers` for keys whose primary glyph depends on
        // shift but whose `characters` is empty under exotic input modes.
        var raw = characters.isEmpty ? charactersIgnoringModifiers : characters
        guard !raw.isEmpty else { return nil }

        // AgenTTY intercepts Caps Lock for dictation, so iPadOS's alphaShift
        // state ceases to be user-intent. The system still toggles it as a side
        // effect of the press, capitalizing subsequent letters; invert that here
        // so AgenTTY behaves as if Caps Lock were always off. Shift+letter still
        // produces uppercase because we re-uppercase when shift is also held.
        if modifierFlags.contains(.alphaShift) {
            raw = modifierFlags.contains(.shift) ? raw.uppercased() : raw.lowercased()
        }

        return raw
    }

    private static func modifierSet(for flags: UIKeyModifierFlags) -> Set<ModifierKey> {
        var result: Set<ModifierKey> = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.ctrl) }
        if flags.contains(.alternate) { result.insert(.alt) }
        // Caps Lock (`.alphaShift`) is already reflected in `UIKey.characters`,
        // so we deliberately do not surface it as a separate modifier.
        return result
    }

    private static func nonPrintableAction(
        for keyCode: UIKeyboardHIDUsage,
        modifiers _: Set<ModifierKey>
    ) -> KeyAction? {
        switch keyCode {
        case .keyboardReturnOrEnter, .keypadEnter:
            return .enter
        case .keyboardDeleteOrBackspace:
            return .backspace
        case .keyboardEscape:
            return .escape
        case .keyboardTab:
            return .tab
        case .keyboardSpacebar:
            return .space
        case .keyboardUpArrow:
            return .arrowUp
        case .keyboardDownArrow:
            return .arrowDown
        case .keyboardLeftArrow:
            return .arrowLeft
        case .keyboardRightArrow:
            return .arrowRight
        default:
            // Page Up/Down, F1–F12, Home/End, etc. fall through to UIKit. Users
            // can reach line-start/-end with the existing Ctrl+A / Ctrl+E chords.
            return nil
        }
    }
}
