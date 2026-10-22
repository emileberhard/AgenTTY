import Foundation

enum GhosttyNamedColorKey: String, CaseIterable, Hashable {
    case background = "background"
    case foreground = "foreground"
    case selectionBackground = "selection-background"
    case selectionForeground = "selection-foreground"
    case cursorColor = "cursor-color"
    case cursorText = "cursor-text"
    case searchForeground = "search-foreground"
    case searchBackground = "search-background"
    case searchSelectedForeground = "search-selected-foreground"
    case searchSelectedBackground = "search-selected-background"
    case splitDividerColor = "split-divider-color"
    case boldColor = "bold-color"
    case windowTitlebarBackground = "window-titlebar-background"
    case windowTitlebarForeground = "window-titlebar-foreground"

    static let required: Set<GhosttyNamedColorKey> = [
        .background,
        .foreground,
    ]

    static let recommended: Set<GhosttyNamedColorKey> = [
        .background,
        .foreground,
        .selectionBackground,
        .selectionForeground,
        .cursorColor,
        .cursorText,
        .searchForeground,
        .searchBackground,
        .searchSelectedForeground,
        .searchSelectedBackground,
        .splitDividerColor,
        .boldColor,
        .windowTitlebarBackground,
        .windowTitlebarForeground,
    ]
}
