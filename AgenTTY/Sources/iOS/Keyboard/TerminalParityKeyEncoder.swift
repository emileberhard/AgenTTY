import Foundation

enum TerminalParityKeyEncoder {
    static func encodeCharacter(
        _ char: String,
        isUppercase: Bool,
        modifiers: Set<ModifierKey>
    ) -> [UInt8] {
        let output = isUppercase ? char.uppercased() : char
        let basePayload: [UInt8]

        if modifiers.contains(.ctrl), let ctrlByte = ctrlComboByte(for: output) {
            basePayload = [ctrlByte]
        } else {
            basePayload = utf8Bytes(for: output)
        }

        if modifiers.contains(.alt) {
            return [0x1B] + basePayload
        }
        return basePayload
    }

    static func encodeNonCharacter(action: KeyAction, modifiers: Set<ModifierKey>) -> [UInt8]? {
        switch action {
        case .arrowUp:
            return encodeArrow(finalByte: 0x41, modifiers: modifiers)
        case .arrowDown:
            return encodeArrow(finalByte: 0x42, modifiers: modifiers)
        case .arrowRight:
            return encodeArrow(finalByte: 0x43, modifiers: modifiers)
        case .arrowLeft:
            return encodeArrow(finalByte: 0x44, modifiers: modifiers)
        case .tab:
            return encodeTab(modifiers: modifiers)
        case .enter:
            return encodeEnter(modifiers: modifiers)
        case .backspace:
            return encodeBackspace(modifiers: modifiers)
        case .escape:
            return encodeEscape(modifiers: modifiers)
        case .space:
            return encodeSpace(modifiers: modifiers)
        default:
            return nil
        }
    }

    private static func encodeArrow(finalByte: UInt8, modifiers: Set<ModifierKey>) -> [UInt8] {
        guard let modifierCode = modifierCode(for: modifiers) else {
            return [0x1B, 0x5B, finalByte]
        }
        return csi1(modifierCode: modifierCode, finalByte: finalByte)
    }

    private static func encodeTab(modifiers: Set<ModifierKey>) -> [UInt8] {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        if hasShift, !hasAlt, !hasCtrl {
            return [0x1B, 0x5B, 0x5A]
        }
        if hasAlt, !hasShift, !hasCtrl {
            return [0x1B, 0x09]
        }
        if let modifierCode = modifierCode(for: modifiers) {
            return csi27(modifierCode: modifierCode, keyCode: 9)
        }
        return [0x09]
    }

    private static func encodeEnter(modifiers: Set<ModifierKey>) -> [UInt8] {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        if !hasShift, !hasAlt, !hasCtrl {
            return [0x0D]
        }
        if hasAlt, !hasShift, !hasCtrl {
            return [0x1B, 0x0D]
        }
        if let modifierCode = modifierCode(for: modifiers) {
            return csi27(modifierCode: modifierCode, keyCode: 13)
        }
        return [0x0D]
    }

    private static func encodeBackspace(modifiers: Set<ModifierKey>) -> [UInt8] {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        if hasCtrl {
            if hasAlt {
                return [0x1B, 0x08]
            }
            return [0x08]
        }
        if hasAlt {
            return [0x1B, 0x7F]
        }
        if hasShift {
            return [0x7F]
        }
        return [0x7F]
    }

    private static func encodeEscape(modifiers: Set<ModifierKey>) -> [UInt8] {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        if !hasShift, !hasAlt, !hasCtrl {
            return [0x1B]
        }
        if hasAlt, !hasShift, !hasCtrl {
            return [0x1B, 0x1B]
        }
        if let modifierCode = modifierCode(for: modifiers) {
            return csi27(modifierCode: modifierCode, keyCode: 27)
        }
        return [0x1B]
    }

    private static func encodeSpace(modifiers: Set<ModifierKey>) -> [UInt8] {
        let hasCtrl = modifiers.contains(.ctrl)
        let hasAlt = modifiers.contains(.alt)
        let byte: UInt8 = hasCtrl ? 0x00 : 0x20
        if hasAlt {
            return [0x1B, byte]
        }
        return [byte]
    }

    private static func modifierCode(for modifiers: Set<ModifierKey>) -> UInt8? {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        switch (hasShift, hasAlt, hasCtrl) {
        case (false, false, false):
            return nil
        case (true, false, false):
            return 2
        case (false, true, false):
            return 3
        case (true, true, false):
            return 4
        case (false, false, true):
            return 5
        case (true, false, true):
            return 6
        case (false, true, true):
            return 7
        case (true, true, true):
            return 8
        }
    }

    private static func csi1(modifierCode: UInt8, finalByte: UInt8) -> [UInt8] {
        [0x1B, 0x5B, 0x31, 0x3B, modifierCode + 0x30, finalByte]
    }

    private static func csi27(modifierCode: UInt8, keyCode: UInt8) -> [UInt8] {
        [0x1B, 0x5B, 0x32, 0x37, 0x3B, modifierCode + 0x30, 0x3B] + decimalBytes(keyCode) + [0x7E]
    }

    private static func decimalBytes(_ value: UInt8) -> [UInt8] {
        Array(String(value).utf8)
    }

    private static func ctrlComboByte(for char: String) -> UInt8? {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else {
            return nil
        }

        let value = scalar.value
        if value >= 0x41 && value <= 0x5A {
            return UInt8(value - 0x40)
        }
        if value >= 0x61 && value <= 0x7A {
            return UInt8(value - 0x60)
        }

        switch value {
        case 0x20, 0x32, 0x40: return 0x00 // space, 2, @
        case 0x2F, 0x37, 0x5F: return 0x1F // /, 7, _
        case 0x33, 0x5B: return 0x1B // 3, [
        case 0x34, 0x5C: return 0x1C // 4, \
        case 0x35, 0x5D: return 0x1D // 5, ]
        case 0x36, 0x5E, 0x7E: return 0x1E // 6, ^, ~
        case 0x38, 0x3F: return 0x7F // 8, ?
        case 0x30: return 0x30 // 0
        case 0x31: return 0x31 // 1
        case 0x39: return 0x39 // 9
        default: return nil
        }
    }

    private static func utf8Bytes(for text: String) -> [UInt8] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        return Array(normalized.utf8)
    }
}
