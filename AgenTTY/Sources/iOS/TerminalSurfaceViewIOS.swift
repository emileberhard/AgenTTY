import GameController
import UIKit
import GhosttyKit

@safe
@MainActor
final class TerminalSurfaceViewIOS: UIView, GhosttySurfaceProvider, TerminalInputSink, TerminalSurfaceLifecycleHost, TerminalTouchScrollHost, TerminalTouchSelectionHost, TerminalShellSwipeHost {
    private let ghostty: GhosttyRuntime
    private let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    private let passwordStore: AgenTTYSSHPasswordStore
    private let hostStore: AgenTTYHostStore
    private let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    private let analyticsClient: AgenTTYAnalyticsClient
    private let maxTmuxShellCount = 10
    private let swipeDirectionThreshold: CGFloat = 10
    private let swipeCommitProgressThreshold: CGFloat = 0.3
    private let swipeCommitVelocityThreshold: CGFloat = 500
    private let swipeDataTimeout: TimeInterval = 0.6
    private var bridge: TerminalBridge?
    private var didLogIOSurfaceLayerCount = false
    private var didLogCustomKeyboardPath = false
    private var quantizationLogCount = 0
    private var lastLoggedQuantizationSignature: QuantizationSignature?
    private var deferredSurfaceResyncWorkItem: DispatchWorkItem?
    private var themeResyncGeneration: UInt = 0
    private var geometryVerifyResyncGeneration: UInt = 0
    private var lastAppliedSurfaceGeometry: SurfaceGeometry?
    private var lastSyncedTerminalWindowSignature: TerminalWindowSyncSignature?
    private var appliedTerminalFontSize = TerminalFontSizeSetting.persistedValue()
    private var hasAppliedTerminalFontSizeAtLeastOnce = false
    private var isDirectionalPadCursorStyleActive = false
    private weak var shellState: ShellIndicatorState?
    private weak var hardwareInputRouter: TerminalInputRouter?
    private let hardwareKeyRepeatEngine = KeyboardRepeatEngine()
    private var hardwareRepeatActiveKeyCode: UIKeyboardHIDUsage?
    private var lastHandledShortcutCommandID: UUID?

    /// Caps Lock on iPad Magic Keyboard is bound to dictation: a quick tap
    /// toggles dictation on/off; holding past `capsLockHoldThreshold` enters
    /// push-to-talk and releases stop+transcribe. Tracked separately from the
    /// generic hardware-key path so we can disambiguate tap vs hold.
    private static let capsLockHoldThreshold: TimeInterval = 0.2
    private var capsLockHoldTimer: Timer?
    private var capsLockIsPressed = false
    private var capsLockEnteredPushToTalk = false

    /// True only while `KeyboardSurfaceMode` is `.systemKeyboard`, i.e. the user
    /// picked the system keyboard *and* nothing else is suppressing it. Drives
    /// both the first-responder gate and the `inputView` suppression below.
    private var systemKeyboardIsActive = false

    /// Weak registry of the most recently window-attached surface so the
    /// keyboard-surface-mode flip in `AgenTTYMainWindowView` and sheet
    /// dismissals can re-claim first responder without holding a strong ref.
    private static weak var lastAttachedSurface: TerminalSurfaceViewIOS?

    /// Asks the most recently attached surface to claim first responder. Safe
    /// to call from anywhere on the main actor; no-ops when the surface does not
    /// need keyboard focus or is not attached to a window.
    static func claimFirstResponderForActiveSurface() {
        lastAttachedSurface?.claimFirstResponder()
    }

