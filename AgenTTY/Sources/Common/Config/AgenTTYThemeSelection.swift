import Foundation

enum AgenTTYThemeSelection {
    static let storageKey = "terminalThemeName"
    static let defaultThemeName = "Catppuccin Mocha"

    struct CuratedTheme: Identifiable, Hashable {
        let name: String
        let displayName: String
        var id: String { name }

        init(name: String, displayName: String? = nil) {
            self.name = name
            self.displayName = displayName ?? name
        }
    }

    static let curatedThemes: [CuratedTheme] = [
        CuratedTheme(name: "TokyoNight", displayName: "Tokyo Night"),
        CuratedTheme(name: "Poimandres"),
        CuratedTheme(name: "Catppuccin Mocha"),
        CuratedTheme(name: "Kanagawa Wave"),
        CuratedTheme(name: "Rose Pine Moon"),
        CuratedTheme(name: "Cobalt2"),
        CuratedTheme(name: "Synthwave Everything"),
        CuratedTheme(name: "Gruvbox Dark"),
        CuratedTheme(name: "Dracula"),
        CuratedTheme(name: "Nord"),
        CuratedTheme(name: "Red Sands"),
        CuratedTheme(name: "Kanagawa Lotus"),
        CuratedTheme(name: "Catppuccin Latte"),
        CuratedTheme(name: "Dayfox"),
        CuratedTheme(name: "Rose Pine Dawn"),
        CuratedTheme(name: "Ayu Light"),
        CuratedTheme(name: "One Half Light"),
        CuratedTheme(name: "Flexoki Light"),
        CuratedTheme(name: "Poimandres White"),
        CuratedTheme(name: "GitHub Light High Contrast"),
        CuratedTheme(name: "Xcode Light"),
    ]

    static func persistedThemeName() -> String {
        persistedThemeName(from: AgenTTYSharedDefaults.store)
    }

    private static func persistedThemeName(from userDefaults: UserDefaults) -> String {
        guard let stored = userDefaults.string(forKey: storageKey) else {
            return defaultThemeName
        }
        if curatedThemes.contains(where: { $0.name == stored }) {
            return stored
        }
        return defaultThemeName
    }
}
