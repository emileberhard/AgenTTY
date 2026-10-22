import SwiftUI
import UIKit

@MainActor
enum AppTheme {
    enum GlassStyle {
        case regular
        case clear
    }

    struct GhosttyResolvedTheme {
        let background: UIColor
        let foreground: UIColor
        let selectionBackground: UIColor
        let cursorColor: UIColor
        let namedColors: [GhosttyNamedColorKey: UIColor]
        let extraNamedColors: [String: UIColor]
        let palette: [UIColor]

        static let fallback = GhosttyResolvedTheme(
            background: UIColor(red: 40 / 255.0, green: 44 / 255.0, blue: 52 / 255.0, alpha: 1),
            foreground: UIColor.white,
            selectionBackground: UIColor(red: 0.20, green: 0.38, blue: 0.65, alpha: 1),
            cursorColor: UIColor.white,
            namedColors: [:],
            extraNamedColors: [:],
            palette: []
        )
    }

    private struct Palette {
        let terminalBackground: UIColor
        let keyboardBackground: UIColor
        let keyboardGradientTop: UIColor
        let keyboardGradientBottom: UIColor
        let accent: UIColor
        let accentPressed: UIColor
        let actionKey: UIColor
        let actionKeyPressed: UIColor
        let destructiveKey: UIColor
        let destructiveKeyPressed: UIColor
        let processingKey: UIColor
        let processingKeyPressed: UIColor
        let keyCharacterIdle: UIColor
        let keyCharacterPressed: UIColor
        let keyModifierIdle: UIColor
        let keyModifierPressed: UIColor
        let keyActiveModifierIdle: UIColor
        let keyActiveModifierPressed: UIColor
        let keyLockedModifierIdle: UIColor
        let keyLockedModifierPressed: UIColor
        let keyLockedModifierStroke: UIColor
        let keyLockedModifierIcon: UIColor
        let keySpaceIdle: UIColor
        let keySpacePressed: UIColor
        let keyStroke: UIColor
        let primaryText: UIColor
        let secondaryText: UIColor
        let dimText: UIColor
        let keyShadow: UIColor
        let dpadBackground: UIColor
        let dpadIdleBackground: UIColor
        let dpadRingStroke: UIColor
        let dpadActiveArrow: UIColor
        let dpadActiveGlow: UIColor
        let dpadInactiveArrow: UIColor
        let terminalBackgroundBright: UIColor

        static let `default`: Palette = {
            let terminalBackground = UIColor(red: 40 / 255.0, green: 44 / 255.0, blue: 52 / 255.0, alpha: 1)
            let terminalForeground = UIColor.white
            let keyboardBackground = UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
            let accent = UIColor(red: 0.20, green: 0.38, blue: 0.65, alpha: 1)
            let destructive = UIColor(red: 0.72, green: 0.24, blue: 0.23, alpha: 1)
            let charFill = UIColor.white.withAlphaComponent(0.12)
            let charFillPressed = UIColor.white.withAlphaComponent(0.20)
            let modFill = UIColor.white.withAlphaComponent(0.16)
            let modFillPressed = UIColor.white.withAlphaComponent(0.24)
            let activeFill = accent.mixed(with: terminalForeground, amount: 0.30)
            let activeFillPressed = activeFill.mixed(with: terminalForeground, amount: 0.12)
            return Palette(
                terminalBackground: terminalBackground,
                keyboardBackground: keyboardBackground,
                keyboardGradientTop: keyboardBackground,
                keyboardGradientBottom: keyboardBackground,
                accent: accent,
                accentPressed: UIColor(red: 0.25, green: 0.45, blue: 0.75, alpha: 1),
                actionKey: modFill,
                actionKeyPressed: modFillPressed,
                destructiveKey: destructive,
                destructiveKeyPressed: destructive.mixed(with: terminalForeground, amount: 0.18),
                processingKey: UIColor(red: 0.68, green: 0.55, blue: 0.18, alpha: 1),
                processingKeyPressed: UIColor(red: 0.78, green: 0.64, blue: 0.22, alpha: 1),
                keyCharacterIdle: charFill,
                keyCharacterPressed: charFillPressed,
                keyModifierIdle: modFill,
                keyModifierPressed: modFillPressed,
                keyActiveModifierIdle: activeFill,
                keyActiveModifierPressed: activeFillPressed,
                keyLockedModifierIdle: UIColor(red: 0.66, green: 0.16, blue: 0.52, alpha: 0.98),
                keyLockedModifierPressed: UIColor(red: 0.74, green: 0.20, blue: 0.58, alpha: 1.0),
                keyLockedModifierStroke: UIColor(red: 1.00, green: 0.56, blue: 0.88, alpha: 1.0),
                keyLockedModifierIcon: UIColor(red: 1.00, green: 0.88, blue: 0.97, alpha: 0.99),
                keySpaceIdle: charFill,
                keySpacePressed: charFillPressed,
                keyStroke: terminalForeground.withAlphaComponent(0.20),
                primaryText: terminalForeground,
                secondaryText: terminalForeground.withAlphaComponent(0.65),
                dimText: terminalForeground.withAlphaComponent(0.3),
                keyShadow: UIColor.black.withAlphaComponent(0.4),
                dpadBackground: modFill,
                dpadIdleBackground: modFill,
                dpadRingStroke: terminalForeground.withAlphaComponent(0.7),
                dpadActiveArrow: terminalForeground,
                dpadActiveGlow: terminalForeground.withAlphaComponent(0.5),
                dpadInactiveArrow: terminalForeground.withAlphaComponent(0.3),
                terminalBackgroundBright: terminalBackground.mixed(with: terminalForeground, amount: 0.18)
            )
        }()
    }