    private func claimFirstResponder() {
        guard window != nil else { return }
        guard shouldOwnKeyboardFocus else { return }
        guard !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    /// iPad always owns keyboard focus (Magic Keyboard path). iPhone claims it
    /// only when it actually needs it: the user picked the system keyboard, or a
    /// physical keyboard is attached. Without this gate the default iPhone
    /// experience would gain a `UIKeyInput` first responder it never uses.
    private var shouldOwnKeyboardFocus: Bool {
        if traitCollection.userInterfaceIdiom == .pad { return true }
        if systemKeyboardIsActive { return true }
        return GCKeyboard.coalesced != nil
    }

    /// Zero-size input view that keeps the software keyboard down while the
    /// surface still holds first responder for hardware keys.
    private lazy var suppressedSoftwareInputView: UIView = {
        let view = UIView(frame: .zero)
        view.autoresizingMask = .flexibleWidth
        return view
    }()

    override var inputView: UIView? {
        systemKeyboardIsActive ? nil : suppressedSoftwareInputView
    }

    func updateSystemKeyboardActive(_ isActive: Bool) {
        guard systemKeyboardIsActive != isActive else { return }
        systemKeyboardIsActive = isActive
        refreshKeyboardFocus()
    }

    private func refreshKeyboardFocus() {
        guard window != nil else { return }
        if shouldOwnKeyboardFocus {
            if isFirstResponder {
                reloadInputViews()
            } else {
                _ = becomeFirstResponder()
            }
            return
        }
        if isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    @objc private func handleHardwareKeyboardAvailabilityChanged() {
        refreshKeyboardFocus()
    }

    private lazy var touchScrollController = TerminalTouchScrollController(host: self)
    private lazy var touchSelectionController = TerminalTouchSelectionController(host: self)
    private lazy var shellSwipeController = TerminalShellSwipeController(host: self)
    private lazy var lifecycleController = TerminalSurfaceLifecycleController(host: self) { [weak self] in
        self?.touchScrollController.cancelMomentum()
        self?.touchSelectionController.cancelInteraction()
    }

    private(set) var ghosttySurface: ghostty_surface_t?

    var isSurfaceAttachedToWindow: Bool {
        window != nil
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    var screenScale: CGFloat {
        window?.windowScene?.screen.scale ?? activeWindowScene?.screen.scale ?? traitCollection.displayScale
    }

    var surfaceBounds: CGRect {
        bounds
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        // Cmd+V flows into the same async clipboard resolver as touch-paste
        // (images → files → text precedence). The existing `paste(_:)` override
        // already delegates to `pasteClipboardContent()`, so we just bind the
        // chord to that selector here.
        [UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))]
    }

    // NOTE: Do NOT override layerClass to CAMetalLayer — this Ghostty build
    // adds its own IOSurfaceLayer as a sublayer via addSublayer:. Keep default CALayer.

    /// Called by GhosttyKit's Metal renderer to add its IOSurfaceLayer sublayer.
    @objc(addSublayer:)
    func addSublayer(_ sublayer: CALayer) {
        layer.addSublayer(sublayer)
        sublayer.frame = layer.bounds
        if EsmaDiagnostics.verboseLoggingEnabled {
            EsmaLog.ghostty.info(
                "iosurface addSublayer type=\(String(describing: type(of: sublayer)), privacy: .public) layer_bounds_pt=\(self.layer.bounds.width, privacy: .public)x\(self.layer.bounds.height, privacy: .public) sublayer_frame_pt=\(sublayer.frame.width, privacy: .public)x\(sublayer.frame.height, privacy: .public)"
            )
        }
        scheduleDeferredSurfaceResync(reason: "iosurface-added")
    }

    init(
        ghostty: GhosttyRuntime,
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        passwordStore: AgenTTYSSHPasswordStore,
        hostStore: AgenTTYHostStore,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        analyticsClient: AgenTTYAnalyticsClient
    ) {
        self.ghostty = ghostty
        self.keyMaterialStore = keyMaterialStore
        self.passwordStore = passwordStore
        self.hostStore = hostStore
        self.trustedHostKeyStore = trustedHostKeyStore
        self.analyticsClient = analyticsClient
        super.init(frame: .zero)

        backgroundColor = ghostty.terminalBackgroundUIColor
        isMultipleTouchEnabled = true

        guard let surface = unsafe ghostty.makeSurface(for: self) else {
            fatalError("failed to create ghostty surface")
        }

        unsafe ghosttySurface = surface
        bridge = unsafe TerminalBridge(
            runtime: ghostty,
            surface: surface,
            keyMaterialStore: keyMaterialStore,
            passwordStore: passwordStore,
            hostStore: hostStore,
            trustedHostKeyStore: trustedHostKeyStore,
            analyticsClient: analyticsClient
        )
        bridge?.terminalDataDidUpdate = { [weak self] in
            self?.handleTerminalDataDidUpdate()
        }

        // Keep the C callback boundary nonisolated; resolve @MainActor state only after explicit hop.
        unsafe ghostty_surface_set_pty_input_callback(surface, ghosttySurfacePtyInputCallback)

        ghostty.tick()

        touchScrollController.installGestures(on: self)
        touchSelectionController.installInteractions(on: self)
        shellSwipeController.installGestures(on: self)
        _ = lifecycleController

        // The surface is a `UIKeyInput` responder, so iPadOS would otherwise
        // offer the shortcuts bar above a hardware keyboard. The terminal has no
        // editable text buffer for it to act on.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []

        // `shouldOwnKeyboardFocus` reads `GCKeyboard.coalesced`, so a keyboard
        // attached or detached after attach has to re-evaluate first responder.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHardwareKeyboardAvailabilityChanged),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHardwareKeyboardAvailabilityChanged),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        bridge = nil
        if let surface = unsafe ghosttySurface {
            unsafe ghostty_surface_set_pty_input_callback(surface, nil)
            unsafe ghostty_surface_free(surface)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sizeDidChange(bounds.size, reason: "didMoveToWindow")
        lifecycleController.didMoveToWindow()

        if window != nil {
            Self.lastAttachedSurface = self
            // Claim FR on attach so hardware `UIPress` events and the system
            // keyboard reach this view. `shouldOwnKeyboardFocus` keeps the
            // default iPhone custom-keyboard path from ever claiming it.
            claimFirstResponder()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, Self.lastAttachedSurface === self {
            Self.lastAttachedSurface = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sizeDidChange(bounds.size, reason: "layoutSubviews")
    }

    func sizeDidChange(_ size: CGSize, reason: String) {
        guard let surface = unsafe ghosttySurface else { return }

        let scale = screenScale
        configureIOSurfaceLayers(size: size, scale: scale)

        let widthPx = max(Int(size.width * scale), 1)
        let heightPx = max(Int(size.height * scale), 1)
        let geometry = SurfaceGeometry(widthPx: widthPx, heightPx: heightPx, scale: scale)
        let didChangeGeometry = geometry != lastAppliedSurfaceGeometry

        if didChangeGeometry {
            unsafe ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            unsafe ghostty_surface_set_size(surface, UInt32(widthPx), UInt32(heightPx))
            lastAppliedSurfaceGeometry = geometry
            // Ghostty applies resizes on its I/O thread with coalescing, so the
            // ghostty_surface_size read below can still report the pre-resize grid.
            // Verify shortly after; settled passes are free thanks to the window
            // signature dedup, and a stale pass would otherwise leave the SSH PTY
            // rows behind the visible grid (blank band above the keyboard).
            scheduleGeometryVerifyResyncPasses()
        }

        let terminalSize = unsafe ghostty_surface_size(surface)
        let windowSignature = TerminalWindowSyncSignature(
            columns: Int(terminalSize.columns),
            rows: Int(terminalSize.rows),
            widthPx: widthPx,
            heightPx: heightPx
        )
        if windowSignature != lastSyncedTerminalWindowSignature {
            lastSyncedTerminalWindowSignature = windowSignature
            bridge?.updateWindowSize(
                columns: windowSignature.columns,
                rows: windowSignature.rows,
                widthPx: widthPx,
                heightPx: heightPx
            )
        }

        logQuantizationDetails(
            reason: reason,
            requestedSizePoints: size,
            boundsSizePoints: bounds.size,
            scale: scale,
            requestedWidthPx: widthPx,
            requestedHeightPx: heightPx,
            reported: terminalSize
        )
    }

    func scheduleDeferredSurfaceResync(reason: String) {
        deferredSurfaceResyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sizeDidChange(self.bounds.size, reason: reason)
            self.deferredSurfaceResyncWorkItem = nil
        }
        deferredSurfaceResyncWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func scheduleGeometryVerifyResyncPasses() {
        geometryVerifyResyncGeneration &+= 1
        let generation = geometryVerifyResyncGeneration
        let delays: [TimeInterval] = [1.0 / 60.0, 0.08, 0.3]
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.geometryVerifyResyncGeneration == generation else { return }
                self.sizeDidChange(self.bounds.size, reason: "geometry-verify-pass\(index + 1)")
            }
        }
    }

    func scheduleThemeResyncPasses(reason: String) {
        themeResyncGeneration &+= 1
        let generation = themeResyncGeneration
        let delays: [TimeInterval] = [0, 1.0 / 60.0, 0.08]
        setNeedsLayout()
        layoutIfNeeded()
        for (index, delay) in delays.enumerated() {
            let passReason = "\(reason)-pass\(index + 1)"
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.themeResyncGeneration == generation else { return }
                self.sizeDidChange(self.bounds.size, reason: passReason)
            }
        }
    }

    func applyTerminalFontSize(_ fontSize: Double, force: Bool = false) {
        guard let surface = unsafe ghosttySurface else { return }

        let quantizedFontSize = TerminalFontSizeSetting.quantized(fontSize)
        let shouldForce = force || !hasAppliedTerminalFontSizeAtLeastOnce
        if !shouldForce {
            guard !TerminalFontSizeSetting.approximatelyEqual(quantizedFontSize, appliedTerminalFontSize) else { return }
        }

        let action = "set_font_size:\(TerminalFontSizeSetting.formattedValue(quantizedFontSize))"
        // Swift 6.2 requires the outer acknowledgement; remove this split when releases use Swift 6.4+.
        #if compiler(<6.4)
        let actionApplied = unsafe action.withCString { actionPointer in
            unsafe ghostty_surface_binding_action(
                surface,
                actionPointer,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
        #else
        let actionApplied = action.withCString { actionPointer in
            unsafe ghostty_surface_binding_action(
                surface,
                actionPointer,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
        #endif

        guard actionApplied else {
            EsmaLog.ghostty.error(
                "failed to apply live terminal font size action=\(action, privacy: .public)"
            )
            return
        }

        appliedTerminalFontSize = quantizedFontSize
        hasAppliedTerminalFontSizeAtLeastOnce = true
        EsmaLog.ghostty.info(
            "applied live terminal font size points=\(TerminalFontSizeSetting.formattedValue(quantizedFontSize), privacy: .public)"
        )
        let hasUsableBounds = bounds.width > 0 && bounds.height > 0
        if hasUsableBounds {
            sizeDidChange(bounds.size, reason: "font-size-action")
        }
    }

    private func configureIOSurfaceLayers(size: CGSize, scale: CGFloat) {
        let ioLayers = layer.sublayers?.filter { String(describing: type(of: $0)) == "IOSurfaceLayer" } ?? []

        if !didLogIOSurfaceLayerCount {
            didLogIOSurfaceLayerCount = true
            EsmaLog.ghostty.info("iosurface layer count=\(ioLayers.count)")
        }

        guard !ioLayers.isEmpty else { return }

        let targetBounds = CGRect(origin: .zero, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ioLayer in ioLayers {
            ioLayer.frame = targetBounds
            ioLayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    func attachInputRouter(_ inputRouter: TerminalInputRouter) {
        hardwareInputRouter = inputRouter
        inputRouter.attach(sink: self)
        inputRouter.hostConnectionPhase = bridge?.hostConnectionPhase ?? .disconnected
        inputRouter.hostConnectionMethod = bridge?.hostConnectionMethod
        bridge?.hostConnectionPhaseDidChange = { [weak inputRouter] phase in
            inputRouter?.hostConnectionPhase = phase
        }
        bridge?.hostConnectionMethodDidChange = { [weak inputRouter] method in
            inputRouter?.hostConnectionMethod = method
        }
        inputRouter.updateConnectionRecoveryRequest(bridge?.connectionRecoveryRequest)
        bridge?.connectionRecoveryRequestDidChange = { [weak inputRouter] request in
            inputRouter?.updateConnectionRecoveryRequest(request)
        }
    }

    func updateActiveHost(_ host: AgenTTYHost?) {
        bridge?.setActiveHost(host)
    }

    func handleShortcutShellCommand(
        _ request: AgenTTYForegroundShellCommand,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard lastHandledShortcutCommandID != request.id else { return }
        lastHandledShortcutCommandID = request.id

        guard let host = hostStore.hosts.first(where: { $0.id == request.hostID }) else {
            EsmaLog.terminal.error(
                "shortcut shell command dropped: host no longer exists host_id=\(request.hostID.uuidString, privacy: .public)"
            )
            completion(false)
            return
        }

        hostStore.selectHost(id: host.id)
        bridge?.setActiveHost(host)
        bridge?.enqueueShortcutShellCommand(
            requestID: request.id,
            hostID: host.id,
            command: request.command,
            completion: completion
        )
    }

    func updateHostAvailability(_ hasNoHosts: Bool) {
        bridge?.setHostAvailability(hasNoHosts: hasNoHosts)
    }

    func dismissConnectionRecovery() {
        bridge?.dismissConnectionRecovery()
    }

    func retryActiveConnection() {
        bridge?.retryConnectionRecovery()
    }

    func handleApplicationWillResignActive() {
        bridge?.handleApplicationWillResignActive()
    }

    func handleApplicationDidEnterBackground() {
        bridge?.handleApplicationDidEnterBackground()
    }

    func handleApplicationDidBecomeActive() {
        bridge?.handleApplicationDidBecomeActive()
    }

    func attachShellState(_ state: ShellIndicatorState) {
        self.shellState = state
        pendingOptimisticShellStates.removeAll(keepingCapacity: false)
        didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
        syncPredictedShellState(windowIds: state.displayedWindowIDs, activePosition: state.activePosition)
        lastAppliedCanonicalShellStateSignature = canonicalShellStateSignature(
            windowIds: state.displayedWindowIDs,
            activePosition: state.activePosition
        )
        bridge?.shellStateDidChange = { [weak self, weak state] windowCount, activePosition, windowIds in
            guard let self else { return }
            if self.shouldSuppressCanonicalShellState(windowIds: windowIds, activePosition: activePosition) {
                return
            }
            guard self.shouldApplyCanonicalShellState(windowIds: windowIds, activePosition: activePosition) else {
                return
            }
            self.syncPredictedShellState(windowIds: windowIds, activePosition: activePosition)
            state?.update(windowCount: windowCount, activePosition: activePosition, windowIds: windowIds)
        }
        bridge?.tmuxShellSwipeDidComplete = { [weak self] didApplyCanonicalState in
            self?.handleCompletedSwipeCommand(didApplyCanonicalState: didApplyCanonicalState)
        }
        bridge?.shellTitleDidChange = { [weak state] windowID, title in
            state?.updateWindowTitle(windowID: windowID, title: title)
        }
        bridge?.shellWorkingDirectoryDidChange = { [weak state] windowID, workingDirectoryPath in
            state?.updateWindowWorkingDirectory(
                windowID: windowID,
                workingDirectoryPath: workingDirectoryPath
            )
        }
        bridge?.activeShellContextDidChange = { [weak state] windowID, workingDirectoryPath, branchName in
            state?.updateWindowContext(
                windowID: windowID,
                workingDirectoryPath: workingDirectoryPath,
                branchName: branchName
            )
        }
        state.spacebarTitleCharacterLimitDidChange = { [weak bridge = bridge] maxCharacters in
            bridge?.setShellTitleCharacterLimit(maxCharacters)
        }
        state.navigateToWindow = { [weak bridge = bridge] windowId in
            bridge?.selectTmuxWindow(id: windowId)
        }
        state.createAndNavigateToNewWindow = { [weak bridge = bridge] in
            bridge?.createTmuxWindowAndSelect()
        }
    }
    private func sendDataToSSH(_ data: Data) {
        unsafe data.withUnsafeBytes { rawBuf in
            guard let base = unsafe rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            unsafe bridge?.sendRawBytes(base, count: data.count)
        }
    }

    func handlePtyInputFromGhosttyCallback(_ data: Data) {
        sendDataToSSH(data)
    }

    func sendTerminalBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        if !didLogCustomKeyboardPath {
            didLogCustomKeyboardPath = true
            EsmaLog.terminal.info("in-app keyboard input routed directly to SSH byte stream")
        }

        #if compiler(<6.4)
        unsafe bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            unsafe bridge?.sendRawBytes(base, count: bytes.count)
        }
        #else
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            unsafe bridge?.sendRawBytes(base, count: bytes.count)
        }
        #endif
    }

    func insertDictationText(_ text: String, fallbackBytes: [UInt8]) {
        guard !text.isEmpty else { return }
        guard let bridge else {
            sendTerminalBytes(fallbackBytes)
            return
        }
        bridge.insertDictationText(text, fallbackBytes: fallbackBytes)
    }

    func captureDictationShellContext(maxLines: Int) async -> String? {
        guard let bridge else { return nil }
        return await bridge.captureActiveTmuxPaneTail(maxLines: maxLines)
    }

    func insertClipboardText(_ text: String, fallbackBytes: [UInt8]) {
        guard !text.isEmpty else { return }
        guard let bridge else {
            sendTerminalBytes(fallbackBytes)
            return
        }
        bridge.insertClipboardText(text, fallbackBytes: fallbackBytes)
    }

    func insertClipboardImages(_ imagePayloads: [TerminalClipboardImagePayload], fallbackBytes: [UInt8]) {
        guard !imagePayloads.isEmpty else { return }
        guard let bridge else {
            sendTerminalBytes(fallbackBytes)
            return
        }
        bridge.insertClipboardImages(imagePayloads, fallbackBytes: fallbackBytes)
    }

    func insertClipboardFiles(_ fileProviders: [any TerminalClipboardItemProvider], fallbackBytes: [UInt8]) {
        guard !fileProviders.isEmpty else { return }
        guard let bridge else {
            sendTerminalBytes(fallbackBytes)
            return
        }
        bridge.insertClipboardFiles(fileProviders, fallbackBytes: fallbackBytes)
    }

    func setDirectionalPadCursorStyle(active: Bool) {
        guard active != isDirectionalPadCursorStyleActive else { return }
        isDirectionalPadCursorStyleActive = active
        bridge?.setDirectionalPadCursorStyle(active: active)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(selectAll(_:)):
            return touchSelectionController.hasSelection()
        case #selector(paste(_:)):
            return hasPasteableClipboardContent
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        touchSelectionController.copyCurrentSelectionToPasteboard()
    }

    override func selectAll(_ sender: Any?) {
        touchSelectionController.selectAll()
    }

    override func paste(_ sender: Any?) {
        pasteClipboardContent()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let afterCapsLock = handleCapsLockPressBegan(presses)
        let unhandled = routeHardwareKeyPresses(afterCapsLock)
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let afterCapsLock = handleCapsLockPressEnded(presses)
        stopHardwareRepeatForReleasedPresses(afterCapsLock)
        if !afterCapsLock.isEmpty {
            super.pressesEnded(afterCapsLock, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let afterCapsLock = handleCapsLockPressEnded(presses)
        stopHardwareRepeatForReleasedPresses(afterCapsLock)
        if !afterCapsLock.isEmpty {
            super.pressesCancelled(afterCapsLock, with: event)
        }
    }

    private func routeHardwareKeyPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard let router = hardwareInputRouter else { return presses }
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let mapped = HardwareKeyMapping.map(key) else {
                unhandled.insert(press)
                continue
            }
            router.handleHardwareKey(action: mapped.action, modifiers: mapped.modifiers)
            startHardwareRepeat(
                for: mapped.action,
                modifiers: mapped.modifiers,
                keyCode: key.keyCode,
                router: router
            )
        }
        return unhandled
    }

    /// Filters Caps Lock presses out of the generic hardware-key flow and
    /// schedules the tap-vs-hold dictation timer. Returns presses that should
    /// continue through the standard mapping.
    private func handleCapsLockPressBegan(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard hardwareInputRouter != nil else { return presses }
        var remaining: Set<UIPress> = []
        for press in presses {
            guard press.key?.keyCode == .keyboardCapsLock else {
                remaining.insert(press)
                continue
            }
            beginCapsLockDictationGesture()
        }
        return remaining
    }

    private func handleCapsLockPressEnded(_ presses: Set<UIPress>) -> Set<UIPress> {
        var remaining: Set<UIPress> = []
        for press in presses {
            guard press.key?.keyCode == .keyboardCapsLock else {
                remaining.insert(press)
                continue
            }
            endCapsLockDictationGesture()
        }
        return remaining
    }

    private func beginCapsLockDictationGesture() {
        cancelCapsLockHoldTimer()
        capsLockIsPressed = true
        capsLockEnteredPushToTalk = false
        let timer = Timer(timeInterval: Self.capsLockHoldThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.capsLockIsPressed,
                      let router = self.hardwareInputRouter else { return }
                self.capsLockEnteredPushToTalk = true
                router.handleHardwareKey(action: .dictation, modifiers: [])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        capsLockHoldTimer = timer
    }

    private func endCapsLockDictationGesture() {
        let wasPushToTalk = capsLockEnteredPushToTalk
        cancelCapsLockHoldTimer()
        capsLockIsPressed = false
        capsLockEnteredPushToTalk = false
        guard let router = hardwareInputRouter else { return }
        // Tap (timer canceled before fire): single toggle = start (or stop the
        // previous tap-toggled session). Push-to-talk: timer already started
        // dictation on hold; release toggles to stop+transcribe.
        _ = wasPushToTalk
        router.handleHardwareKey(action: .dictation, modifiers: [])
    }

    private func cancelCapsLockHoldTimer() {
        capsLockHoldTimer?.invalidate()
        capsLockHoldTimer = nil
    }

    private func startHardwareRepeat(
        for action: KeyAction,
        modifiers: Set<ModifierKey>,
        keyCode: UIKeyboardHIDUsage,
        router: TerminalInputRouter
    ) {
        guard let behavior = action.repeatBehavior else {
            hardwareKeyRepeatEngine.stop()
            hardwareRepeatActiveKeyCode = nil
            return
        }
        hardwareRepeatActiveKeyCode = keyCode
        hardwareKeyRepeatEngine.start(
            initialDelay: behavior.initialDelay,
            hapticMinimumInterval: nil
        ) { [weak self, weak router] holdDuration in
            guard let self, let router else { return nil }
            guard self.hardwareRepeatActiveKeyCode == keyCode else { return nil }
            router.handleHardwareKey(action: action, modifiers: modifiers)
            return RepeatTickStep(
                nextDelay: behavior.interval(forHoldDuration: holdDuration),
                emitsHaptic: false
            )
        }
    }

    private func stopHardwareRepeatForReleasedPresses(_ presses: Set<UIPress>) {
        guard let activeKeyCode = hardwareRepeatActiveKeyCode else { return }
        for press in presses where press.key?.keyCode == activeKeyCode {
            hardwareKeyRepeatEngine.stop()
            hardwareRepeatActiveKeyCode = nil
            return
        }
    }

    func sendSyntheticTerminalFocusRefresh(reason: String) {
        bridge?.sendSyntheticTerminalFocusRefresh(reason: reason)
    }

    func setSurfaceFocus(_ focused: Bool, reason: String) {
        lifecycleController.setSurfaceFocus(focused, reason: reason)
    }

    func cancelScrollMomentumForSelection() {
        touchScrollController.cancelMomentum()
    }

    private var hasPasteableClipboardContent: Bool {
        TerminalClipboard.hasPasteableGeneralContent()
    }

    private func pasteClipboardContent() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = await TerminalClipboard.generalPastePayload()
            applyClipboardPastePayload(payload, fallbackBytes: [])
        }
    }

    private var swipeSnapshotView: UIView?
    private var swipeMaskingView: UIView?
    private var isWaitingForSwipeData = false
    private var swipeDataTimeoutWorkItem: DispatchWorkItem?
    private var predictedShellWindowIds: [Int]?
    private var predictedShellActivePosition: Int?
    private var pendingOptimisticShellStates: [(windowIds: [Int], activePosition: Int)] = []
    private var didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
    private var nextProvisionalWindowID = -1
    private var lastAppliedCanonicalShellStateSignature: CanonicalShellStateSignature?

    func canSwipeShell(in direction: TerminalShellSwipeDirection) -> Bool {
        // Swiping drives tmux over the live transport. While the host is gone
        // the gesture must not start at all, so the terminal never looks like a
        // connected session.
        guard bridge?.hostConnectionPhase.allowsHostInteraction == true else { return false }
        guard let predictedState = predictedShellState else { return true }
        if direction == .backward {
            return predictedState.activePosition > 0
        }
        let lastPosition = max(predictedState.windowIds.count - 1, 0)
        return predictedState.activePosition < lastPosition || predictedState.windowIds.count < maxTmuxShellCount
    }

    func beginShellSwipePan() {
        shellState?.beginSwipeIndicatorEmphasis()
        shellState?.updateActiveShellSwipeReleaseVelocity(velocityX: 0)
        shellState?.updateActiveShellSwipePreview(translationX: 0, viewWidth: bounds.width)
        cancelSwipeDataWait()
        clearSwipeOverlay()

        guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }

        let mask = UIView(frame: bounds)
        mask.backgroundColor = ghostty.terminalBackgroundUIColor
        mask.isUserInteractionEnabled = false
        mask.layer.zPosition = VisualLayering.TerminalSurfaceUIKit.swipeMask
        addSubview(mask)
        swipeMaskingView = mask

        snapshot.frame = bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.zPosition = VisualLayering.TerminalSurfaceUIKit.swipeSnapshot
        addSubview(snapshot)
        swipeSnapshotView = snapshot
    }

    func updateShellSwipePan(translationX: CGFloat) {
        swipeSnapshotView?.transform = CGAffineTransform(translationX: translationX, y: 0)
    }

    func endShellSwipePan(translationX: CGFloat, velocityX: CGFloat) {
        shellState?.endSwipeIndicatorEmphasis()
        let width = bounds.width
        guard width > 0 else {
            cancelSwipeCommitAnimation()
            return
        }
        shellState?.updateActiveShellSwipeReleaseVelocity(velocityX: velocityX)

        let progress = abs(translationX) / width
        let shouldCommit = progress > swipeCommitProgressThreshold || abs(velocityX) > swipeCommitVelocityThreshold
        guard shouldCommit,
              let direction = resolveSwipeDirection(translationX: translationX, velocityX: velocityX),
              canSwipeShell(in: direction)
        else {
            cancelSwipeCommitAnimation()
            return
        }

        if let snapshot = swipeSnapshotView {
            let targetTranslationX: CGFloat = direction == .forward ? -width : width
            let springVelocity = abs(velocityX) / 1000
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: springVelocity,
                options: .curveEaseOut
            ) {
                snapshot.transform = CGAffineTransform(translationX: targetTranslationX, y: 0)
            } completion: { _ in
                if self.swipeSnapshotView === snapshot {
                    self.swipeSnapshotView = nil
                }
                snapshot.removeFromSuperview()
            }
        }

        startCommittedShellSwipe(direction)
    }

    private func handleTerminalDataDidUpdate() {
        guard isWaitingForSwipeData else { return }
        cancelSwipeDataWait()

        guard let mask = swipeMaskingView else { return }

        // Give Ghostty one short render beat before revealing the new shell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.swipeMaskingView === mask else { return }

            UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseOut) {
                mask.alpha = 0
            } completion: { _ in
                if self.swipeMaskingView === mask {
                    self.swipeMaskingView = nil
                }
                mask.removeFromSuperview()
            }
        }
    }

