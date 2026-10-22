import UIKit

enum KeyboardSurfaceMode: Equatable {
    /// AgenTTY's own key grid.
    case customGrid
    /// Slim shelf plus the iOS software keyboard driven through `UIKeyInput`.
    case systemKeyboard
    /// Slim shelf only; input comes from a hardware keyboard or nothing at all.
    case hidden
}

enum KeyboardPresentationPolicy {
    static func resolve(
        idiom: UIUserInterfaceIdiom,
        sceneSize: CGSize,
        inputMode: KeyboardInputMode,
        isHiddenByUser: Bool
    ) -> KeyboardSurfaceMode {
        // iPad landscape keeps its existing hardware-keyboard path. Size classes
        // are useless here because full-screen iPads report regular/regular in
        // both orientations.
        if idiom == .pad, sceneSize.width > 0, sceneSize.height > 0, sceneSize.height < sceneSize.width {
            return .hidden
        }
        if isHiddenByUser {
            return .hidden
        }
        return inputMode == .system ? .systemKeyboard : .customGrid
    }
}
