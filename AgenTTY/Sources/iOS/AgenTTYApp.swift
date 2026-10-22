import AppIntents
import Observation
import SwiftUI
import UserNotifications

enum APNsTokenStore {
    private static let key = "apns_device_token"
    static var pendingToken: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension Notification.Name {
    static let agenttyAPNsTokenDidChange = Notification.Name("agentty.apns-token-did-change")
}

struct InAppNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let subtitle: String?
    let traceContext: NotificationTraceContext

    var attemptID: String? { traceContext.attemptID }
    var source: String? { traceContext.source }
    var tmuxWindowId: Int? { traceContext.tmuxWindowID }
}

@MainActor
@Observable
final class AgenTTYAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate
{
    var inAppNotification: InAppNotification?
    var pendingNavigationWindowId: Int?
    @ObservationIgnored
    weak var shellState: ShellIndicatorState?
    @ObservationIgnored
    private var dismissTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentShownAt: ContinuousClock.Instant?
    @ObservationIgnored
    private var pendingQueue: [InAppNotification] = []

    private static func traceAppState(_ state: UIApplication.State) -> NotificationTraceAppState {
        switch state {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .unknown
        }
    }

    private static func tokenTail(_ value: String) -> String {
        String(value.suffix(8))
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !AgenTTYSSHSeedPolicy.isScreenshotMode {
            AgenTTYSentryService.configure()
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if !AgenTTYSSHSeedPolicy.isScreenshotMode {
            Task {
                let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                EsmaLog.notifications.notice("event=notification_authorization_result granted=\(granted ?? false)")
                application.registerForRemoteNotifications()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShellTitleGenerationFailed(_:)),
            name: .shellTitleGenerationFailed,
            object: nil
        )
        return true
    }

    @objc private func handleShellTitleGenerationFailed(_ notification: Notification) {
        let errorMessage = notification.userInfo?["error"] as? String ?? "unknown error"
        showInAppNotification(InAppNotification(
            title: "Shell title failed",
            body: errorMessage,
            subtitle: nil,
            traceContext: .empty
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let traceContext = NotificationTraceContext.parse(content: content)
        let activeWindowID = shellState?.activeWindowId
        let appState = Self.traceAppState(UIApplication.shared.applicationState)
        let isActiveWindow = traceContext.tmuxWindowID != nil && traceContext.tmuxWindowID == activeWindowID
        if isActiveWindow {
            NotificationTraceLogger.log(
                .pushForeground,
                context: traceContext,
                fields: .foreground(
                    activeWindowID: activeWindowID,
                    appState: appState,
                    decision: .suppressActiveWindow
                )
            )
            return []
        }

        let inApp = InAppNotification(
            title: content.title,
            body: content.body,
            subtitle: content.subtitle.isEmpty ? nil : content.subtitle,
            traceContext: traceContext
        )
        showInAppNotification(inApp)
        NotificationTraceLogger.log(
            .pushForeground,
            context: traceContext,
            fields: .foreground(
                activeWindowID: activeWindowID,
                appState: appState,
                decision: .showInAppBanner
            )
        )
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let traceContext = NotificationTraceContext.parse(content: response.notification.request.content)
        if let windowID = traceContext.tmuxWindowID {
            pendingNavigationWindowId = windowID
            NotificationTraceLogger.log(
                .pushResponse,
                context: traceContext,
                fields: .response(
                    action: NotificationTraceAction(response.actionIdentifier),
                    decision: .navigateWindow
                )
            )
            return
        }
        NotificationTraceLogger.log(
            .pushResponse,
            context: traceContext,
            fields: .response(
                action: NotificationTraceAction(response.actionIdentifier),
                decision: .noWindowNavigation
            )
        )
    }

    private let defaultDuration: Duration = .seconds(8)
    private let minimumDuration: Duration = .seconds(4)

    @MainActor
    func showInAppNotification(_ notification: InAppNotification) {
        if let shownAt = currentShownAt {
            let elapsed = ContinuousClock.now - shownAt
            if elapsed >= minimumDuration {
                presentNotification(notification)
            } else {
                NotificationTraceLogger.log(
                    .bannerQueued,
                    context: notification.traceContext,
                    fields: .banner(
                        activeWindowID: shellState?.activeWindowId,
                        reason: .minDisplayDuration
                    )
                )
                pendingQueue.append(notification)
                dismissTask?.cancel()
                let remaining = minimumDuration - elapsed
                let currentId = inAppNotification?.id
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(for: remaining)
                    if inAppNotification?.id == currentId {
                        showNext(dismissReason: .timeout)
                    }
                }
            }
        } else {
            presentNotification(notification)
        }
    }

    @MainActor
    private func presentNotification(_ notification: InAppNotification) {
        dismissTask?.cancel()
        if let current = inAppNotification {
            NotificationTraceLogger.log(
                .bannerDismissed,
                context: current.traceContext,
                fields: .banner(
                    activeWindowID: shellState?.activeWindowId,
                    reason: .replaced
                )
            )
        }
        inAppNotification = notification
        currentShownAt = .now
        NotificationTraceLogger.log(
            .bannerPresented,
            context: notification.traceContext,
            fields: .banner(
                activeWindowID: shellState?.activeWindowId,
                reason: nil
            )
        )
        let id = notification.id
        let duration = pendingQueue.isEmpty ? defaultDuration : minimumDuration
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            if inAppNotification?.id == id {
                showNext(dismissReason: .timeout)
            }
        }
    }

    @MainActor
    private func showNext(dismissReason: NotificationTraceReason) {
        if let current = inAppNotification {
            NotificationTraceLogger.log(
                .bannerDismissed,
                context: current.traceContext,
                fields: .banner(
                    activeWindowID: shellState?.activeWindowId,
                    reason: dismissReason
                )
            )
        }
        if let next = pendingQueue.first {
            pendingQueue.removeFirst()
            inAppNotification = nil
            currentShownAt = nil
            presentNotification(next)
        } else {
            inAppNotification = nil
            currentShownAt = nil
        }
    }

    @MainActor
    func dismissNotification(reason: NotificationTraceReason = .manual) {
        if let current = inAppNotification {
            NotificationTraceLogger.log(
                .bannerDismissed,
                context: current.traceContext,
                fields: .banner(
                    activeWindowID: shellState?.activeWindowId,
                    reason: reason
                )
            )
        }
        dismissTask?.cancel()
        pendingQueue.removeAll()
        inAppNotification = nil
        currentShownAt = nil
    }

    @MainActor
    func dismissCurrentNotificationIfMatchingWindow(_ windowId: Int) {
        guard inAppNotification?.tmuxWindowId == windowId else { return }
        dismissTask?.cancel()
        showNext(dismissReason: .activeWindowMatch)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map {
            let s = String($0, radix: 16)
            return s.count < 2 ? "0" + s : s
        }.joined()
        EsmaLog.notifications.notice(
            "event=apns_token_received token_tail=\(Self.tokenTail(hex), privacy: .public) token_length=\(hex.count)"
        )
        APNsTokenStore.pendingToken = hex
        NotificationCenter.default.post(name: .agenttyAPNsTokenDidChange, object: nil)
        Task {
            do {
                _ = try await AgenTTYNotifyRelayClient.shared.registerPendingDeviceIfPossible()
            } catch {
                EsmaLog.notifications.error(
                    "event=relay_register_failure error=\(String(describing: error), privacy: .public)"
                )
                AgenTTYSentryService.capture(error: error, context: "relay_register_failure")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        EsmaLog.notifications.error(
            "event=apns_token_registration_failure error=\(String(describing: error), privacy: .public)"
        )
        AgenTTYSentryService.capture(error: error, context: "apns_token_registration_failure")
    }
}

enum TerminalLayout {
    static let topSafeAreaTrim: CGFloat = 7
    static let horizontalInset: CGFloat = 3
    static let overlayTrailingInset: CGFloat = 10
    static let overlayTopInset: CGFloat = 6
    static let statusBarBlackoutLift: CGFloat = 4
    static let topChromeHorizontalInset: CGFloat = 14
    static let topChromeTopPadding: CGFloat = 3.0

    static func contentTopInset(safeAreaTop: CGFloat) -> CGFloat {
        // Minimum ensures notch devices (shorter safe area) still get enough
        // black padding below the status chrome to match Dynamic Island devices.
        max(52, safeAreaTop - topSafeAreaTrim)
    }

    static func statusBarBlackoutHeight(safeAreaTop: CGFloat) -> CGFloat {
        max(0, contentTopInset(safeAreaTop: safeAreaTop) - statusBarBlackoutLift)
    }
}

@main
@safe
struct AgenTTYiOSApp: App {
    @UIApplicationDelegateAdaptor(AgenTTYAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TerminalFontSizeSetting.storageKey, store: AgenTTYSharedDefaults.store)
    private var terminalFontSize: Double = TerminalFontSizeSetting.defaultValue
    @AppStorage(KeyboardEncodingMode.storageKey, store: AgenTTYSharedDefaults.store)
    private var keyboardEncodingModeRawValue: String = KeyboardEncodingMode.defaultValue.rawValue
    @AppStorage(KeyboardInputMode.storageKey, store: AgenTTYSharedDefaults.store)
    private var keyboardInputModeRawValue: String = KeyboardInputMode.defaultValue.rawValue
    private let ghostty = GhosttyRuntime()
    private let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    private let passwordStore: AgenTTYSSHPasswordStore
    private let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    private let analyticsClient: AgenTTYAnalyticsClient
    private let shortcutExecutionContext: AgenTTYShortcutExecutionContext
    @State private var inputRouter = TerminalInputRouter()
    @State private var shellState = ShellIndicatorState()
    @State private var keyboardState = KeyboardState()
    @State private var hostStore: AgenTTYHostStore
    @State private var sshKeyStore: AgenTTYSSHKeyStore
    @State private var hostReachabilityMonitor = AgenTTYHostReachabilityMonitor()
    @State private var sheetPresentation: SheetPresentation
    @State private var didPrepareScreenshotScreen = false
    @State private var themeToken = AppThemeToken()
    @State private var pendingThemeDismissRefresh = false
    @State private var lifetimeAccessController: AgenTTYLifetimeAccessController

    init() {
        AgenTTYDictation.migrateModelSelectionIfNeeded()

        if AgenTTYSSHSeedPolicy.isScreenshotMode {
            AgenTTYScreenshotReadySignal.reset()
            AgenTTYSharedDefaults.store.set(
                AgenTTYThemeSelection.defaultThemeName,
                forKey: AgenTTYThemeSelection.storageKey
            )
            if ProcessInfo.processInfo.arguments.contains("-ASC_DISABLE_ANIMATIONS") {
                UIView.setAnimationsEnabled(false)
            }
        }

        let flavor = AgenTTYBuildFlavor.current()
        let materialStore = AgenTTYSSHKeyMaterialStore(flavor: flavor)
        let passwordStore = AgenTTYSSHPasswordStore(flavor: flavor)
        let trustedHostKeyStore = AgenTTYTrustedHostKeyStore(
            userDefaults: AgenTTYSharedDefaults.store,
            flavor: flavor
        )
        let analyticsClient = AgenTTYAnalyticsClient(flavor: flavor)
        let hostStore = AgenTTYHostStore(flavor: flavor)
        let lifetimeAccessController = AgenTTYLifetimeAccessController(
            flavor: flavor,
            analyticsClient: analyticsClient
        )

        keyMaterialStore = materialStore
        self.passwordStore = passwordStore
        self.trustedHostKeyStore = trustedHostKeyStore
        self.analyticsClient = analyticsClient
        _sshKeyStore = State(initialValue: AgenTTYSSHKeyStore(flavor: flavor, materialStore: materialStore))
        _hostStore = State(initialValue: hostStore)
        _sheetPresentation = State(initialValue: SheetPresentation())
        _lifetimeAccessController = State(initialValue: lifetimeAccessController)

        let shortcutExecutionContext = AgenTTYShortcutExecutionContext(
            hostStore: hostStore,
            keyMaterialStore: materialStore,
            passwordStore: passwordStore,
            trustedHostKeyStore: trustedHostKeyStore,
            lifetimeAccessController: lifetimeAccessController
        )
        self.shortcutExecutionContext = shortcutExecutionContext
        unsafe AppDependencyManager.shared.add(dependency: shortcutExecutionContext)
    }

    var body: some Scene {
        let themeNonce = themeToken.nonce

        WindowGroup {
            AgenTTYMainWindowView(
                appDelegate: appDelegate,
                ghostty: ghostty,
                keyMaterialStore: keyMaterialStore,
                passwordStore: passwordStore,
                trustedHostKeyStore: trustedHostKeyStore,
                inputRouter: inputRouter,
                shellState: shellState,
                keyboardState: keyboardState,
                hostStore: hostStore,
                sheetPresentation: sheetPresentation,
                themeToken: themeToken,
                themeNonce: themeNonce,
                terminalFontSize: terminalFontSize,
                keyboardInputMode: keyboardInputMode,
                lifetimeAccessController: lifetimeAccessController,
                analyticsClient: analyticsClient,
                shortcutExecutionContext: shortcutExecutionContext
            )
            .onAppear {
                appDelegate.shellState = shellState
                inputRouter.keyboardEncodingMode = keyboardEncodingMode
                lifetimeAccessController.setSceneActive(scenePhase == .active)
                hostReachabilityMonitor.updateHosts(hostStore.hosts)
                hostReachabilityMonitor.setSceneActive(scenePhase == .active)
                Task {
                    await analyticsClient.setSceneActive(
                        scenePhase == .active,
                        accessState: lifetimeAccessController.analyticsAccessState,
                        savedHostCount: hostStore.hosts.count,
                        activeHostPresent: hostStore.activeHost != nil
                    )
                }
            }
            .task {
                await AgenTTYDictationLibrary.shared.resumePublication()
                await prepareScreenshotScreenIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                lifetimeAccessController.setSceneActive(newPhase == .active)
                hostReachabilityMonitor.setSceneActive(newPhase == .active)
                Task {
                    await analyticsClient.setSceneActive(
                        newPhase == .active,
                        accessState: lifetimeAccessController.analyticsAccessState,
                        savedHostCount: hostStore.hosts.count,
                        activeHostPresent: hostStore.activeHost != nil
                    )
                }
                guard newPhase == .active else { return }
                Task {
                    await AgenTTYDictationLibrary.shared.resumePublication()
                    await lifetimeAccessController.refreshForForeground()
                }
            }
            .onChange(of: hostStore.hosts) { _, newHosts in
                hostReachabilityMonitor.updateHosts(newHosts)
            }
            .onChange(of: keyboardEncodingModeRawValue) { _, _ in
                inputRouter.keyboardEncodingMode = keyboardEncodingMode
            }
            .onChange(of: keyboardInputModeRawValue) { _, _ in
                // Switching to the system keyboard unmounts `InAppKeyboardView`,
                // whose `onDisappear` would otherwise read as an accidental
                // home-indicator swipe and send a stray backspace.
                keyboardState.suppressLifecycleUndo()
            }
            .onChange(of: appDelegate.pendingNavigationWindowId) { _, windowId in
                if let windowId {
                    shellState.navigateAndClearUnread(windowId)
                    appDelegate.pendingNavigationWindowId = nil
                }
            }
            .onChange(of: shellState.activeWindowId) { _, activeWindowId in
                if let activeWindowId {
                    appDelegate.dismissCurrentNotificationIfMatchingWindow(activeWindowId)
                }
            }
            .onChange(of: appDelegate.inAppNotification) { _, notification in
                if let windowId = notification?.tmuxWindowId {
                    if shellState.activeWindowId == windowId {
                        appDelegate.dismissCurrentNotificationIfMatchingWindow(windowId)
                    } else {
                        shellState.markUnread(windowId)
                    }
                }
            }
            .alert(
                "Dictation Error",
                isPresented: Binding(
                    get: { inputRouter.dictationError != nil },
                    set: { if !$0 { inputRouter.dictationError = nil } }
                )
            ) {
                Button("OK") { inputRouter.dictationError = nil }
            } message: {
                if let error = inputRouter.dictationError {
                    Text(error)
                }
            }
            .sheet(
                isPresented: $sheetPresentation.showSettings,
                onDismiss: { TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface() }
            ) {
                TerminalSettingsSheet()
                    .presentationDetents([.medium, .large])
                    .esmaTermSheetBackground()
            }
            .sheet(
                isPresented: $sheetPresentation.showTips,
                onDismiss: { TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface() }
            ) {
                TerminalTipsSheet()
                    .presentationDetents([.medium, .large])
                    .esmaTermSheetBackground()
            }
            .sheet(
                isPresented: $sheetPresentation.showHosts,
                onDismiss: {
                    sheetPresentation.pendingHostEditorID = nil
                    TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface()
                }
            ) {
                TerminalHostsSheet(
                    trustedHostKeyStore: trustedHostKeyStore,
                    passwordStore: passwordStore,
                    analyticsClient: analyticsClient,
                    initialHostEditorID: sheetPresentation.pendingHostEditorID
                )
                    .environment(inputRouter)
                    .environment(hostStore)
                    .environment(sshKeyStore)
                    .environment(hostReachabilityMonitor)
                    .esmaTermSheetBackground()
            }
            .sheet(
                isPresented: $sheetPresentation.showSSHKeys,
                onDismiss: { TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface() }
            ) {
                TerminalSSHKeysSheet(analyticsClient: analyticsClient)
                    .environment(sshKeyStore)
                    .environment(hostStore)
                    .esmaTermSheetBackground()
            }
            .sheet(
                isPresented: $sheetPresentation.showThemes,
                onDismiss: {
                    handleThemesSheetDismissed()
                    TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface()
                }
            ) {
                TerminalThemesSheet { newThemeName in
                    let didApply = ghostty.applyTheme(named: newThemeName)
                    if didApply {
                        keyboardState.invalidateVisualsForThemeChange()
                        pendingThemeDismissRefresh = true
                        themeToken.invalidate()
                    }
                    return didApply
                }
                    .environment(themeToken)
                    .presentationDetents([.medium, .large])
                    .esmaTermSheetBackground()
            }
            .preferredColorScheme(AppTheme.preferredColorScheme)
            .statusBar(hidden: true)
        }
    }

    private var keyboardEncodingMode: KeyboardEncodingMode {
        if let mode = KeyboardEncodingMode(rawValue: keyboardEncodingModeRawValue) {
            return mode
        }
        return .defaultValue
    }

    private var keyboardInputMode: KeyboardInputMode {
        if let mode = KeyboardInputMode(rawValue: keyboardInputModeRawValue) {
            return mode
        }
        return .defaultValue
    }

    private func prepareScreenshotScreenIfNeeded() async {
        guard !didPrepareScreenshotScreen,
              let screenshotScreen = AgenTTYScreenshotScreen.current else { return }
        didPrepareScreenshotScreen = true

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        switch screenshotScreen {
        case .themes:
            sheetPresentation.showThemes = true
        case .hosts:
            sheetPresentation.showHosts = true
        case .keys:
            sheetPresentation.showSSHKeys = true
        case .terminal, .switchHosts:
            return
        }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        AgenTTYScreenshotReadySignal.markReady(screenshotScreen)
    }

    private func handleThemesSheetDismissed() {
        guard pendingThemeDismissRefresh else { return }
        pendingThemeDismissRefresh = false

        Task { @MainActor in
            await Task.yield()
            keyboardState.invalidateVisualsForThemeChange()
        }
    }
}

@safe
private struct AgenTTYMainWindowView: View {
    let appDelegate: AgenTTYAppDelegate
    let ghostty: GhosttyRuntime
    let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    let passwordStore: AgenTTYSSHPasswordStore
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let inputRouter: TerminalInputRouter
    let shellState: ShellIndicatorState
    let keyboardState: KeyboardState
    let hostStore: AgenTTYHostStore
    let sheetPresentation: SheetPresentation
    let themeToken: AppThemeToken
    let themeNonce: Int
    let terminalFontSize: Double
    let keyboardInputMode: KeyboardInputMode
    let lifetimeAccessController: AgenTTYLifetimeAccessController
    let analyticsClient: AgenTTYAnalyticsClient
    let shortcutExecutionContext: AgenTTYShortcutExecutionContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Approximates the system keyboard's slide curve so hiding/showing the
    /// custom key grid feels like the native keyboard instead of snapping.
    private static let keyboardSurfaceAnimation = Animation.spring(duration: 0.45, bounce: 0)

    private var connectionRecoveryTitle: String {
        guard let request = inputRouter.connectionRecoveryRequest else {
            return "Connection Needs Attention"
        }
        return AgenTTYSSHRecoveryGuidance.guidance(for: request.outcome).title
    }

    var body: some View {
        GeometryReader { geo in
            let contentTopInset = TerminalLayout.contentTopInset(
                safeAreaTop: geo.safeAreaInsets.top
            )
            let statusBarBlackoutHeight = TerminalLayout.statusBarBlackoutHeight(
                safeAreaTop: geo.safeAreaInsets.top
            )
            let keyboardSurfaceMode = KeyboardPresentationPolicy.resolve(
                idiom: UIDevice.current.userInterfaceIdiom,
                sceneSize: geo.size,
                inputMode: keyboardInputMode,
                isHiddenByUser: keyboardState.isKeyboardHidden
            )

            ZStack {
                terminalLayer(systemKeyboardIsActive: keyboardSurfaceMode == .systemKeyboard)
                if masksTerminalForScreenshotSheet {
                    Color(red: 0.035, green: 0.03, blue: 0.08)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .environment(inputRouter)
            .environment(shellState)
            .environment(hostStore)
            .environment(lifetimeAccessController)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Group {
                    switch keyboardSurfaceMode {
                    case .customGrid:
                        keyboardInset(bottomSafeAreaInset: geo.safeAreaInsets.bottom)
                            .zIndex(VisualLayering.AppShell.keyboardSurfaceTransition)
                            .transition(.move(edge: .bottom))
                    case .systemKeyboard, .hidden:
                        hiddenKeyboardShelf
                    }
                }
                // The animated scope must contain the switch above for the
                // .move transition to fire (a transition only plays inside an
                // animated transaction), but must stop here: the outer
                // transaction — the inset height and the terminal growing into
                // the freed space — stays un-animated so the Metal surface
                // snaps to final size in one Ghostty/PTY resize instead of
                // relayouting every animation frame, which visibly drops
                // frames.
                .animation(
                    reduceMotion ? nil : Self.keyboardSurfaceAnimation,
                    value: keyboardSurfaceMode
                )
                .overlay(alignment: .topTrailing) {
                    if keyboardToggleIsVisible(for: keyboardSurfaceMode) {
                        keyboardToggleButton(showsKeyboard: keyboardSurfaceMode == .hidden)
                            .padding(.bottom, 10)
                            .padding(.trailing, 14)
                            // Zero-height anchor pinned to the inset's top edge:
                            // the button lays out fully above it, floating over
                            // the terminal without growing the inset.
                            .frame(height: 0, alignment: .bottom)
                            // Scoped to the button only: its anchor jumps with
                            // the snapping inset, so glide it along the same
                            // curve the sliding key grid uses.
                            .animation(
                                reduceMotion ? nil : Self.keyboardSurfaceAnimation,
                                value: keyboardSurfaceMode
                            )
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                notificationOverlay
                    .padding(.trailing, TerminalLayout.overlayTrailingInset + 4)
                    .padding(.top, TerminalLayout.overlayTopInset)
                    .zIndex(VisualLayering.AppShell.inAppNotificationBanner)
            }
            .animation(.spring(duration: 0.35), value: appDelegate.inAppNotification)
            .padding(.top, contentTopInset)
            .ignoresSafeArea(.container, edges: ignoredContainerSafeAreaEdges)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: statusBarBlackoutHeight)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(VisualLayering.AppShell.statusBarBlackout)
            }
            .overlay(alignment: .top) {
                topChromeOverlay(statusBarBlackoutHeight: statusBarBlackoutHeight)
            }
            .overlay(alignment: .topTrailing) {
                if AgenTTYScreenshotScreen.current == .switchHosts {
                    AgenTTYScreenshotHostSwitcher(hostStore: hostStore)
                        .padding(.top, statusBarBlackoutHeight + 8)
                        .padding(.trailing, 14)
                        .zIndex(VisualLayering.AppShell.inAppNotificationBanner)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Without the key grid there is no in-key recording indicator,
                // so the floating badge is the only dictation state left.
                if keyboardSurfaceMode != .customGrid {
                    dictationStatusOverlay
                        .padding(.leading, 14)
                        .padding(.bottom, 14)
                        .zIndex(VisualLayering.AppShell.dictationStatusOverlay)
                }
            }
            .overlay {
                accessGateOverlay
            }
            .background {
                // Explicitly covers the keyboard safe-area region too, so the
                // system keyboard sits on the terminal theme background instead
                // of window black.
                Color(uiColor: ghostty.terminalBackgroundUIColor)
                    .ignoresSafeArea()
            }
            .onChange(of: keyboardSurfaceMode) { _, surfaceMode in
                if surfaceMode != .customGrid {
                    TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface()
                }
            }
            .alert(
                connectionRecoveryTitle,
                isPresented: Binding(
                    get: { inputRouter.connectionRecoveryRequest != nil },
                    set: { if !$0 { inputRouter.dismissConnectionRecovery() } }
                )
            ) {
                Button("Retry") {
                    inputRouter.retryConnectionRecovery()
                }
                Button("Edit Host") {
                    if let request = inputRouter.connectionRecoveryRequest,
                       let host = hostStore.hosts.first(where: { $0.id == request.hostID }) {
                        sheetPresentation.presentHosts(hostEditorID: host.id)
                    }
                    inputRouter.dismissConnectionRecovery()
                }
                Button("Dismiss", role: .cancel) {
                    inputRouter.dismissConnectionRecovery()
                }
            } message: {
                if let request = inputRouter.connectionRecoveryRequest {
                    Text(AgenTTYSSHRecoveryGuidance.guidance(for: request.outcome).message)
                }
            }
        }
    }

    private var ignoredContainerSafeAreaEdges: Edge.Set {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return [.top, .horizontal, .bottom]
        }
        return [.top, .horizontal]
    }

    private var masksTerminalForScreenshotSheet: Bool {
        switch AgenTTYScreenshotScreen.current {
        case .themes, .hosts, .keys:
            true
        case .terminal, .switchHosts, nil:
            false
        }
    }

    @ViewBuilder
    private func terminalLayer(systemKeyboardIsActive: Bool) -> some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            GhosttyTerminalViewIOS(
                ghostty: ghostty,
                inputRouter: inputRouter,
                shellState: shellState,
                keyMaterialStore: keyMaterialStore,
                passwordStore: passwordStore,
                hostStore: hostStore,
                trustedHostKeyStore: trustedHostKeyStore,
                analyticsClient: analyticsClient,
                activeHost: hostStore.activeHost,
                hasNoHosts: hostStore.hosts.isEmpty,
                terminalFontSize: terminalFontSize,
                themeNonce: themeToken.nonce,
                systemKeyboardIsActive: systemKeyboardIsActive,
                shortcutExecutionContext: shortcutExecutionContext
            )
            .padding(.horizontal, TerminalLayout.horizontalInset)
            .zIndex(VisualLayering.AppShell.terminalContent)
        } else {
            Color(uiColor: ghostty.terminalBackgroundUIColor)
                .ignoresSafeArea()
                .zIndex(VisualLayering.AppShell.terminalContent)
        }
    }

    @ViewBuilder
    private func keyboardInset(bottomSafeAreaInset: CGFloat) -> some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            InAppKeyboardView(keyboardState: keyboardState, bottomSafeAreaInset: bottomSafeAreaInset)
                .environment(inputRouter)
                .environment(shellState)
                .environment(hostStore)
                .environment(sheetPresentation)
                .environment(themeToken)
                .zIndex(VisualLayering.AppShell.keyboardInset)
        }
    }

