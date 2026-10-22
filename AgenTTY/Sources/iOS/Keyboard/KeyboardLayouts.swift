import SwiftUI

enum KeyboardLayouts {

    static func letterRows() -> [[KeyDefinition]] {
        [
            modifierRow,
            row("qwertyuiop"),
            row("asdfghjkl"),
            letterRow4,
            letterRow5,
        ]
    }

    static var symbolRows: [[KeyDefinition]] {
        [
            numberRow,
            shellSymbolRow2,
            shellSymbolRow3,
            shellSymbolRow4,
            symbolRow5,
        ]
    }

    private static let modifierRow: [KeyDefinition] = {
        [
            key("esc", .escape, style: .modifier),
            key("\u{2303}", .ctrl, style: .modifier),
            key("\u{2325}", .alt, style: .modifier),
            key("\u{21E5}", .tab, style: .modifier),
            key("dpad", .directionPad, style: .modifier),
            charDef("-"),
            charDef("~"),
            charDef("/"),
        ]
    }()

    private static let numberRow: [KeyDefinition] = {
        "1234567890".map { charDef(String($0)) }
    }()

    private static let shellSymbolRow2: [KeyDefinition] = {
        row("-/:;()$&@\"")
    }()

    private static let shellSymbolRow3: [KeyDefinition] = {
        row("[]{}#%^*+=")
    }()

    private static let shellSymbolRow4: [KeyDefinition] = {
        var keys = row("_\\|<>,!?'")
        keys.append(KeyDefinition(id: "key-backspace-sym-r4", action: .backspace, label: "\u{232B}", widthWeight: 1.5, style: .modifier))
        return keys
    }()

    private static func row(_ chars: String) -> [KeyDefinition] {
        chars.map { charDef(String($0)) }
    }

    private static let letterRow4: [KeyDefinition] = {
        var keys: [KeyDefinition] = []
        keys.append(key("\u{21E7}", .shift, width: 1.5, style: .modifier))
        keys.append(contentsOf: "zxcvbnm".map { charDef(String($0)) })
        keys.append(key("\u{232B}", .backspace, width: 1.5, style: .modifier))
        return keys
    }()

    private static let letterRow5: [KeyDefinition] = {
        [
            key("#+=", .symbolLayer, width: 1.6, style: .modifier),
            key("dictation", .dictation, width: 1.6, style: .modifier),
            KeyDefinition(id: "space", action: .space, label: "", widthWeight: 4.2, style: .space),
            KeyDefinition(id: "char-.", action: .character("."), label: ".", widthWeight: 1.1, style: .character),
            key("\u{21B5}", .enter, width: 1.6, style: .action),
        ]
    }()

    private static let symbolRow5: [KeyDefinition] = {
        [
            KeyDefinition(id: "key-abc-r5", action: .symbolLayer, label: "abc", widthWeight: 1.6, style: .modifier),
            KeyDefinition(id: "key-dictation-sym", action: .dictation, label: "dictation", widthWeight: 1.6, style: .modifier),
            KeyDefinition(id: "space-sym", action: .space, label: "", widthWeight: 4.2, style: .space),
            KeyDefinition(id: "char-`", action: .character("`"), label: "`", widthWeight: 1.1, style: .character),
            KeyDefinition(id: "key-enter-sym", action: .enter, label: "\u{21B5}", widthWeight: 1.6, style: .action),
        ]
    }()

    private static func charDef(_ c: String) -> KeyDefinition {
        KeyDefinition(id: "char-\(c)", action: .character(c), label: c, widthWeight: 1.0, style: .character)
    }

    private static func key(
        _ label: String,
        _ action: KeyAction,
        width: CGFloat = 1.0,
        style: KeyDefinition.KeyStyle
    ) -> KeyDefinition {
        KeyDefinition(id: "key-\(label)", action: action, label: label, widthWeight: width, style: style)
    }
}