    private func startCommittedShellSwipe(_ direction: TerminalShellSwipeDirection) {
        // Dispatch tmux navigation only after commit; canceled drags stay non-mutating.
        guard let bridge, bridge.navigateTmuxShell(direction) else {
            shellState?.cancelActiveShellSwipePreview()
            clearSwipeMask()
            return
        }

        applyPredictedSwipe(direction)

        guard swipeMaskingView != nil else { return }

        cancelSwipeDataWait()
        isWaitingForSwipeData = true
        let work = DispatchWorkItem { [weak self] in
            self?.handleTerminalDataDidUpdate()
        }
        swipeDataTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + swipeDataTimeout, execute: work)
    }

    private func resolveSwipeDirection(
        translationX: CGFloat,
        velocityX: CGFloat
    ) -> TerminalShellSwipeDirection? {
        if abs(translationX) >= swipeDirectionThreshold {
            return translationX < 0 ? .forward : .backward
        }
        if abs(velocityX) >= swipeCommitVelocityThreshold {
            return velocityX < 0 ? .forward : .backward
        }
        guard translationX != 0 else { return nil }
        return translationX < 0 ? .forward : .backward
    }

    private func cancelSwipeCommitAnimation() {
        cancelSwipeDataWait()
        shellState?.cancelActiveShellSwipePreview()

        guard let snapshot = swipeSnapshotView else {
            clearSwipeOverlay()
            return
        }

        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            snapshot.transform = .identity
        } completion: { _ in
            self.clearSwipeOverlay()
        }
    }

    private func cancelSwipeDataWait() {
        isWaitingForSwipeData = false
        swipeDataTimeoutWorkItem?.cancel()
        swipeDataTimeoutWorkItem = nil
    }

    private func clearSwipeOverlay() {
        clearSwipeSnapshot()
        clearSwipeMask()
    }

    private func clearSwipeSnapshot() {
        swipeSnapshotView?.removeFromSuperview()
        swipeSnapshotView = nil
    }

    private func clearSwipeMask() {
        swipeMaskingView?.removeFromSuperview()
        swipeMaskingView = nil
    }

    private var predictedShellState: (windowIds: [Int], activePosition: Int)? {
        guard let shellState else { return nil }

        let sourceWindowIds = predictedShellWindowIds ?? shellState.displayedWindowIDs
        let normalizedWindowIds = boundedWindowIds(sourceWindowIds)
        let proposedActivePosition = predictedShellActivePosition ?? shellState.activePosition
        return (
            windowIds: normalizedWindowIds,
            activePosition: normalizedActivePosition(proposedActivePosition, windowCount: normalizedWindowIds.count)
        )
    }

    private func syncPredictedShellState(windowIds: [Int], activePosition: Int) {
        let normalizedWindowIds = boundedWindowIds(windowIds)
        predictedShellWindowIds = normalizedWindowIds
        predictedShellActivePosition = normalizedActivePosition(
            activePosition,
            windowCount: normalizedWindowIds.count
        )
    }

    private func applyPredictedSwipe(_ direction: TerminalShellSwipeDirection) {
        guard var predictedShellState else { return }

        switch direction {
        case .forward:
            let lastPosition = max(predictedShellState.windowIds.count - 1, 0)
            if predictedShellState.activePosition < lastPosition {
                predictedShellState.activePosition += 1
            } else if predictedShellState.windowIds.count < maxTmuxShellCount {
                let provisionalWindowID = allocateProvisionalWindowID(avoiding: predictedShellState.windowIds)
                predictedShellState.windowIds.append(provisionalWindowID)
                predictedShellState.activePosition = max(predictedShellState.windowIds.count - 1, 0)
            }
        case .backward:
            if predictedShellState.activePosition > 0 {
                predictedShellState.activePosition -= 1
            }
        }

        syncPredictedShellState(
            windowIds: predictedShellState.windowIds,
            activePosition: predictedShellState.activePosition
        )
        markPendingOptimisticShellState(
            windowIds: predictedShellState.windowIds,
            activePosition: predictedShellState.activePosition
        )
        shellState?.applyOptimistic(
            windowIds: predictedShellState.windowIds,
            activePosition: predictedShellState.activePosition
        )
    }

    private func markPendingOptimisticShellState(windowIds: [Int], activePosition: Int) {
        let normalizedWindowIds = boundedWindowIds(windowIds)
        let normalizedPosition = normalizedActivePosition(
            activePosition,
            windowCount: normalizedWindowIds.count
        )
        pendingOptimisticShellStates.append(
            (windowIds: normalizedWindowIds, activePosition: normalizedPosition)
        )
        if pendingOptimisticShellStates.count > maxTmuxShellCount {
            let overflow = pendingOptimisticShellStates.count - maxTmuxShellCount
            pendingOptimisticShellStates.removeFirst(overflow)
        }
    }

    private func shouldSuppressCanonicalShellState(windowIds: [Int], activePosition: Int) -> Bool {
        guard !pendingOptimisticShellStates.isEmpty else {
            didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
            return false
        }

        let normalizedWindowIds = boundedWindowIds(windowIds)
        let normalizedPosition = normalizedActivePosition(
            activePosition,
            windowCount: normalizedWindowIds.count
        )
        if let matchedIndex = pendingOptimisticShellStates.firstIndex(where: {
            $0.windowIds == normalizedWindowIds && $0.activePosition == normalizedPosition
        }) {
            pendingOptimisticShellStates.removeFirst(matchedIndex + 1)
            didConsumePendingOptimisticStateOnLastCanonicalUpdate = true
            return !pendingOptimisticShellStates.isEmpty
        }

        guard let latestPendingState = pendingOptimisticShellStates.last else {
            didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
            return false
        }

        let canonicalShapeMatchesLatestPending =
            latestPendingState.windowIds.count == normalizedWindowIds.count &&
            latestPendingState.activePosition == normalizedPosition
        if canonicalShapeMatchesLatestPending {
            pendingOptimisticShellStates.removeAll(keepingCapacity: false)
            didConsumePendingOptimisticStateOnLastCanonicalUpdate = true
            return false
        }

        didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
        return true
    }

    private func handleCompletedSwipeCommand(didApplyCanonicalState: Bool) {
        shellState?.cancelActiveShellSwipePreview()
        if didApplyCanonicalState {
            if didConsumePendingOptimisticStateOnLastCanonicalUpdate {
                didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
                return
            }
            dropFirstPendingOptimisticShellState()
            return
        }

        didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
        dropFirstPendingOptimisticShellState()
    }

    private func dropFirstPendingOptimisticShellState() {
        guard !pendingOptimisticShellStates.isEmpty else {
            didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
            return
        }
        pendingOptimisticShellStates.removeFirst()
        didConsumePendingOptimisticStateOnLastCanonicalUpdate = false
    }

    private func boundedWindowIds(_ windowIds: [Int]) -> [Int] {
        Array(windowIds.prefix(maxTmuxShellCount))
    }

    private func canonicalShellStateSignature(
        windowIds: [Int],
        activePosition: Int
    ) -> CanonicalShellStateSignature {
        let normalizedWindowIds = boundedWindowIds(windowIds)
        let normalizedPosition = normalizedActivePosition(
            activePosition,
            windowCount: normalizedWindowIds.count
        )
        return CanonicalShellStateSignature(
            windowIds: normalizedWindowIds,
            activePosition: normalizedPosition
        )
    }

    private func shouldApplyCanonicalShellState(windowIds: [Int], activePosition: Int) -> Bool {
        let signature = canonicalShellStateSignature(windowIds: windowIds, activePosition: activePosition)
        if signature == lastAppliedCanonicalShellStateSignature {
            return false
        }
        lastAppliedCanonicalShellStateSignature = signature
        return true
    }

    private func normalizedActivePosition(_ proposed: Int, windowCount: Int) -> Int {
        guard windowCount > 0 else { return 0 }
        return min(max(proposed, 0), windowCount - 1)
    }

    private func allocateProvisionalWindowID(avoiding windowIds: [Int]) -> Int {
        let occupiedWindowIds = Set(windowIds)
        var candidate = nextProvisionalWindowID
        while occupiedWindowIds.contains(candidate) {
            candidate -= 1
        }
        nextProvisionalWindowID = candidate - 1
        return candidate
    }

    private func logQuantizationDetails(
        reason: String,
        requestedSizePoints: CGSize,
        boundsSizePoints: CGSize,
        scale: CGFloat,
        requestedWidthPx: Int,
        requestedHeightPx: Int,
        reported: ghostty_surface_size_s
    ) {
        let columns = Int(reported.columns)
        let rows = Int(reported.rows)
        let cellWidthPx = Int(reported.cell_width_px)
        let cellHeightPx = Int(reported.cell_height_px)
        let reportedWidthPx = Int(reported.width_px)
        let reportedHeightPx = Int(reported.height_px)

        let gridWidthPx = columns * cellWidthPx
        let gridHeightPx = rows * cellHeightPx

        let requestedRemainderWidthPx = max(requestedWidthPx - gridWidthPx, 0)
        let requestedRemainderHeightPx = max(requestedHeightPx - gridHeightPx, 0)
        let reportedRemainderWidthPx = max(reportedWidthPx - gridWidthPx, 0)
        let reportedRemainderHeightPx = max(reportedHeightPx - gridHeightPx, 0)

        let rawWidthPx = Double(requestedSizePoints.width * scale)
        let rawHeightPx = Double(requestedSizePoints.height * scale)
        let widthCastLossPx = rawWidthPx - Double(requestedWidthPx)
        let heightCastLossPx = rawHeightPx - Double(requestedHeightPx)

        let signature = QuantizationSignature(
            requestedWidthPx: requestedWidthPx,
            requestedHeightPx: requestedHeightPx,
            reportedWidthPx: reportedWidthPx,
            reportedHeightPx: reportedHeightPx,
            columns: columns,
            rows: rows,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            requestedRemainderWidthPx: requestedRemainderWidthPx,
            requestedRemainderHeightPx: requestedRemainderHeightPx
        )

        let shouldLogUpdate = EsmaDiagnostics.verboseLoggingEnabled || signature != lastLoggedQuantizationSignature
        guard shouldLogUpdate else { return }
        lastLoggedQuantizationSignature = signature

        quantizationLogCount += 1
        guard EsmaDiagnostics.shouldLog(counter: quantizationLogCount, defaultLimit: 15) else {
            return
        }

        let ghosttyConfig = AgenTTYGhosttyConfig.iOSInitialization
        let ioSurfaceWidthsPt = layer.sublayers?
            .filter { String(describing: type(of: $0)) == "IOSurfaceLayer" }
            .prefix(3)
            .map { String(describing: $0.frame.width) } ?? []
        let ioSurfaceWidthsSummary = ioSurfaceWidthsPt.isEmpty ? "none" : ioSurfaceWidthsPt.joined(separator: ",")
        EsmaLog.ghostty.info(
            """
            quantization reason=\(reason, privacy: .public) requested_pt=\(requestedSizePoints.width, privacy: .public)x\(requestedSizePoints.height, privacy: .public) bounds_pt=\(boundsSizePoints.width, privacy: .public)x\(boundsSizePoints.height, privacy: .public) scale=\(scale, privacy: .public) raw_px=\(rawWidthPx, privacy: .public)x\(rawHeightPx, privacy: .public) cast_loss_px=\(widthCastLossPx, privacy: .public)x\(heightCastLossPx, privacy: .public) requested_px=\(requestedWidthPx, privacy: .public)x\(requestedHeightPx, privacy: .public) reported_px=\(reportedWidthPx, privacy: .public)x\(reportedHeightPx, privacy: .public)
            quantization grid cols=\(columns, privacy: .public) rows=\(rows, privacy: .public) cell_px=\(cellWidthPx, privacy: .public)x\(cellHeightPx, privacy: .public) grid_px=\(gridWidthPx, privacy: .public)x\(gridHeightPx, privacy: .public) remainder_requested_px=\(requestedRemainderWidthPx, privacy: .public)x\(requestedRemainderHeightPx, privacy: .public) remainder_reported_px=\(reportedRemainderWidthPx, privacy: .public)x\(reportedRemainderHeightPx, privacy: .public)
            quantization iosurface widths_pt=\(ioSurfaceWidthsSummary, privacy: .public)
            quantization config padding_x=\(ghosttyConfig.windowPaddingX.cliValue, privacy: .public) padding_y=\(ghosttyConfig.windowPaddingY.cliValue, privacy: .public) padding_balance=\(ghosttyConfig.windowPaddingBalance.rawValue, privacy: .public) padding_color=\(ghosttyConfig.windowPaddingColor.rawValue, privacy: .public)
            """
        )
    }
}

