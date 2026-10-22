#if os(iOS)
import Foundation
import GhosttyKit
import UIKit

extension GhosttyRuntime {
    func applyResolvedIOSThemeColors(from config: ghostty_config_t) {
        let resolvedTheme = unsafe buildResolvedGhosttyTheme(from: config)
        AppTheme.applyGhosttyResolvedTheme(resolvedTheme)
        setTerminalBackgroundColor(resolvedTheme.background)

        let foregroundHex = Self.hexString(from: resolvedTheme.foreground)
        let selectionHex = Self.hexString(from: resolvedTheme.selectionBackground)
        let cursorHex = Self.hexString(from: resolvedTheme.cursorColor)
        EsmaLog.ghostty.info(
            "resolved ghostty iOS theme colors: named=\(resolvedTheme.namedColors.count, privacy: .public) extra_named=\(resolvedTheme.extraNamedColors.count, privacy: .public) palette=\(resolvedTheme.palette.count, privacy: .public) background=#\(Self.hexString(from: resolvedTheme.background), privacy: .public) foreground=#\(foregroundHex, privacy: .public) selection=#\(selectionHex, privacy: .public) cursor=#\(cursorHex, privacy: .public)"
        )
    }

    struct GhosttyConfigColorLookupResult {
        let key: String
        let didResolve: Bool
        let color: ghostty_config_color_s
    }

    struct DiscoveredThemeFileData {
        let namedColors: [String: UIColor]
        let palette: [UIColor]

        static let empty = DiscoveredThemeFileData(namedColors: [:], palette: [])
    }

    func resolveColorLookup(forRawKey key: String, in config: ghostty_config_t) -> GhosttyConfigColorLookupResult {
        var color = ghostty_config_color_s()
        let didResolve = unsafe ghostty_config_get(
            config,
            &color,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        )
        return GhosttyConfigColorLookupResult(key: key, didResolve: didResolve, color: color)
    }

    func resolveColor(for key: GhosttyNamedColorKey, in config: ghostty_config_t) -> ghostty_config_color_s? {
        let lookup = unsafe resolveColorLookup(forRawKey: key.rawValue, in: config)
        return lookup.didResolve ? lookup.color : nil
    }

    func logMissingRequiredColorDiagnostics(
        missingRequired: [String],
        discoveredKeys: Set<String>,
        in config: ghostty_config_t
    ) {
        let probeKeys = Set(GhosttyNamedColorKey.recommended.map(\.rawValue))
            .union(GhosttyNamedColorKey.required.map(\.rawValue))
            .union(missingRequired)

        EsmaLog.ghostty.error(
            "ghostty named-color probe: missing_required=\(missingRequired.joined(separator: ","), privacy: .public) discovered_count=\(discoveredKeys.count, privacy: .public)"
        )

        for key in probeKeys.sorted() {
            let lookup = unsafe resolveColorLookup(forRawKey: key, in: config)
            EsmaLog.ghostty.error(
                "ghostty_config_get probe key=\(lookup.key, privacy: .public) resolved=\(lookup.didResolve, privacy: .public) rgb=(\(lookup.color.r, privacy: .public),\(lookup.color.g, privacy: .public),\(lookup.color.b, privacy: .public)) in_theme_file=\(discoveredKeys.contains(lookup.key), privacy: .public)"
            )
        }
    }

    func resolvePalette(in config: ghostty_config_t) -> [UIColor] {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        let didResolve = unsafe ghostty_config_get(
            config,
            &palette,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        )
        guard didResolve else {
            return []
        }

        // Swift 6.2 requires the outer acknowledgement; remove this split when releases use Swift 6.4+.
        #if compiler(<6.4)
        return unsafe withUnsafeBytes(of: palette.colors) { raw in
            unsafe raw.bindMemory(to: ghostty_config_color_s.self).map { Self.uiColor(from: $0) }
        }
        #else
        return withUnsafeBytes(of: palette.colors) { raw in
            unsafe raw.bindMemory(to: ghostty_config_color_s.self).map { Self.uiColor(from: $0) }
        }
        #endif
    }

