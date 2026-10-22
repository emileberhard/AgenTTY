import SwiftUI

@safe
struct GhosttyTerminalViewIOS: View {
    let ghostty: GhosttyRuntime
    let inputRouter: TerminalInputRouter
    let shellState: ShellIndicatorState
    let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    let passwordStore: AgenTTYSSHPasswordStore
    let hostStore: AgenTTYHostStore
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let analyticsClient: AgenTTYAnalyticsClient
    let activeHost: AgenTTYHost?
    let hasNoHosts: Bool
    let terminalFontSize: Double
    let themeNonce: Int
    let systemKeyboardIsActive: Bool
    let shortcutExecutionContext: AgenTTYShortcutExecutionContext

    var body: some View {
        GeometryReader { geo in
            GhosttySurfaceRepresentableIOS(
                ghostty: ghostty,
                inputRouter: inputRouter,
                shellState: shellState,
                keyMaterialStore: keyMaterialStore,
                passwordStore: passwordStore,
                hostStore: hostStore,
                trustedHostKeyStore: trustedHostKeyStore,
                analyticsClient: analyticsClient,
                activeHost: activeHost,
                hasNoHosts: hasNoHosts,
                terminalFontSize: terminalFontSize,
                themeNonce: themeNonce,
                systemKeyboardIsActive: systemKeyboardIsActive,
                shortcutExecutionContext: shortcutExecutionContext,
                size: geo.size
            )
        }
    }
}

@safe
private struct GhosttySurfaceRepresentableIOS: UIViewRepresentable {
    final class Coordinator {
        var lastThemeNonce: Int?
    }

    let ghostty: GhosttyRuntime
    let inputRouter: TerminalInputRouter
    let shellState: ShellIndicatorState
    let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    let passwordStore: AgenTTYSSHPasswordStore
    let hostStore: AgenTTYHostStore
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let analyticsClient: AgenTTYAnalyticsClient
    let activeHost: AgenTTYHost?
    let hasNoHosts: Bool
    let terminalFontSize: Double
    let themeNonce: Int
    let systemKeyboardIsActive: Bool
    let shortcutExecutionContext: AgenTTYShortcutExecutionContext
    let size: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TerminalSurfaceViewIOS {
        let view = TerminalSurfaceViewIOS(
            ghostty: ghostty,
            keyMaterialStore: keyMaterialStore,
            passwordStore: passwordStore,
            hostStore: hostStore,
            trustedHostKeyStore: trustedHostKeyStore,
            analyticsClient: analyticsClient
        )
        view.attachInputRouter(inputRouter)
        view.attachShellState(shellState)
        view.updateHostAvailability(hasNoHosts)
        view.updateActiveHost(activeHost)
        view.updateSystemKeyboardActive(systemKeyboardIsActive)
        return view
    }

    func updateUIView(_ uiView: TerminalSurfaceViewIOS, context: Context) {
        let themeDidChange = if let previousThemeNonce = context.coordinator.lastThemeNonce {
            previousThemeNonce != themeNonce
        } else {
            false
        }
        context.coordinator.lastThemeNonce = themeNonce
        let targetBackgroundColor = ghostty.terminalBackgroundUIColor
        let boundsSize = uiView.bounds.size
        let hasUsableBounds = boundsSize.width > 0 && boundsSize.height > 0
        let effectiveSize = hasUsableBounds ? boundsSize : size

        if themeDidChange || EsmaDiagnostics.verboseLoggingEnabled {
            let sizeSource = hasUsableBounds ? "bounds" : "geometry"
            EsmaLog.ghostty.info(
                "updateUIView themeDidChange=\(themeDidChange) size_source=\(sizeSource, privacy: .public) geometry_pt=\(size.width, privacy: .public)x\(size.height, privacy: .public) bounds_pt=\(boundsSize.width, privacy: .public)x\(boundsSize.height, privacy: .public)"
            )
        }

        uiView.attachInputRouter(inputRouter)
        uiView.attachShellState(shellState)
        uiView.updateHostAvailability(hasNoHosts)
        uiView.updateActiveHost(activeHost)
        uiView.updateSystemKeyboardActive(systemKeyboardIsActive)
        if let request = shortcutExecutionContext.pendingForegroundCommand {
            uiView.handleShortcutShellCommand(request) { succeeded in
                shortcutExecutionContext.completeForegroundCommand(
                    id: request.id,
                    succeeded: succeeded
                )
            }
        }
        uiView.applyTerminalFontSize(terminalFontSize)
        if themeDidChange || uiView.backgroundColor?.isEqual(targetBackgroundColor) != true {
            uiView.backgroundColor = targetBackgroundColor
        }
        uiView.sizeDidChange(effectiveSize, reason: "swiftui-update")
        if themeDidChange {
            uiView.scheduleThemeResyncPasses(reason: "theme-deferred-resync")
            uiView.sendSyntheticTerminalFocusRefresh(reason: "theme-change")
        }
    }
}
