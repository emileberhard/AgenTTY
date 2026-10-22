import Foundation

enum AgenTTYGhosttyConfig {
    // Pinned to the bundled Ghostty version documented in `ghostty.5.md`.
    static let pinnedUpstreamCommit = "61e347a2c278263dd1392c324feaee5fb9712ee5"

    enum Reference {
        static let configOptions = "https://github.com/ghostty-org/ghostty/blob/\(AgenTTYGhosttyConfig.pinnedUpstreamCommit)/src/config/Config.zig"
        static let surfaceConfigApplication = "https://github.com/ghostty-org/ghostty/blob/\(AgenTTYGhosttyConfig.pinnedUpstreamCommit)/src/Surface.zig"
        static let viewportSizing = "https://github.com/ghostty-org/ghostty/blob/\(AgenTTYGhosttyConfig.pinnedUpstreamCommit)/src/renderer/size.zig"
        static let configTemplate = "https://github.com/ghostty-org/ghostty/blob/\(AgenTTYGhosttyConfig.pinnedUpstreamCommit)/src/config/config-template"
    }

    enum CursorStyle: String {
        case block
        case bar
        case underline
        case blockHollow = "block_hollow"
    }

    enum WindowPaddingBalance: String {
        case disabled = "false"
        case balanced = "true"
    }

    enum WindowPaddingColor: String {
        case background
        case extend
        case extendAlways = "extend-always"
    }

    struct WindowPadding: Equatable {
        let topLeft: UInt32
        let bottomRight: UInt32

        var cliValue: String {
            if topLeft == bottomRight {
                return "\(topLeft)"
            }
            return "\(topLeft),\(bottomRight)"
        }
    }

    struct ThemeName: Equatable {
        let value: String

        init(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!trimmed.isEmpty, "ghostty theme name must be non-empty")
            self.value = trimmed
        }
    }

    struct Initialization: Equatable {
        let themeName: ThemeName
        let cursorStyle: CursorStyle
        let windowPaddingX: WindowPadding
        let windowPaddingY: WindowPadding
        let windowPaddingBalance: WindowPaddingBalance
        let windowPaddingColor: WindowPaddingColor

        var normalizedThemeName: String {
            themeName.value
        }

        var cliArguments: [String] {
            var arguments: [String] = []
            arguments.append("--theme=\(normalizedThemeName)")
            arguments.append("--cursor-style=\(cursorStyle.rawValue)")
            arguments.append("--window-padding-x=\(windowPaddingX.cliValue)")
            arguments.append("--window-padding-y=\(windowPaddingY.cliValue)")
            arguments.append("--window-padding-balance=\(windowPaddingBalance.rawValue)")
            arguments.append("--window-padding-color=\(windowPaddingColor.rawValue)")
            return arguments
        }

        var configString: String {
            cliArguments.map { argument in
                guard argument.hasPrefix("--") else { return argument }
                return String(argument.dropFirst(2))
            }.joined(separator: "\n")
        }

        static func withTheme(_ themeName: String) -> Initialization {
            Initialization(
                themeName: ThemeName(themeName),
                cursorStyle: iOSInitialization.cursorStyle,
                windowPaddingX: iOSInitialization.windowPaddingX,
                windowPaddingY: iOSInitialization.windowPaddingY,
                windowPaddingBalance: iOSInitialization.windowPaddingBalance,
                windowPaddingColor: iOSInitialization.windowPaddingColor
            )
        }
    }

    // Ghostty defaults are set explicitly so runtime behavior is deterministic
    // and all knobs live in one place. Theme name is read from persisted user
    // preference once at first access; defaults to "Catppuccin Mocha" when unset.
    static let iOSInitialization: Initialization = {
        Initialization(
            themeName: ThemeName(AgenTTYThemeSelection.persistedThemeName()),
            cursorStyle: .bar,
            windowPaddingX: .init(topLeft: 2, bottomRight: 2),
            windowPaddingY: .init(topLeft: 2, bottomRight: 2),
            windowPaddingBalance: .balanced,
            windowPaddingColor: .background
        )
    }()

    #if os(iOS)
    @MainActor
    private static var didCheckBundledReferenceVersion = false

    @MainActor
    static func logBundledReferenceDriftIfNeeded(bundle: Bundle = .main) {
        #if DEBUG
        guard !didCheckBundledReferenceVersion else { return }
        didCheckBundledReferenceVersion = true

        guard let bundledCommit = bundledGhosttyCommitHash(bundle: bundle) else {
            EsmaLog.ghostty.error(
                "ghostty doc version parse failed; pinned references may be stale commit=\(pinnedUpstreamCommit, privacy: .public)"
            )
            return
        }

        if !pinnedUpstreamCommit.hasPrefix(bundledCommit) {
            EsmaLog.ghostty.error(
                "ghostty reference drift detected pinned=\(pinnedUpstreamCommit, privacy: .public) bundled=\(bundledCommit, privacy: .public)"
            )
            return
        }

        EsmaLog.ghostty.info(
            "ghostty reference commit confirmed bundled=\(bundledCommit, privacy: .public)"
        )
        #endif
    }

    private static func bundledGhosttyCommitHash(bundle: Bundle) -> String? {
        guard let resourceURL = bundle.resourceURL else {
            return nil
        }
        let docURL = resourceURL
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("doc", isDirectory: true)
            .appendingPathComponent("ghostty.5.md", isDirectory: false)
        let content: String
        do {
            content = try String(contentsOf: docURL, encoding: .utf8)
        } catch {
            EsmaLog.ghostty.error(
                "failed to read bundled ghostty.5.md at \(docURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        guard let firstLine = content.split(whereSeparator: \.isNewline).first else {
            return nil
        }

        let line = String(firstLine)
        guard let plusIndex = line.firstIndex(of: "+") else {
            return nil
        }
        let suffix = line[line.index(after: plusIndex)...]
        let hashPrefix = suffix.prefix { $0.isHexDigit }
        guard hashPrefix.count >= 8 else {
            return nil
        }
        return String(hashPrefix)
    }
    #endif
}