    func buildResolvedGhosttyTheme(from config: ghostty_config_t, themeName: String? = nil) -> AppTheme.GhosttyResolvedTheme {
        let discoveredThemeData = discoverThemeFileData(themeName: themeName)
        let discoveredThemeNamedColors = discoveredThemeData.namedColors
        let discoveredKeys = Set(discoveredThemeNamedColors.keys)

        var namedColors: [GhosttyNamedColorKey: UIColor] = [:]
        for key in GhosttyNamedColorKey.recommended {
            guard let color = unsafe resolveColor(for: key, in: config) else {
                continue
            }
            namedColors[key] = Self.uiColor(from: color)
        }

        let extraNamedColors = discoveredThemeNamedColors.filter { GhosttyNamedColorKey(rawValue: $0.key) == nil }

        let missingRequired = GhosttyNamedColorKey.required
            .filter { namedColors[$0] == nil }
            .map(\.rawValue)
            .sorted()
        if !missingRequired.isEmpty {
            unsafe logMissingRequiredColorDiagnostics(
                missingRequired: missingRequired,
                discoveredKeys: discoveredKeys,
                in: unsafe config
            )
        }
        if !missingRequired.isEmpty {
            assertionFailure(
                "missing required Ghostty named colors after config finalize: \(missingRequired.joined(separator: ", "))"
            )
        }

        let palette = discoveredThemeData.palette
        let fallbackTheme = AppTheme.GhosttyResolvedTheme.fallback
        let background = namedColors[.background] ?? fallbackTheme.background
        let foreground = namedColors[.foreground] ?? fallbackTheme.foreground
        if !missingRequired.isEmpty {
            EsmaLog.ghostty.error(
                "falling back to default base colors for missing ghostty keys: \(missingRequired.joined(separator: ","), privacy: .public)"
            )
        }

        var synthesizedKeys: [String] = []
        func resolveOrSynthesize(_ key: GhosttyNamedColorKey, fallback: UIColor) -> UIColor {
            if let color = namedColors[key] {
                return color
            }
            synthesizedKeys.append(key.rawValue)
            namedColors[key] = fallback
            return fallback
        }

        let selectionBackground = resolveOrSynthesize(.selectionBackground, fallback: foreground)
        let cursorColor = resolveOrSynthesize(.cursorColor, fallback: foreground)

        _ = resolveOrSynthesize(.selectionForeground, fallback: background)
        _ = resolveOrSynthesize(.cursorText, fallback: background)

        if !synthesizedKeys.isEmpty {
            EsmaLog.ghostty.info(
                "synthesized missing ghostty semantic colors: \(synthesizedKeys.sorted().joined(separator: ","), privacy: .public)"
            )
        }

        return AppTheme.GhosttyResolvedTheme(
            background: background,
            foreground: foreground,
            selectionBackground: selectionBackground,
            cursorColor: cursorColor,
            namedColors: namedColors,
            extraNamedColors: extraNamedColors,
            palette: palette
        )
    }

    func discoverThemeFileData(themeName: String? = nil) -> DiscoveredThemeFileData {
        let trimmedThemeName = (themeName ?? AgenTTYGhosttyConfig.iOSInitialization.normalizedThemeName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThemeName.isEmpty else {
            return .empty
        }

        if let cached = cachedDiscoveredThemeFileData(named: trimmedThemeName) {
            return cached
        }

        guard let resourcesDir = unsafe getenv("GHOSTTY_RESOURCES_DIR") else {
            return .empty
        }

        let resourcesURL = URL(fileURLWithPath: unsafe String(cString: resourcesDir), isDirectory: true)
        let themeURL = resourcesURL
            .appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent(trimmedThemeName, isDirectory: false)

        let content: String
        do {
            content = try String(contentsOf: themeURL, encoding: .utf8)
        } catch {
            EsmaLog.ghostty.error(
                "failed to read bundled ghostty theme file at \(themeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .empty
        }

        let parsedTheme = GhosttyThemeFileParser.parse(content: content)
        var discoveredColors: [String: UIColor] = [:]
        for (key, hexValue) in parsedTheme.namedColorHexByKey {
            guard let color = Self.uiColor(fromHex: hexValue) else { continue }
            discoveredColors[key] = color
        }

        var discoveredPalette: [Int: UIColor] = [:]
        for (index, hexValue) in parsedTheme.paletteHexByIndex {
            guard let color = Self.uiColor(fromHex: hexValue) else { continue }
            discoveredPalette[index] = color
        }

        let palette: [UIColor]
        if discoveredPalette.isEmpty {
            palette = []
        } else if discoveredPalette.keys.min() == 0 {
            var contiguousPalette: [UIColor] = []
            var index = 0
            while let color = discoveredPalette[index] {
                contiguousPalette.append(color)
                index += 1
            }
            palette = contiguousPalette
        } else {
            palette = []
        }

        let discovered = DiscoveredThemeFileData(namedColors: discoveredColors, palette: palette)
        cacheDiscoveredThemeFileData(discovered, named: trimmedThemeName)
        return discovered
    }

    func logConfigDiagnostics(
        config: ghostty_config_t,
        context: String,
        failOnDiagnostics: Bool
    ) -> Bool {
        let diagnosticsCount = unsafe ghostty_config_diagnostics_count(config)
        if diagnosticsCount == 0 {
            return true
        }

        for index in 0..<diagnosticsCount {
            let diagnostic = unsafe ghostty_config_get_diagnostic(config, index)
            guard let message = unsafe diagnostic.message else { continue }
            EsmaLog.ghostty.error(
                "\(context, privacy: .public) diagnostic[\(index)]: \(unsafe String(cString: message), privacy: .public)"
            )
        }

        return !failOnDiagnostics
    }

    static func uiColor(from color: ghostty_config_color_s) -> UIColor {
        UIColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1
        )
    }

    static func hexString(from color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if unsafe color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return unsafe String(
                format: "%02X%02X%02X",
                Int(round(r * 255)),
                Int(round(g * 255)),
                Int(round(b * 255))
            )
        }

        var white: CGFloat = 0
        if unsafe color.getWhite(&white, alpha: &a) {
            let component = Int(round(white * 255))
            return unsafe String(format: "%02X%02X%02X", component, component, component)
        }

        return "000000"
    }

    static func uiColor(fromHex rawValue: String) -> UIColor? {
        guard let rgb = GhosttyThemeFileParser.parseRGBComponents(hex: rawValue) else {
            return nil
        }
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    static func string(from pointer: UnsafePointer<CChar>?, len: UInt) -> String {
        guard let pointer = unsafe pointer else {
            return "<null>"
        }
        let data = unsafe Data(bytes: UnsafeRawPointer(pointer), count: Int(len))
        return String(decoding: data, as: UTF8.self)
    }

    static func nullTerminatedString(from pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer = unsafe pointer else {
            return "<null>"
        }
        return unsafe String(cString: pointer)
    }

}
#endif