    /// Slim strip that keeps the shell dots and dir/branch chips on screen when
    /// the key grid is not mounted. `safeAreaInset` content sits outside the
    /// environment applied to the terminal stack, so it re-injects `shellState`
    /// exactly like `keyboardInset` does.
    @ViewBuilder
    private var hiddenKeyboardShelf: some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            KeyboardHiddenShelfView()
                .environment(shellState)
                .id(themeNonce)
                .zIndex(VisualLayering.AppShell.keyboardInset)
        }
    }

    private func keyboardToggleIsVisible(for surfaceMode: KeyboardSurfaceMode) -> Bool {
        guard lifetimeAccessController.shouldRenderInteractiveContent else { return false }
        switch surfaceMode {
        case .customGrid, .systemKeyboard:
            return true
        case .hidden:
            // iPad landscape hides automatically; only a user-hidden keyboard
            // offers a restore affordance.
            return keyboardState.isKeyboardHidden
        }
    }

    /// One floating glass control both hides and restores the keyboard, built
    /// on the same `ChromeGlassIconLabel` base as the top menu button so the
    /// chrome controls stay visually unified.
    private func keyboardToggleButton(showsKeyboard: Bool) -> some View {
        Button {
            if showsKeyboard {
                keyboardState.showKeyboard()
            } else {
                keyboardState.hideKeyboard()
            }
        } label: {
            ChromeGlassIconLabel(systemImage: showsKeyboard ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.glassProminent)
        .tint(AppTheme.controlGlassTint)
        .accessibilityLabel(showsKeyboard ? "Show keyboard" : "Hide keyboard")
    }

    @ViewBuilder
    private var notificationOverlay: some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            VStack(alignment: .trailing, spacing: 12) {
                if let notification = appDelegate.inAppNotification {
                    InAppNotificationBanner(
                        notification: notification,
                        onDismiss: { appDelegate.dismissNotification() },
                        onNavigate: notification.tmuxWindowId.map { windowId in
                            {
                                shellState.navigateAndClearUnread(windowId)
                                appDelegate.dismissNotification(reason: .navigate)
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private var dictationStatusOverlay: some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            Group {
                if inputRouter.isDictationCaptureActive {
                    // Theme-independent strong red so the recording state is
                    // unmistakable regardless of which Ghostty theme is active.
                    dictationStatusBadge(
                        systemImage: "mic.fill",
                        label: "rec",
                        pulses: true,
                        glass: .regular.tint(Color(red: 0.85, green: 0.12, blue: 0.12).opacity(0.92)),
                        foreground: .white,
                        showsAppOrnamentStroke: false
                    )
                } else if inputRouter.isDictationProcessing {
                    dictationStatusBadge(
                        systemImage: "waveform",
                        label: "transcribing",
                        pulses: false,
                        glass: AppTheme.glass(.regular),
                        foreground: AppTheme.darkModePrimaryText.opacity(0.9),
                        showsAppOrnamentStroke: true
                    )
                }
            }
            .animation(.snappy(duration: 0.18), value: inputRouter.isDictationCaptureActive)
            .animation(.snappy(duration: 0.18), value: inputRouter.isDictationProcessing)
        }
    }

    private func dictationStatusBadge(
        systemImage: String,
        label: String,
        pulses: Bool,
        glass: Glass,
        foreground: Color,
        showsAppOrnamentStroke: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: pulses)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .fixedSize()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(glass, in: .capsule)
        .overlay {
            if showsAppOrnamentStroke {
                Capsule().stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 0.5)
            }
        }
        .accessibilityLabel(pulses ? "Dictation recording" : "Transcribing")
    }

    @ViewBuilder
    private func topChromeOverlay(statusBarBlackoutHeight: CGFloat) -> some View {
        if lifetimeAccessController.shouldRenderInteractiveContent {
            TopStatusChromeView(
                onSelectHost: { hostID in
                    hostStore.selectHost(id: hostID)
                },
                onSelectAdjacentHost: { direction in
                    switch direction {
                    case .previous:
                        hostStore.selectAdjacentHost(direction: .previous)
                    case .next:
                        hostStore.selectAdjacentHost(direction: .next)
                    }
                }
            )
            .environment(inputRouter)
            .environment(hostStore)
            .environment(sheetPresentation)
            .environment(keyboardState)
            .frame(height: statusBarBlackoutHeight, alignment: .center)
            .padding(.top, TerminalLayout.topChromeTopPadding)
            .padding(.horizontal, TerminalLayout.topChromeHorizontalInset)
            .ignoresSafeArea(.container, edges: .top)
            .id(themeNonce)
            .zIndex(VisualLayering.AppShell.topStatusChrome)
        }
    }

    @ViewBuilder
    private var accessGateOverlay: some View {
        if lifetimeAccessController.shouldBlockWithGate {
            AgenTTYAccessGateView(analyticsClient: analyticsClient)
                .environment(lifetimeAccessController)
                .zIndex(VisualLayering.AppShell.accessGate)
        }
    }
}

@safe
private struct AgenTTYScreenshotHostSwitcher: View {
    let hostStore: AgenTTYHostStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(hostStore.hosts) { host in
                hostRow(host)
            }

            Divider()

            Label("Manage Hosts…", systemImage: "list.bullet")
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 44)
        }
        .frame(width: UIDevice.current.userInterfaceIdiom == .pad ? 260 : 220)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.38), radius: 22, y: 12)
        .accessibilityIdentifier("agentty-screenshot-host-switcher")
    }

    private func hostRow(_ host: AgenTTYHost) -> some View {
        let isActive = host.id == hostStore.activeHostID
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .opacity(isActive ? 1 : 0)
                .frame(width: 16)
            Text(host.label)
                .font(.system(size: 16, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

#if DEBUG
#Preview("Main App (Welcome)") {
    let flavor = AgenTTYBuildFlavor.dev
    let materialStore = AgenTTYSSHKeyMaterialStore(flavor: flavor)
    let passwordStore = AgenTTYSSHPasswordStore(flavor: flavor)
    let trustedHostKeyStore = AgenTTYTrustedHostKeyStore(
        userDefaults: .standard,
        flavor: flavor
    )
    let hostStore = AgenTTYHostStore(userDefaults: .standard, flavor: flavor)
    let lifetimeAccessController = AgenTTYLifetimeAccessController(flavor: flavor)
    let analyticsClient = AgenTTYAnalyticsClient(flavor: flavor)
    let shortcutExecutionContext = AgenTTYShortcutExecutionContext(
        hostStore: hostStore,
        keyMaterialStore: materialStore,
        passwordStore: passwordStore,
        trustedHostKeyStore: trustedHostKeyStore,
        lifetimeAccessController: lifetimeAccessController
    )
    let shellState = ShellIndicatorState()
    let _ = shellState.update(windowCount: 1, activePosition: 0, windowIds: [1])
    let _ = shellState.updateWindowContext(
        windowID: 1,
        workingDirectoryPath: "/home/developer/projects/my-app",
        branchName: "main"
    )

    AgenTTYMainWindowView(
        appDelegate: AgenTTYAppDelegate(),
        ghostty: GhosttyRuntime(),
        keyMaterialStore: materialStore,
        passwordStore: passwordStore,
        trustedHostKeyStore: trustedHostKeyStore,
        inputRouter: TerminalInputRouter(),
        shellState: shellState,
        keyboardState: KeyboardState(),
        hostStore: hostStore,
        sheetPresentation: SheetPresentation(),
        themeToken: AppThemeToken(),
        themeNonce: 0,
        terminalFontSize: TerminalFontSizeSetting.defaultValue,
        keyboardInputMode: .defaultValue,
        lifetimeAccessController: lifetimeAccessController,
        analyticsClient: analyticsClient,
        shortcutExecutionContext: shortcutExecutionContext
    )
    .statusBar(hidden: true)
    .preferredColorScheme(.dark)
}
#endif
