import Foundation
import GhosttyKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@safe
@MainActor
protocol GhosttySurfaceProvider: AnyObject {
    var ghosttySurface: ghostty_surface_t? { get }
}

@safe
@MainActor
final class GhosttyRuntime {
    private static var didInitGhostty = false
    #if os(iOS)
    private static var retainedInitArgv: [UnsafeMutablePointer<CChar>?] = unsafe []
    private static let nativeProbeModeKey = "AGENTTY_NATIVE_PROBE_MODE"
    #endif

    private var config: ghostty_config_t!
    private var app: ghostty_app_t!
    private var appIsActive = true
    private var didLogInactiveRenderSkip = false
    private var didLogInactiveTickSkip = false
    private var tickCount = 0
    private var renderCount = 0
    private var wakeupCount = 0
    private var discoveredThemeFileDataByName: [String: DiscoveredThemeFileData] = [:]

    #if os(iOS)
    private(set) var terminalBackgroundUIColor = UIColor(
        red: 40 / 255.0,
        green: 44 / 255.0,
        blue: 52 / 255.0,
        alpha: 1
    )
    #endif

    init() {
        EsmaLog.ghostty.info("runtime init start")
        GhosttyRuntimeEnvironment.configureCoreLoggingEnvironment()
        if !Self.didInitGhostty {
            #if os(iOS)
            Self.configureIOSEmbeddedEnvironment()
            AgenTTYGhosttyConfig.logBundledReferenceDriftIfNeeded()
            if unsafe Self.retainedInitArgv.isEmpty {
                let initArguments = AgenTTYGhosttyConfig.iOSInitialization.cliArguments
                Self.logGhosttyInitializationArguments(initArguments)
                unsafe Self.retainedInitArgv = Self.makeGhosttyInitArgv(
                    arguments: initArguments
                )
            }
            let initResult = unsafe Self.retainedInitArgv.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return unsafe ghostty_init(UInt(buffer.count), baseAddress)
            }
            guard initResult == GHOSTTY_SUCCESS else {
                fatalError("ghostty_init failed")
            }
            #else
            guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
                fatalError("ghostty_init failed")
            }
            #endif
            Self.didInitGhostty = true
            EsmaLog.ghostty.info("ghostty_init ok")
        }

        guard let config = unsafe ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }

        #if os(macOS)
        ghostty_config_load_default_files(config)
        #endif
        unsafe ghostty_config_load_cli_args(config)
        unsafe ghostty_config_finalize(config)
        unsafe self.config = config

        #if os(iOS)
        unsafe runNativeProbeIfEnabled(config)
        unsafe applyResolvedIOSThemeColors(from: config)
        #endif

        let diagnosticsCount = unsafe ghostty_config_diagnostics_count(config)
        EsmaLog.ghostty.debug("config finalized diagnostics=\(diagnosticsCount)")
        _ = unsafe logConfigDiagnostics(config: config, context: "config", failOnDiagnostics: false)

        var runtimeCfg = unsafe ghostty_runtime_config_s(
            userdata: unsafe Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: ghosttyRuntimeWakeupCallback,
            action_cb: ghosttyRuntimeActionCallback,
            read_clipboard_cb: ghosttyRuntimeClipboardReadCallback,
            confirm_read_clipboard_cb: ghosttyRuntimeClipboardConfirmReadCallback,
            write_clipboard_cb: ghosttyRuntimeClipboardWriteCallback,
            close_surface_cb: ghosttyRuntimeCloseSurfaceCallback
        )

        guard let app = unsafe ghostty_app_new(&runtimeCfg, config) else {
            fatalError("ghostty_app_new failed")
        }
        unsafe self.app = app
        EsmaLog.ghostty.info("app created")

        #if os(macOS)
        ghostty_app_set_focus(app, NSApp.isActive)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        #elseif os(iOS)
        unsafe ghostty_app_set_focus(app, true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        #endif
    }

    isolated deinit {
        EsmaLog.ghostty.info("runtime deinit")
        NotificationCenter.default.removeObserver(self)
        unsafe ghostty_app_free(app)
        unsafe ghostty_config_free(config)
    }

    func makeSurface(for view: GhosttySurfaceProvider) -> ghostty_surface_t? {
        var cfg = unsafe ghostty_surface_config_new()
        let viewObject = view as AnyObject
        unsafe cfg.userdata = Unmanaged.passUnretained(viewObject).toOpaque()

        #if os(macOS)
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(viewObject).toOpaque()
        ))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        #elseif os(iOS)
        unsafe cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        unsafe cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(viewObject).toOpaque()
        ))
        let viewScale = (view as? UIView)?.window?.windowScene?.screen.scale
            ?? (view as? UIView)?.traitCollection.displayScale
            ?? 2.0
        unsafe cfg.scale_factor = Double(viewScale)
        #endif

        unsafe cfg.font_size = Float(TerminalFontSizeSetting.persistedValue())

        let surface = unsafe ghostty_surface_new(app, &cfg)
        if unsafe surface == nil {
            EsmaLog.ghostty.error("surface create failed")
        } else {
            EsmaLog.ghostty.info("surface created")
        }
        return unsafe surface
    }

    func tick() {
        tickCount += 1
        if EsmaDiagnostics.shouldLog(counter: tickCount, defaultLimit: 6) {
            EsmaLog.ghostty.info("tick #\(self.tickCount) active=\(self.appIsActive)")
        }
        guard appIsActive else {
            if EsmaDiagnostics.verboseLoggingEnabled || !didLogInactiveTickSkip {
                didLogInactiveTickSkip = true
                EsmaLog.ghostty.info("tick skipped while app inactive")
            }
            return
        }
        unsafe ghostty_app_tick(app)
    }

    func render(surface: ghostty_surface_t) {
        renderCount += 1
        if EsmaDiagnostics.shouldLog(counter: renderCount, defaultLimit: 6) {
            EsmaLog.ghostty.info("runtime render #\(self.renderCount) active=\(self.appIsActive)")
        }
        guard appIsActive else {
            if EsmaDiagnostics.verboseLoggingEnabled || !didLogInactiveRenderSkip {
                didLogInactiveRenderSkip = true
                EsmaLog.ghostty.info("render skipped while app inactive")
            }
            return
        }
        unsafe ghostty_surface_refresh(surface)
        unsafe ghostty_surface_draw(surface)
        unsafe ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        unsafe ghostty_app_set_focus(app, focused)
    }

    #if os(iOS)
    func cachedDiscoveredThemeFileData(named themeName: String) -> DiscoveredThemeFileData? {
        discoveredThemeFileDataByName[themeName]
    }

    func cacheDiscoveredThemeFileData(_ data: DiscoveredThemeFileData, named themeName: String) {
        discoveredThemeFileDataByName[themeName] = data
    }

    func setTerminalBackgroundColor(_ color: UIColor) {
        terminalBackgroundUIColor = color
    }
    #endif

    func handleWakeupFromRuntimeCallback() {
        wakeupCount += 1
        if EsmaDiagnostics.shouldLog(counter: wakeupCount, defaultLimit: 10) {
            EsmaLog.ghostty.info("wakeup #\(self.wakeupCount) active=\(self.appIsActive)")
        }
        tick()
    }

    @objc private func appDidBecomeActive() {
        appIsActive = true
        didLogInactiveRenderSkip = false
        didLogInactiveTickSkip = false
        setFocus(true)
        EsmaLog.ghostty.info("app active: resumed ghostty rendering")
    }

    @objc private func appDidResignActive() {
        appIsActive = false
        setFocus(false)
        EsmaLog.ghostty.info("app inactive: paused ghostty rendering")
    }

    #if os(iOS)
    private static var nativeProbeModeEnabled: Bool {
        let rawValue: String
        if let value = unsafe getenv(nativeProbeModeKey) {
            rawValue = unsafe String(cString: value)
        } else if let legacyValue = unsafe getenv("AGENTTY_NATIVE_PROBE_MODE") {
            rawValue = unsafe String(cString: legacyValue)
        } else {
            return false
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }

    private func runNativeProbeIfEnabled(_ config: ghostty_config_t) {
        guard Self.nativeProbeModeEnabled else {
            return
        }

        EsmaLog.ghostty.info("native probe mode enabled; collecting startup ghostty API probes")
        unsafe runNativeProbe(config)
    }

    private func runNativeProbe(_ config: ghostty_config_t) {
        let info = unsafe ghostty_info()
        let version = unsafe Self.string(from: info.version, len: UInt(info.version_len))
        let buildModeRawValue = unsafe info.build_mode.rawValue
        EsmaLog.ghostty.info(
            "probe ghostty_info: version=\(version, privacy: .public) build_mode=\(buildModeRawValue, privacy: .public)"
        )

        let openPath = unsafe ghostty_config_open_path()
        let openPathValue = unsafe Self.string(from: openPath.ptr, len: UInt(openPath.len))
        let openPathSentinel = unsafe openPath.sentinel
        EsmaLog.ghostty.info(
            "probe ghostty_config_open_path: sentinel=\(openPathSentinel, privacy: .public) value=\(openPathValue, privacy: .public)"
        )
        if unsafe !openPath.sentinel {
            unsafe ghostty_string_free(openPath)
        }

        var fontSize: Float = -1
        let didResolveFontSize = unsafe ghostty_config_get(
            config,
            &fontSize,
            "font-size",
            UInt("font-size".lengthOfBytes(using: .utf8))
        )
        EsmaLog.ghostty.info(
            "probe ghostty_config_get font-size: resolved=\(didResolveFontSize, privacy: .public) value=\(fontSize, privacy: .public)"
        )

        var backgroundOpacity: Double = -1
        let didResolveBackgroundOpacity = unsafe ghostty_config_get(
            config,
            &backgroundOpacity,
            "background-opacity",
            UInt("background-opacity".lengthOfBytes(using: .utf8))
        )
        EsmaLog.ghostty.info(
            "probe ghostty_config_get background-opacity: resolved=\(didResolveBackgroundOpacity, privacy: .public) value=\(backgroundOpacity, privacy: .public)"
        )

        var palette = ghostty_config_palette_s()
        let didResolvePalette = unsafe ghostty_config_get(
            config,
            &palette,
            "palette",
            UInt("palette".lengthOfBytes(using: .utf8))
        )
        if didResolvePalette {
            // Swift 6.2 requires the outer acknowledgement; remove this split when releases use Swift 6.4+.
            #if compiler(<6.4)
            let colors = unsafe withUnsafeBytes(of: palette.colors) { raw in
                unsafe Array(raw.bindMemory(to: ghostty_config_color_s.self))
            }
            #else
            let colors = withUnsafeBytes(of: palette.colors) { raw in
                unsafe Array(raw.bindMemory(to: ghostty_config_color_s.self))
            }
            #endif
            if colors.count >= 2 {
                let first = colors[0]
                let second = colors[1]
                EsmaLog.ghostty.info(
                    "probe ghostty_config_get palette: resolved=true p0=(\(first.r, privacy: .public),\(first.g, privacy: .public),\(first.b, privacy: .public)) p1=(\(second.r, privacy: .public),\(second.g, privacy: .public),\(second.b, privacy: .public))"
                )
            } else {
                EsmaLog.ghostty.info(
                    "probe ghostty_config_get palette: resolved=true entries=\(colors.count, privacy: .public)"
                )
            }
        } else {
            EsmaLog.ghostty.info("probe ghostty_config_get palette: resolved=false")
        }

        guard let cloned = unsafe ghostty_config_clone(config) else {
            EsmaLog.ghostty.error("probe ghostty_config_clone: clone returned nil")
            return
        }
        defer { unsafe ghostty_config_free(cloned) }

        let originalBackground = unsafe resolveColorLookup(forRawKey: "background", in: config)
        let clonedBackground = unsafe resolveColorLookup(forRawKey: "background", in: cloned)
        let backgroundEqual =
            originalBackground.didResolve &&
            clonedBackground.didResolve &&
            originalBackground.color.r == clonedBackground.color.r &&
            originalBackground.color.g == clonedBackground.color.g &&
            originalBackground.color.b == clonedBackground.color.b
        EsmaLog.ghostty.info(
            "probe ghostty_config_clone background: original_resolved=\(originalBackground.didResolve, privacy: .public) clone_resolved=\(clonedBackground.didResolve, privacy: .public) equal=\(backgroundEqual, privacy: .public)"
        )

        let originalSelection = unsafe resolveColorLookup(forRawKey: "selection-background", in: config)
        let clonedSelection = unsafe resolveColorLookup(forRawKey: "selection-background", in: cloned)
        EsmaLog.ghostty.info(
            "probe ghostty_config_clone selection-background: original_resolved=\(originalSelection.didResolve, privacy: .public) clone_resolved=\(clonedSelection.didResolve, privacy: .public)"
        )

        for triggerValue in ["ctrl+c", "alt+f", "a"] {
            let trigger = unsafe ghostty_config_trigger(
                config,
                triggerValue,
                UInt(triggerValue.lengthOfBytes(using: .utf8))
            )
            EsmaLog.ghostty.info(
                "probe ghostty_config_trigger '\(triggerValue, privacy: .public)': tag=\(trigger.tag.rawValue, privacy: .public) mods=\(trigger.mods.rawValue, privacy: .public)"
            )
        }

        for key in ["copy_to_clipboard", "new_tab", "open_config"] {
            let translated = unsafe ghostty_translate(key)
            let translation = unsafe Self.nullTerminatedString(from: translated)
            EsmaLog.ghostty.info(
                "probe ghostty_translate '\(key, privacy: .public)': value=\(translation, privacy: .public)"
            )
        }
    }

    func applyTheme(named themeName: String) -> Bool {
        let initialization = AgenTTYGhosttyConfig.Initialization.withTheme(themeName)
        let configString = initialization.configString

        guard let newConfig = unsafe ghostty_config_new() else {
            EsmaLog.ghostty.error("theme switch: ghostty_config_new failed")
            return false
        }

        defer { unsafe ghostty_config_free(newConfig) }

        #if compiler(<6.4)
        unsafe configString.withCString { ptr in
            unsafe ghostty_config_load_string(newConfig, ptr, UInt(configString.utf8.count))
        }
        #else
        configString.withCString { ptr in
            unsafe ghostty_config_load_string(newConfig, ptr, UInt(configString.utf8.count))
        }
        #endif
        unsafe ghostty_config_finalize(newConfig)

        guard unsafe logConfigDiagnostics(config: newConfig, context: "theme switch", failOnDiagnostics: true) else {
            EsmaLog.ghostty.error(
                "theme switch aborted due to ghostty config diagnostics theme=\(themeName, privacy: .public)"
            )
            return false
        }

        unsafe ghostty_app_update_config(app, newConfig)

        let resolvedTheme = unsafe buildResolvedGhosttyTheme(from: newConfig, themeName: themeName)
        AppTheme.applyGhosttyResolvedTheme(resolvedTheme)
        terminalBackgroundUIColor = resolvedTheme.background

        EsmaLog.ghostty.info("applied runtime theme: \(themeName, privacy: .public)")
        return true
    }

    private static func configureIOSEmbeddedEnvironment() {
        let fileManager = FileManager.default

        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            EsmaLog.ghostty.error("failed to resolve application support directory for iOS ghostty")
            return
        }
        let xdgConfigRoot = appSupportURL.appendingPathComponent("ghostty-xdg", isDirectory: true)
        do {
            try fileManager.createDirectory(at: xdgConfigRoot, withIntermediateDirectories: true)
            unsafe setenv("XDG_CONFIG_HOME", xdgConfigRoot.path, 1)
            EsmaLog.ghostty.info("set XDG_CONFIG_HOME for iOS ghostty: \(xdgConfigRoot.path, privacy: .public)")
        } catch {
            EsmaLog.ghostty.error(
                "failed to create iOS ghostty XDG config dir: \(error.localizedDescription, privacy: .public)"
            )
        }

        if unsafe getenv("HOME") == nil {
            unsafe setenv("HOME", NSHomeDirectory(), 1)
        }

        guard let bundleResourceURL = Bundle.main.resourceURL else {
            EsmaLog.ghostty.error("missing bundle resource URL for ghostty resources")
            return
        }

        let packagedGhosttyRoot = bundleResourceURL.appendingPathComponent("ghostty", isDirectory: true)
        let packagedGhosttyThemes = packagedGhosttyRoot.appendingPathComponent("themes", isDirectory: true)
        guard fileManager.fileExists(atPath: packagedGhosttyThemes.path) else {
            EsmaLog.ghostty.error(
                "missing bundled ghostty themes at expected path: \(packagedGhosttyThemes.path, privacy: .public)"
            )
            return
        }

        unsafe setenv("GHOSTTY_RESOURCES_DIR", packagedGhosttyRoot.path, 1)
        EsmaLog.ghostty.info(
            "set GHOSTTY_RESOURCES_DIR for iOS ghostty: \(packagedGhosttyRoot.path, privacy: .public)"
        )
    }

    private static func makeGhosttyInitArgv(arguments: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var args: [UnsafeMutablePointer<CChar>?] = unsafe [strdup("agentty")]
        for argument in arguments {
            unsafe args.append(strdup(argument))
        }
        return unsafe args
    }

    private static func logGhosttyInitializationArguments(_ arguments: [String]) {
        let joined = arguments.joined(separator: " ")
        EsmaLog.ghostty.info("ghostty init cli args: \(joined, privacy: .public)")
    }

    #endif
}
