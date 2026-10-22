import Foundation

enum KeyboardEncodingMode: String, CaseIterable {
    case defaultShortcuts = "default_shortcuts"
    case strictParity = "strict_parity"

    static let storageKey = "keyboardEncodingMode"
    static let defaultValue: KeyboardEncodingMode = .defaultShortcuts

    var displayName: String {
        switch self {
        case .defaultShortcuts:
            return "Default (Shortcuts)"
        case .strictParity:
            return "Strict Parity"
        }
    }

    var subtitle: String {
        switch self {
        case .defaultShortcuts:
            return "Parity baseline with Mac-style nav shortcuts."
        case .strictParity:
            return "No overrides. Encodes keys exactly as parity mode."
        }
    }
}