// MARK: - System keyboard input

/// `UIKeyInput` is what lets the iOS software keyboard target the terminal in
/// `KeyboardInputMode.system`. There is no local text buffer: every insertion is
/// forwarded straight into the existing hardware-key encoder, which is also why
/// `hasText` is always false. The conformance is inert unless the surface holds
/// first responder, and `shouldOwnKeyboardFocus` keeps that from happening on
/// the default iPhone path.
extension TerminalSurfaceViewIOS: UIKeyInput {
    var hasText: Bool { false }

    func insertText(_ text: String) {
        guard let router = hardwareInputRouter else { return }
        for character in text {
            // The system Return key delivers "\n"; the terminal wants the
            // existing enter encoding, not a raw 0x0A.
            if character == "\n" || character == "\r" {
                router.handleHardwareKey(action: .enter, modifiers: [])
            } else {
                router.handleHardwareKey(action: .character(String(character)), modifiers: [])
            }
        }
    }

    func deleteBackward() {
        hardwareInputRouter?.handleHardwareKey(action: .backspace, modifiers: [])
    }
}

// MARK: - System keyboard traits

/// Every trait here exists to stop iOS from rewriting shell input: smart quotes
/// would break quoting, smart dashes would break `--flag`, autocapitalization
/// would break `ls`, and predictions would suggest prose into a command line.
/// `UITextInputTraits` declares these as `@objc optional`, so the explicit
/// `@objc` keeps UIKit's `respondsToSelector` probe from silently falling back
/// to the defaults.
extension TerminalSurfaceViewIOS {
    @objc var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { _ = newValue }
    }

    @objc var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { _ = newValue }
    }

    @objc var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { _ = newValue }
    }

    @objc var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { _ = newValue }
    }

    @objc var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { _ = newValue }
    }

    @objc var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { _ = newValue }
    }

    @objc var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { _ = newValue }
    }

    @objc var writingToolsBehavior: UIWritingToolsBehavior {
        get { .none }
        set { _ = newValue }
    }

    @objc var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set { _ = newValue }
    }

    @objc var returnKeyType: UIReturnKeyType {
        get { .default }
        set { _ = newValue }
    }

    @objc var keyboardAppearance: UIKeyboardAppearance {
        get { AppTheme.preferredColorScheme == .light ? .light : .dark }
        set { _ = newValue }
    }
}