    private static var palette = Palette.default
    private(set) static var ghosttyResolvedTheme: GhosttyResolvedTheme = .fallback

    // MARK: - Terminal

    static var terminalBackground: Color { Color(uiColor: palette.terminalBackground) }
    static var terminalBackgroundUIColor: UIColor { palette.terminalBackground }
    static var terminalBackgroundBright: Color { Color(uiColor: palette.terminalBackgroundBright) }
    static var preferredColorScheme: ColorScheme {
        ghosttyResolvedTheme.background.relativeLuminance >= 0.5 ? .light : .dark
    }
    static var darkModePrimaryText: Color {
        Color(uiColor: UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    }

    // MARK: - Shared materials

    static func glass(_ style: GlassStyle) -> Glass {
        let base: Glass = switch style {
        case .regular: .regular
        case .clear: .clear
        }
        return base.tint(glassTint(for: style))
    }

    static var controlGlassTint: Color { terminalBackground.opacity(0.25) }

    /// Shared label height for the glass icon controls in the app chrome (top
    /// menu, floating keyboard toggle); the glass capsule pads around it.
    static let chromeCapsuleHeight: CGFloat = 18
    static var surfaceOrnamentFill: Color { primaryText.opacity(0.06) }
    static var surfaceOrnamentStroke: Color { primaryText.opacity(0.14) }
    static var sheetListRowBackground: Color { surfaceOrnamentFill }

    private static func glassTint(for style: GlassStyle) -> Color {
        switch style {
        case .regular, .clear:
            return terminalBackground.opacity(0.4)
        }
    }

    // MARK: - Keyboard chrome

    static var keyboardBackground: Color { Color(uiColor: palette.keyboardBackground) }
    static var keyboardBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color(uiColor: palette.keyboardGradientTop), Color(uiColor: palette.keyboardGradientBottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Accent

    static var accent: Color { Color(uiColor: palette.accent) }
    static var accentPressed: Color { Color(uiColor: palette.accentPressed) }
    static var actionKey: Color { Color(uiColor: palette.actionKey) }
    static var actionKeyPressed: Color { Color(uiColor: palette.actionKeyPressed) }
    static var destructiveKey: Color { Color(uiColor: palette.destructiveKey) }
    static var destructiveKeyPressed: Color { Color(uiColor: palette.destructiveKeyPressed) }
    static var processingKey: Color { Color(uiColor: palette.processingKey) }
    static var processingKeyPressed: Color { Color(uiColor: palette.processingKeyPressed) }

    // MARK: - Key fills

    static var keyCharacterIdle: Color { Color(uiColor: palette.keyCharacterIdle) }
    static var keyCharacterPressed: Color { Color(uiColor: palette.keyCharacterPressed) }
    static var keyModifierIdle: Color { Color(uiColor: palette.keyModifierIdle) }
    static var keyModifierPressed: Color { Color(uiColor: palette.keyModifierPressed) }
    static var keyActiveModifierIdle: Color { Color(uiColor: palette.keyActiveModifierIdle) }
    static var keyActiveModifierPressed: Color { Color(uiColor: palette.keyActiveModifierPressed) }
    static var keyLockedModifierIdle: Color { Color(uiColor: palette.keyLockedModifierIdle) }
    static var keyLockedModifierPressed: Color { Color(uiColor: palette.keyLockedModifierPressed) }
    static var keyLockedModifierStroke: Color { Color(uiColor: palette.keyLockedModifierStroke) }
    static var keyLockedModifierIcon: Color { Color(uiColor: palette.keyLockedModifierIcon) }
    static var keySpaceIdle: Color { Color(uiColor: palette.keySpaceIdle) }
    static var keySpacePressed: Color { Color(uiColor: palette.keySpacePressed) }
    static var keyStroke: Color { Color(uiColor: palette.keyStroke) }

    // MARK: - Text

    static var primaryText: Color { Color(uiColor: palette.primaryText) }
    static var secondaryText: Color { Color(uiColor: palette.secondaryText) }
    static var dimText: Color { Color(uiColor: palette.dimText) }

    // MARK: - Shadows

    static var keyShadow: Color { Color(uiColor: palette.keyShadow) }

    // MARK: - D-pad

    static var dpadBackground: Color { Color(uiColor: palette.dpadBackground) }
    static var dpadIdleBackground: Color { Color(uiColor: palette.dpadIdleBackground) }
    static var dpadRingStroke: Color { Color(uiColor: palette.dpadRingStroke) }
    static var dpadActiveArrow: Color { Color(uiColor: palette.dpadActiveArrow) }
    static var dpadActiveGlow: Color { Color(uiColor: palette.dpadActiveGlow) }
    static var dpadInactiveArrow: Color { Color(uiColor: palette.dpadInactiveArrow) }

    static func applyGhosttyResolvedTheme(_ resolvedTheme: GhosttyResolvedTheme) {
        ghosttyResolvedTheme = resolvedTheme

        let terminalBackground = resolvedTheme.background.withAlphaComponent(1)
        let terminalForeground = resolvedTheme.foreground.withAlphaComponent(1)
        let selectionBackground = resolvedTheme.selectionBackground.withAlphaComponent(1)
        let accentSeed = selectionBackground

        let ansiYellow = paletteColor(at: 3, from: resolvedTheme.palette, fallback: accentSeed)
        let ansiRed = paletteColor(at: 1, from: resolvedTheme.palette, fallback: accentSeed)
        let ansiBrightBlack = paletteColor(
            at: 8,
            from: resolvedTheme.palette,
            fallback: terminalForeground.mixed(with: terminalBackground, amount: 0.45)
        )

        let ansiBlack = paletteColor(at: 0, from: resolvedTheme.palette, fallback: .black)
        let keyboardBackground = terminalBackground.mixed(with: ansiBlack, amount: 0.42)

        let keyBaseBackground = terminalBackground.mixed(with: terminalForeground, amount: 0.08)

        let accent = accentSeed.mixed(with: terminalBackground, amount: 0.20)
        let accentPressed = accent.mixed(with: terminalForeground, amount: 0.18)

        // Characters: neutral. Modifiers: tinted with theme yellow.
        let keyIdle = keyBaseBackground.mixed(with: ansiBrightBlack, amount: 0.18)
        let keyPressed = keyIdle.mixed(with: terminalForeground, amount: 0.14)
        let keyModifierIdle = keyBaseBackground.mixed(with: ansiYellow, amount: 0.22)
        let keyModifierPressed = keyModifierIdle.mixed(with: terminalForeground, amount: 0.14)

        // Active modifiers: selection color accent for state feedback.
        let keyActiveModifierIdle = keyModifierIdle.mixed(with: accentSeed, amount: 0.18)
        let keyActiveModifierPressed = keyActiveModifierIdle.mixed(with: terminalForeground, amount: 0.12)
        // Locked modifiers: explicit magenta-biased fill/stroke so the locked state
        // reads clearly as magenta regardless of warm terminal palettes.
        let lockedMagentaBase = UIColor(red: 0.84, green: 0.20, blue: 0.70, alpha: 1.0)
        let lockedAccentBase = lockedMagentaBase.mixed(with: accentSeed, amount: 0.22)
        let lockedFillBase = keyModifierIdle
            .mixed(with: lockedMagentaBase, amount: 0.90)
            .mixed(with: terminalBackground, amount: 0.08)
        let keyLockedModifierIdle = lockedFillBase.withAlphaComponent(0.99)
        let keyLockedModifierPressed = lockedFillBase
            .mixed(with: terminalForeground, amount: 0.10)
            .withAlphaComponent(1.0)
        let keyLockedModifierIcon = lockedAccentBase.mixed(with: terminalForeground, amount: 0.42).withAlphaComponent(1.0)
        let keyLockedModifierStroke = lockedMagentaBase
            .mixed(with: terminalForeground, amount: 0.28)
            .withAlphaComponent(1.0)

        // Dictation-specific states keep functional color signals.
        let destructiveKey = keyBaseBackground.mixed(with: ansiRed, amount: 0.42)
        let destructiveKeyPressed = keyBaseBackground.mixed(with: ansiRed, amount: 0.58)
        let processingKey = keyBaseBackground.mixed(with: ansiYellow, amount: 0.42)
        let processingKeyPressed = keyBaseBackground.mixed(with: ansiYellow, amount: 0.58)

        let shadowAlpha: CGFloat = terminalBackground.relativeLuminance > 0.5 ? 0.30 : 0.45
        let keyShadow = UIColor.black.withAlphaComponent(shadowAlpha)
        let keyStroke = terminalForeground.withAlphaComponent(0.18)

        palette = Palette(
            terminalBackground: terminalBackground,
            keyboardBackground: keyboardBackground,
            keyboardGradientTop: keyboardBackground,
            keyboardGradientBottom: keyboardBackground,
            accent: accent,
            accentPressed: accentPressed,
            actionKey: keyModifierIdle,
            actionKeyPressed: keyModifierPressed,
            destructiveKey: destructiveKey,
            destructiveKeyPressed: destructiveKeyPressed,
            processingKey: processingKey,
            processingKeyPressed: processingKeyPressed,
            keyCharacterIdle: keyIdle,
            keyCharacterPressed: keyPressed,
            keyModifierIdle: keyModifierIdle,
            keyModifierPressed: keyModifierPressed,
            keyActiveModifierIdle: keyActiveModifierIdle,
            keyActiveModifierPressed: keyActiveModifierPressed,
            keyLockedModifierIdle: keyLockedModifierIdle,
            keyLockedModifierPressed: keyLockedModifierPressed,
            keyLockedModifierStroke: keyLockedModifierStroke,
            keyLockedModifierIcon: keyLockedModifierIcon,
            keySpaceIdle: keyIdle,
            keySpacePressed: keyPressed,
            keyStroke: keyStroke,
            primaryText: terminalForeground,
            secondaryText: terminalForeground.withAlphaComponent(0.65),
            dimText: terminalForeground.withAlphaComponent(0.3),
            keyShadow: keyShadow,
            dpadBackground: keyModifierIdle.withAlphaComponent(0.50),
            dpadIdleBackground: keyModifierIdle,
            dpadRingStroke: terminalForeground.withAlphaComponent(0.72),
            dpadActiveArrow: terminalForeground,
            dpadActiveGlow: terminalForeground.withAlphaComponent(0.5),
            dpadInactiveArrow: terminalForeground.withAlphaComponent(0.3),
            terminalBackgroundBright: terminalBackground.mixed(with: terminalForeground, amount: 0.18)
        )
    }

    static func ghosttyUIColor(for key: String) -> UIColor? {
        if let typedKey = GhosttyNamedColorKey(rawValue: key) {
            return ghosttyResolvedTheme.namedColors[typedKey]
        }
        return ghosttyResolvedTheme.extraNamedColors[key]
    }

    static func ghosttyUIColor(for key: GhosttyNamedColorKey) -> UIColor? {
        ghosttyResolvedTheme.namedColors[key]
    }

    static func ghosttyColor(for key: String) -> Color? {
        guard let uiColor = ghosttyUIColor(for: key) else {
            return nil
        }
        return Color(uiColor: uiColor)
    }

    static func ghosttyColor(for key: GhosttyNamedColorKey) -> Color? {
        guard let uiColor = ghosttyUIColor(for: key) else {
            return nil
        }
        return Color(uiColor: uiColor)
    }

    static func ghosttyPaletteUIColor(at index: Int) -> UIColor? {
        guard ghosttyResolvedTheme.palette.indices.contains(index) else {
            return nil
        }
        return ghosttyResolvedTheme.palette[index]
    }

    static func ghosttyPaletteColor(at index: Int) -> Color? {
        guard let uiColor = ghosttyPaletteUIColor(at: index) else {
            return nil
        }
        return Color(uiColor: uiColor)
    }

    private static func paletteColor(at index: Int, from palette: [UIColor], fallback: UIColor) -> UIColor {
        guard palette.indices.contains(index) else {
            return fallback
        }
        return palette[index]
    }
}

/// Base label for glass icon buttons in the app chrome — the top-left menu and
/// the floating keyboard toggle use it so their metrics stay identical. Pair
/// with `.buttonStyle(.glassProminent)` + `.tint(AppTheme.controlGlassTint)`.
/// The `.contentShape(.rect)` is required because glass enlarges visual bounds
/// without expanding hit-testing.
struct ChromeGlassIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(height: AppTheme.chromeCapsuleHeight)
            .contentShape(.rect)
    }
}

private extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let t = max(0, min(1, amount))
        let lhs = rgba
        let rhs = other.rgba
        return UIColor(
            red: lhs.r + (rhs.r - lhs.r) * t,
            green: lhs.g + (rhs.g - lhs.g) * t,
            blue: lhs.b + (rhs.b - lhs.b) * t,
            alpha: lhs.a + (rhs.a - lhs.a) * t
        )
    }

    var relativeLuminance: CGFloat {
        let components = rgba
        func linearize(_ channel: CGFloat) -> CGFloat {
            if channel <= 0.03928 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }

        let r = linearize(components.r)
        let g = linearize(components.g)
        let b = linearize(components.b)
        return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    }

    private var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if unsafe getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (r, g, b, a)
        }

        var white: CGFloat = 0
        if unsafe getWhite(&white, alpha: &a) {
            return (white, white, white, a)
        }

        return (0, 0, 0, 1)
    }
}
