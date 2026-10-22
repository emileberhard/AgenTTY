import Foundation

enum KeyboardInputMode: String, CaseIterable {
    case custom = "custom"
    case system = "system"

    static let storageKey = "keyboardInputMode"
    static let defaultValue: KeyboardInputMode = .custom

    var displayName: String {
        switch self {
        case .custom:
            return "AgenTTY Keyboard"
        case .system:
            return "System Keyboard"
        }
    }

    var subtitle: String {
        switch self {
        case .custom:
            return "Terminal-optimized keys, modifiers, and shell switcher."
        case .system:
            return "Standard iOS keyboard, including its own dictation key."
        }
    }
}
