import SwiftUI

@safe
struct TerminalThemesSheet: View {
    let applyTheme: (String) -> Bool
    @Environment(AppThemeToken.self) private var themeToken

    @AppStorage(AgenTTYThemeSelection.storageKey, store: AgenTTYSharedDefaults.store)
    private var persistedThemeName: String = AgenTTYThemeSelection.defaultThemeName

    @State private var previews: [String: ThemePreviewColors] = [:]
    @State private var themeApplyErrorMessage: String?

    var body: some View {
        let themeNonce = themeToken.nonce
        let preferredColorScheme = AppTheme.preferredColorScheme

        NavigationStack {
            List {
                if let themeApplyErrorMessage {
                    Section {
                        Text(themeApplyErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.red.opacity(0.08))
                }

                Section {
                    ForEach(AgenTTYThemeSelection.curatedThemes) { theme in
                        Button {
                            applyThemeSelection(theme.name)
                        } label: {
                            ThemeCardRow(
                                theme: theme,
                                preview: previews[theme.name],
                                isSelected: theme.name == persistedThemeName,
                                themeNonce: themeNonce
                            )
                        }
                        .listRowBackground(AppTheme.sheetListRowBackground)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .containerBackground(.clear, for: .navigation)
            .navigationTitle("Themes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(preferredColorScheme)
        .task {
            previews = ThemePreviewColors.loadAllCached()
            let sanitizedPersistedThemeName = AgenTTYThemeSelection.persistedThemeName()
            if persistedThemeName != sanitizedPersistedThemeName {
                persistedThemeName = sanitizedPersistedThemeName
            }
        }
    }

    private func applyThemeSelection(_ themeName: String) {
        guard themeName != persistedThemeName else { return }
        if applyTheme(themeName) {
            persistedThemeName = themeName
            themeApplyErrorMessage = nil
            return
        }
        themeApplyErrorMessage = "failed to apply theme, keeping current selection"
    }
}

// MARK: - Theme card row

@safe
private struct ThemeCardRow: View {
    let theme: AgenTTYThemeSelection.CuratedTheme
    let preview: ThemePreviewColors?
    let isSelected: Bool
    let themeNonce: Int

    var body: some View {
        let _ = themeNonce

        HStack(spacing: 14) {
            themeColorSwatch
                .frame(width: 44, height: 32)
                .clipShape(.rect(cornerRadius: 6))

            Text(theme.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: isSelected)
    }

    @ViewBuilder
    private var themeColorSwatch: some View {
        if let preview {
            ZStack {
                Rectangle().fill(preview.background)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(preview.foreground)
                        .frame(height: 3)
                        .padding(.horizontal, 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(preview.selectionBackground.opacity(0.7))
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(preview.cursorColor.opacity(0.6))
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.primaryText.opacity(0.2), lineWidth: 1)
            )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        }
    }
}

// MARK: - Theme preview color parsing

private struct ThemePreviewColors {
    let background: Color
    let foreground: Color
    let selectionBackground: Color
    let cursorColor: Color

    static func loadAllCached() -> [String: ThemePreviewColors] {
        cachedAll
    }

    private static let cachedAll: [String: ThemePreviewColors] = loadAllFromDisk()

    private static func loadAllFromDisk() -> [String: ThemePreviewColors] {
        guard let resourcesURL = Bundle.main.resourceURL else { return [:] }
        let themesDir = resourcesURL
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)

        var result: [String: ThemePreviewColors] = [:]
        for theme in AgenTTYThemeSelection.curatedThemes {
            let fileURL = themesDir.appendingPathComponent(theme.name, isDirectory: false)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if let parsed = parse(content: content) {
                result[theme.name] = parsed
            }
        }
        return result
    }

    private static func parse(content: String) -> ThemePreviewColors? {
        let parsedTheme = GhosttyThemeFileParser.parse(content: content)
        guard let bg = parsedTheme.namedColorHexByKey[GhosttyNamedColorKey.background.rawValue].flatMap(colorFromHex),
              let fg = parsedTheme.namedColorHexByKey[GhosttyNamedColorKey.foreground.rawValue].flatMap(colorFromHex) else {
            return nil
        }

        let sel = parsedTheme.namedColorHexByKey[GhosttyNamedColorKey.selectionBackground.rawValue].flatMap(colorFromHex) ?? fg
        let cursor = parsedTheme.namedColorHexByKey[GhosttyNamedColorKey.cursorColor.rawValue].flatMap(colorFromHex) ?? fg

        return ThemePreviewColors(
            background: bg, foreground: fg,
            selectionBackground: sel, cursorColor: cursor
        )
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        guard let rgb = GhosttyThemeFileParser.parseRGBComponents(hex: hex) else { return nil }
        return Color(
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue
        )
    }
}
