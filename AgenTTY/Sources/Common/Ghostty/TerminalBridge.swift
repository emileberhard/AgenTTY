import Foundation
import GhosttyKit
import NIOCore
import NIOSSH
import OSLog
import Synchronization
#if os(iOS)
import UIKit
#endif

@MainActor
enum TerminalShellSwipeDirection {
    case forward
    case backward
}

nonisolated enum AgenTTYHostConnectionPhase: Sendable {
    case disconnected
    case connecting
    case connected

    /// Single gate for host-dependent UI affordances (shell swipes, the
    /// spacebar quick switcher, new-shell creation). Anything that needs a live
    /// transport reads this instead of checking phases ad hoc.
    var allowsHostInteraction: Bool {
        self == .connected
    }
}

@MainActor
private enum SyntheticFocusRefreshReason {
    case themeChange
    case didBecomeActive
    case other(String)

    init(rawReason: String) {
        switch rawReason {
        case "theme-change":
            self = .themeChange
        case "didBecomeActive":
            self = .didBecomeActive
        default:
            self = .other(rawReason)
        }
    }
}

private enum AgenTTYPasswordBootstrapError: LocalizedError {
    case keyInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyInstallFailed(let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "Failed to install the AgenTTY SSH key on the host."
            }
            return "Failed to install the AgenTTY SSH key on the host: \(trimmedOutput)"
        }
    }
}

private struct AgenTTYAnalyticsSSHSession {
    let sessionID: String
    let hostID: UUID
    let generation: Int
    let startedAt: Date
    let authMode: AgenTTYAnalyticsSSHAuthMode
    var wasReady: Bool
    var hadTerminalInput: Bool
    var inputEventCount: Int
}

private struct AgenTTYPendingShortcutShellCommand: Sendable {
    let requestID: UUID
    let hostID: UUID
    let command: String
    let completion: @MainActor @Sendable (Bool) -> Void
}

nonisolated private struct TerminalInboundRoutingState: Sendable {
    var generation = 0
    var surfaceBits: UInt = 0
    var isAcceptingData = false
    var isSwipeNotifyActive = false
    var didLogFirstInboundBytes = false
    var inboundChunkCount = 0
}

nonisolated private struct TerminalInboundRoute: Sendable {
    let surfaceBits: UInt
    let chunkCount: Int
    let shouldLogFirstInboundBytes: Bool
    let shouldLogChunk: Bool
    let shouldNotifyTerminalDataUpdate: Bool
}

nonisolated private final class TerminalInboundDataRouter: Sendable {
    private let state = Mutex(TerminalInboundRoutingState())

    func updateSurfaceBits(_ surfaceBits: UInt) {
        state.withLock { state in
            state.surfaceBits = surfaceBits
        }
    }

    func updateConnection(generation: Int, acceptingData: Bool) {
        state.withLock { state in
            state.generation = generation
            state.isAcceptingData = acceptingData
        }
    }

    func setAcceptingData(_ isAcceptingData: Bool) {
        state.withLock { state in
            state.isAcceptingData = isAcceptingData
        }
    }

    func setSwipeNotifyActive(_ isActive: Bool) {
        state.withLock { state in
            state.isSwipeNotifyActive = isActive
        }
    }

    func routeRemoteData(
        _ data: Data,
        generation: Int,
        source: String,
        terminalIOQueue: DispatchQueue,
        notifyTerminalDataDidUpdate: @escaping @Sendable () -> Void
    ) {
        guard !data.isEmpty else { return }

        guard let route = state.withLock({ state -> TerminalInboundRoute? in
            guard state.generation == generation,
                  state.isAcceptingData,
                  state.surfaceBits != 0 else {
                return nil
            }

            let shouldLogFirstInboundBytes = !state.didLogFirstInboundBytes
            state.didLogFirstInboundBytes = true
            state.inboundChunkCount += 1
            let chunkCount = state.inboundChunkCount
            return TerminalInboundRoute(
                surfaceBits: state.surfaceBits,
                chunkCount: chunkCount,
                shouldLogFirstInboundBytes: shouldLogFirstInboundBytes,
                shouldLogChunk: EsmaDiagnostics.shouldLog(counter: chunkCount, defaultLimit: 4),
                shouldNotifyTerminalDataUpdate: state.isSwipeNotifyActive
            )
        }) else { return }

        if route.shouldLogFirstInboundBytes {
            EsmaLog.terminal.info("first inbound bytes=\(data.count) source=\(source, privacy: .public)")
        }
        if route.shouldLogChunk {
            let preview = Self.logPreview(of: data)
            EsmaLog.terminal.info(
                "inbound chunk #\(route.chunkCount) source=\(source, privacy: .public) bytes=\(data.count) preview=\(preview, privacy: .public)"
            )
        }

        terminalIOQueue.async {
            guard let surface = unsafe UnsafeMutableRawPointer(bitPattern: route.surfaceBits) else { return }
            unsafe data.withUnsafeBytes { rawBuffer in
                guard let base = unsafe rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                // Ghostty's processOutput path already schedules coalesced renderer wakeups.
                // Avoid per-chunk forced draws here to prevent extra CPU/GPU churn.
                unsafe ghostty_surface_write_pty_output(surface, base, UInt(data.count))
            }
        }

        if route.shouldNotifyTerminalDataUpdate {
            notifyTerminalDataDidUpdate()
        }
    }

    private static func logPreview(of data: Data, maxBytes: Int = 80) -> String {
        let limited = data.prefix(maxBytes)
        let bytes = Array(limited)
        let text = String(decoding: bytes, as: UTF8.self)
        let singleLine = text
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        if data.count > maxBytes {
            return "\(singleLine)…"
        }
        return singleLine
    }
}

@safe
@MainActor
final class TerminalBridge {
    private let runtime: GhosttyRuntime
    private let surface: ghostty_surface_t
    private let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    private let passwordStore: AgenTTYSSHPasswordStore
    private let hostStore: AgenTTYHostStore
    private let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    private let analyticsClient: AgenTTYAnalyticsClient
    private var ssh: SSHClientSession?
    private var connectPreflightTask: Task<Void, Never>?
    private var clipboardFileInsertTask: Task<Void, Never>?
    private var reconnectWorkItem: DispatchWorkItem?
    private var notificationsProvisionTask: Task<Void, Never>?
    private var notificationsRefreshTask: Task<Void, Never>?
    private var relayConnectorMaintenanceTask: Task<Void, Never>?
#if os(iOS)
    private var backgroundWarmHoldTask: UIBackgroundTaskIdentifier = .invalid
#endif
    private var reconnectAttempt = 0
    private var reconnectRetryDeadline: Date?
    private let reconnectScreen = TerminalReconnectScreenPresenter()
    private var connectionGeneration = 0
    private var activeHost: AgenTTYHost?
    private var activeConnectionTarget: AgenTTYConnectionTarget?
    private var relayBridge: AgenTTYRelayBridge?
    private var activeRouteMode: AgenTTYResolvedConnectionRouteMode?
    private let connectionSignposter = OSSignposter(
        subsystem: "dev.tuist.agentty",
        category: .pointsOfInterest
    )
    private var connectionSignpost: (
        generation: Int,
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        startedAtNanoseconds: UInt64
    )?
    private let networkPathObserver = AgenTTYNetworkPathObserver()
    private var livenessProbeInFlight = false
    private var preReadyFailureCircuitBreaker = AgenTTYPreReadyFailureCircuitBreaker()
    private var hasNoHosts = false
    private var isShuttingDown = false
    private var isApplicationActive = true
    private var hasSizedSurface = false
    private var pendingStatusLines: [String] = []
    private var pendingNoHostsOnboarding = false
    private var didRenderNoHostsOnboarding = false
    private var lastRenderedNoHostsOnboardingSize: (columns: Int, rows: Int)?
    private var latestWindowSize: TerminalWindowSize?
    private var lastLoggedTerminalSize: (columns: Int, rows: Int)?
    private var renderCallCount = 0
    private var syntheticFocusRefreshRenderGeneration: UInt = 0
    private var didLogFirstKeyboardWrite = false
    private var isDirectionalPadCursorStyleActive = false
    private var tmuxShellSwipeInFlight = false
    private var queuedTmuxShellSwipes: [TerminalShellSwipeDirection] = []
    private var pendingShortcutShellCommands: [AgenTTYPendingShortcutShellCommand] = []
    private var shortcutShellCommandExecution: AgenTTYPendingShortcutShellCommand?
    private let maxTmuxShellCount = 10
    private var shellPollWorkItem: DispatchWorkItem?
    private var shellImmediatePollWorkItems: [DispatchWorkItem] = []
    private let initialShellPollDelay: TimeInterval = 0.5
    private let shellPollInterval: TimeInterval = 1.0
    // Interactive tmux commands (polls, swipes, window selection) fail fast so a
    // silently dead transport escalates to a liveness probe within seconds; the
    // 20s one-off exec default would keep the UI pretending it is connected.
    private let interactiveTmuxCommandTimeout: TimeAmount = .seconds(5)
    // While backgrounded the indicators are invisible; slow polling doubles as a
    // lightweight keepalive without burning radio at the foreground cadence.
    private let backgroundShellPollInterval: TimeInterval = 15.0
    private let syntheticFocusRefreshFollowUpRenderDelay: TimeInterval = 0.08
    private let notificationsRefreshLeadTime: TimeInterval = 6 * 60 * 60
    private let minimumNotificationsRefreshDelay: TimeInterval = 60
    private let shellLineCountPollCadence = 4
    private var shellPollTicksSinceLineCountRefresh = 0
    // Ordinary shells use scrollback milestones. Agent windows use completed-turn milestones.
    private let shellTitleInitialGenerationLineThreshold = 25
    private let shellTitleSecondGenerationLineThreshold = 50
    private let shellTitleEarlyRefreshLineCutoff = 500
    private let shellTitleEarlyRefreshInterval = 100
    private let shellTitleFrequentRefreshLineCutoff = 1_000
    private let shellTitleFrequentRefreshInterval = 200
    private let shellTitleSteadyRefreshInterval = 400
    private let shellTitleContextLineLimit = 5_000
    private let minimumShellTitleCharacterLimit = 12
    private let maximumShellTitleCharacterLimit = 120
    private var shellTitleCharacterLimit = 40
    private let shellTitleGenerationProvider: AgenTTYLLMClient.Provider = .gemini
    private let shellTitleGenerationModel = "gemini-3.1-flash-lite"
    private let shellTitleAIEnabled = AgenTTYFeatureFlags.shellTitleAIEnabled
    private let shellTitlePersistenceDebounce: TimeInterval = 0.75
    private var shellTitlePersistWorkItem: DispatchWorkItem?
    private var shellTitleGenerationTasksByIdentity: [ShellTitleIdentity: Task<Void, Never>] = [:]
    private var shellTitleStatesByIdentity: [ShellTitleIdentity: ShellTitleState] = ShellTitlePersistence.loadStates()
    private var shellTitleObservationsByWindowID: [Int: ShellTitleObservation] = [:]
    private var lastPublishedShellStateSignature: ShellStateSignature?
    private let shellContextBranchRefreshInterval: TimeInterval = 3
    private var shellContextGitHeadByWorkingDirectory: [String: GitHeadResolution] = [:]
    private var shellContextLastLookupDateByWorkingDirectory: [String: Date] = [:]
    private var shellContextBranchLookupInFlight: ShellContextBranchLookupRequest?
    private var shellContextBranchLookupRequestSequence = 0
    private var lastPublishedActiveShellContextSignature: ActiveShellContextSignature?
    /// Serial queue for ghostty_surface_write_pty_output calls.
    /// CRITICAL: write_pty_output must NOT be called from main thread because it can
    /// block waiting for surface mailbox space, and the main thread is the consumer
    /// of that mailbox — calling from main = self-deadlock.
    private nonisolated let terminalIOQueue = DispatchQueue(label: "dev.tuist.agentty.terminal-io", qos: .userInteractive)
    private nonisolated let terminalInboundDataRouter = TerminalInboundDataRouter()
    var shellStateDidChange: ((_ windowCount: Int, _ activePosition: Int, _ windowIds: [Int]) -> Void)?
    var shellTitleDidChange: ((_ windowID: Int, _ title: String) -> Void)?
    var shellWorkingDirectoryDidChange: ((_ windowID: Int, _ workingDirectoryPath: String) -> Void)?
    var activeShellContextDidChange: ((_ windowID: Int, _ workingDirectoryPath: String, _ branchName: String?) -> Void)?
    var shellTitleGenerationDidFail: ((_ error: String) -> Void)?
    var terminalDataDidUpdate: (() -> Void)?
    var tmuxShellSwipeDidComplete: ((_ didApplyCanonicalState: Bool) -> Void)?
    var hostConnectionPhaseDidChange: ((_ phase: AgenTTYHostConnectionPhase) -> Void)?
    var hostConnectionMethodDidChange: ((_ method: AgenTTYHostConnectionMethod?) -> Void)?
    var connectionRecoveryRequestDidChange: ((_ request: AgenTTYConnectionRecoveryRequest?) -> Void)?
    private var apnsTokenDidChangeObserver: NSObjectProtocol?
    private var analyticsSSHSession: AgenTTYAnalyticsSSHSession?
    private(set) var hostConnectionPhase: AgenTTYHostConnectionPhase = .disconnected
    private(set) var hostConnectionMethod: AgenTTYHostConnectionMethod?
    private(set) var connectionRecoveryRequest: AgenTTYConnectionRecoveryRequest?

    init(
        runtime: GhosttyRuntime,
        surface: ghostty_surface_t,
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        passwordStore: AgenTTYSSHPasswordStore,
        hostStore: AgenTTYHostStore,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        analyticsClient: AgenTTYAnalyticsClient
    ) {
        self.runtime = runtime
        unsafe self.surface = surface
        self.keyMaterialStore = keyMaterialStore
        self.passwordStore = passwordStore
        self.hostStore = hostStore
        self.trustedHostKeyStore = trustedHostKeyStore
        self.analyticsClient = analyticsClient
        terminalInboundDataRouter.updateSurfaceBits(UInt(bitPattern: surface))
        reconnectScreen.writeOutput = { [weak self] data, source in
            self?.injectTerminalOutputLocally(data, source: source)
        }
        apnsTokenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .agenttyAPNsTokenDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleNotificationsProvisioning(generation: self.connectionGeneration)
            }
        }
        networkPathObserver.pathDidChange = { [weak self] isSatisfied in
            self?.handleNetworkPathChange(isSatisfied: isSatisfied)
        }
        networkPathObserver.start()
        EsmaLog.terminal.info("bridge init")
        if !shellTitleAIEnabled {
            EsmaLog.terminal.notice(
                "shell title generation disabled by \(AgenTTYFeatureFlags.shellTitleAIEnvironmentKey, privacy: .public)"
            )
        }
    }

    isolated deinit {
        isShuttingDown = true
        terminalInboundDataRouter.updateConnection(generation: connectionGeneration, acceptingData: false)
        terminalInboundDataRouter.setSwipeNotifyActive(false)
        networkPathObserver.stop()
        reconnectScreen.invalidate()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        notificationsProvisionTask?.cancel()
        notificationsProvisionTask = nil
        notificationsRefreshTask?.cancel()
        notificationsRefreshTask = nil
        relayConnectorMaintenanceTask?.cancel()
        relayConnectorMaintenanceTask = nil
        endConnectionDiagnostics(outcome: "bridge_deinit")
#if os(iOS)
        endBackgroundWarmHoldIfNeeded(reason: "bridge_deinit")
#endif
        if let apnsTokenDidChangeObserver {
            NotificationCenter.default.removeObserver(apnsTokenDidChangeObserver)
            self.apnsTokenDidChangeObserver = nil
        }
        connectPreflightTask?.cancel()
        connectPreflightTask = nil
        shellTitlePersistWorkItem?.cancel()
        shellTitlePersistWorkItem = nil
        cancelShellPolling()
        cancelShellTitleGenerationTasks()
        persistShellTitleStates()
        EsmaLog.terminal.info("bridge deinit")
        ssh?.close()
        ssh = nil
    }

    func updateWindowSize(columns: Int, rows: Int, widthPx: Int, heightPx: Int) {
        let windowSize = TerminalWindowSize(columns: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)
        latestWindowSize = windowSize
        forwardWindowSizeToSSH(windowSize)
        if lastLoggedTerminalSize?.columns != windowSize.columns || lastLoggedTerminalSize?.rows != windowSize.rows {
            lastLoggedTerminalSize = (windowSize.columns, windowSize.rows)
            EsmaLog.terminal.info(
                "size cols=\(windowSize.columns) rows=\(windowSize.rows) px=\(windowSize.widthPx)x\(windowSize.heightPx)"
            )
        }
        if !hasSizedSurface {
            hasSizedSurface = true
            EsmaLog.terminal.info("surface became size-ready")
            flushPendingStatusLines()
            flushPendingNoHostsOnboardingIfNeeded()
        }
        if hasNoHosts,
           didRenderNoHostsOnboarding,
           (lastRenderedNoHostsOnboardingSize?.columns != windowSize.columns ||
            lastRenderedNoHostsOnboardingSize?.rows != windowSize.rows) {
            emitNoHostsOnboardingIfNeeded(force: true, reason: "terminal size changed while host list is empty")
        }
        refreshReconnectScreen()
        if ssh == nil {
            maybeStartSSHConnection(reason: "surface became size-ready")
        }
        renderSurface(reason: "size update")
    }

    func setActiveHost(_ host: AgenTTYHost?) {
        discardPendingShortcutShellCommands(notFor: host?.id)
        let nextTarget = host?.connectionTarget
        if let currentTarget = activeConnectionTarget,
           let nextTarget,
           shouldAdoptConnectionTargetWithoutReconnect(current: currentTarget, next: nextTarget) {
            activeHost = host
            activeConnectionTarget = nextTarget
            return
        }
        guard nextTarget != activeConnectionTarget else {
            activeHost = host
            if nextTarget == nil {
                clearConnectionRecoveryRequest()
                preReadyFailureCircuitBreaker.reset()
                setHostConnectionPhase(.disconnected)
                emitNoHostsOnboardingIfNeeded(force: false, reason: "active host unchanged")
            }
            return
        }

        activeHost = host
        activeConnectionTarget = nextTarget
        reconnectAttempt = 0
        reconnectRetryDeadline = nil
        preReadyFailureCircuitBreaker.reset()
        clearConnectionRecoveryRequest()
        setHostConnectionMethod(nil)
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        guard nextTarget != nil else {
            setHostConnectionPhase(.disconnected)
            closeAndClearSSH()
            if hasNoHosts {
                emitNoHostsOnboardingIfNeeded(force: false, reason: "active host cleared while host list is empty")
            } else {
                emitStatusLine("[agentty] no active host selected")
            }
            return
        }

        setHostConnectionPhase(.connecting)
        maybeStartSSHConnection(reason: "active host changed")
    }

    func setHostAvailability(hasNoHosts: Bool) {
        guard self.hasNoHosts != hasNoHosts else { return }
        self.hasNoHosts = hasNoHosts

        if hasNoHosts {
            pendingNoHostsOnboarding = true
            didRenderNoHostsOnboarding = false
            lastRenderedNoHostsOnboardingSize = nil
            refreshReconnectScreen()
            emitNoHostsOnboardingIfNeeded(force: false, reason: "host list became empty")
            return
        }

        pendingNoHostsOnboarding = false
        didRenderNoHostsOnboarding = false
        lastRenderedNoHostsOnboardingSize = nil
        if activeConnectionTarget == nil {
            emitStatusLine("[agentty] no active host selected")
        }
    }

    func sendRawBytes(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        if !didLogFirstKeyboardWrite {
            didLogFirstKeyboardWrite = true
            EsmaLog.terminal.info("first keyboard write bytes=\(count)")
        }
        if analyticsSSHSession != nil {
            analyticsSSHSession?.hadTerminalInput = true
            analyticsSSHSession?.inputEventCount += 1
        }
        let data = unsafe Data(bytes: bytes, count: count)
        ssh?.send(data)
        scheduleImmediateShellPollingIfNeeded(for: data)
    }

    func setDirectionalPadCursorStyle(active: Bool) {
        guard active != isDirectionalPadCursorStyleActive else { return }
        isDirectionalPadCursorStyleActive = active
        let sequence = Self.cursorStyleControlSequence(isDirectionalPadActive: active)
        injectTerminalOutputLocally(
            sequence,
            source: active ? "dpad_cursor_active" : "dpad_cursor_restore"
        )
    }

    func sendSyntheticTerminalFocusRefresh(reason: String) {
        guard ssh != nil else {
            EsmaLog.terminal.debug(
                "skip synthetic focus-refresh event: ssh unavailable reason=\(reason, privacy: .public)"
            )
            return
        }
        let refreshReason = SyntheticFocusRefreshReason(rawReason: reason)
        if !Self.shouldApplyRenderBeforeFocusPulse(refreshReason) {
            emitSyntheticFocusPulse(reason: reason)
        }
        guard hasSizedSurface else { return }
        guard Self.shouldForceRenderAfterSyntheticFocusRefresh(refreshReason) else { return }
        performSyntheticFocusRefreshPass(
            refreshReason: refreshReason,
            rawReason: reason,
            passLabel: "pass1"
        )
        scheduleSyntheticFocusRefreshFollowUpRender(
            refreshReason: refreshReason,
            rawReason: reason
        )
    }

    func setShellTitleCharacterLimit(_ maxCharacters: Int) {
        let normalizedLimit = min(
            max(maxCharacters, minimumShellTitleCharacterLimit),
            maximumShellTitleCharacterLimit
        )
        guard normalizedLimit != shellTitleCharacterLimit else { return }
        shellTitleCharacterLimit = normalizedLimit
        trimPersistedShellTitles(to: normalizedLimit)
    }

    func insertDictationText(_ text: String, fallbackBytes: [UInt8]) {
        guard !text.isEmpty else { return }
        guard let ssh else {
            EsmaLog.terminal.error("dictation insert failed: ssh unavailable")
            sendFallbackBytes(fallbackBytes)
            return
        }

        ssh.insertTextViaTmux(text) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    EsmaLog.terminal.info("dictation inserted via tmux paste-buffer")
                    return
                }

                EsmaLog.terminal.error("dictation tmux insertion failed; falling back to raw bytes")
                self.sendFallbackBytes(fallbackBytes)
            }
        }
    }

    func insertClipboardText(_ text: String, fallbackBytes: [UInt8]) {
        guard !text.isEmpty else { return }
        guard let ssh else {
            EsmaLog.terminal.error("clipboard text insert failed: ssh unavailable")
            sendFallbackBytes(fallbackBytes)
            return
        }

        ssh.insertTextViaTmux(text) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    EsmaLog.terminal.info("clipboard text inserted via tmux paste-buffer bytes=\(text.utf8.count)")
                    return
                }

                EsmaLog.terminal.error("clipboard text insertion failed; falling back to key bytes")
                self.sendFallbackBytes(fallbackBytes)
            }
        }
    }

    private struct ClipboardImageUploadPlan: Sendable {
        let index: Int
        let data: Data
        let preferredExtension: String
        let remotePath: String
    }

    private struct ClipboardImageUploadResult: Sendable {
        let index: Int
        let remotePath: String
        let byteCount: Int
        let preferredExtension: String
        let success: Bool
    }

    private static let maximumConcurrentClipboardImageUploads = 2
    // Pace multi-image path pastes so terminal clients that collapse rapid
    // successive paste events still treat each remote path as a separate image.
    private static let clipboardImagePasteEventDelayNanosecondsValue: UInt64 = 500_000_000

    func insertClipboardImages(_ imagePayloads: [TerminalClipboardImagePayload], fallbackBytes: [UInt8]) {
        guard !imagePayloads.isEmpty else { return }
        guard let ssh else {
            EsmaLog.terminal.error("clipboard image insert failed: ssh unavailable")
            sendFallbackBytes(fallbackBytes)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            var uploadedCount = 0
            var failedCount = 0
            var nextResultIndex = 0
            var pendingResults: [Int: ClipboardImageUploadResult] = [:]
            let remotePathPasteEventDelayNanoseconds = Self.clipboardImagePasteEventDelayNanoseconds(
                forImageCount: imagePayloads.count
            )

            let uploadPlans = imagePayloads.enumerated().map { index, imagePayload in
                ClipboardImageUploadPlan(
                    index: index,
                    data: imagePayload.data,
                    preferredExtension: imagePayload.preferredExtension,
                    remotePath: Self.remoteClipboardImagePath(preferredExtension: imagePayload.preferredExtension)
                )
            }

            let uploadImage: @Sendable (ClipboardImageUploadPlan) async -> ClipboardImageUploadResult = { uploadPlan in
                guard !Task.isCancelled else {
                    return ClipboardImageUploadResult(
                        index: uploadPlan.index,
                        remotePath: uploadPlan.remotePath,
                        byteCount: uploadPlan.data.count,
                        preferredExtension: uploadPlan.preferredExtension,
                        success: false
                    )
                }

                let success = await ssh.writeRemoteFile(
                    uploadPlan.data,
                    remotePath: uploadPlan.remotePath,
                    executable: false
                )
                return ClipboardImageUploadResult(
                    index: uploadPlan.index,
                    remotePath: uploadPlan.remotePath,
                    byteCount: uploadPlan.data.count,
                    preferredExtension: uploadPlan.preferredExtension,
                    success: success
                )
            }

            await withTaskGroup(of: ClipboardImageUploadResult.self) { group in
                var nextUploadPlanIndex = 0
                let initialUploadCount = min(Self.maximumConcurrentClipboardImageUploads, uploadPlans.count)

                for _ in 0..<initialUploadCount {
                    let uploadPlan = uploadPlans[nextUploadPlanIndex]
                    nextUploadPlanIndex += 1
                    group.addTask {
                        await uploadImage(uploadPlan)
                    }
                }

                for await uploadResult in group {
                    if nextUploadPlanIndex < uploadPlans.count {
                        let uploadPlan = uploadPlans[nextUploadPlanIndex]
                        nextUploadPlanIndex += 1
                        group.addTask {
                            await uploadImage(uploadPlan)
                        }
                    }

                    pendingResults[uploadResult.index] = uploadResult

                    // Preserve clipboard order even when uploads finish out of order.
                    while let readyResult = pendingResults.removeValue(forKey: nextResultIndex) {
                        if readyResult.success {
                            ssh.send(Self.bracketedPasteData(for: readyResult.remotePath))
                            uploadedCount += 1
                            if let remotePathPasteEventDelayNanoseconds, nextResultIndex < uploadPlans.count - 1 {
                                try? await Task.sleep(nanoseconds: remotePathPasteEventDelayNanoseconds)
                            }
                            EsmaLog.terminal.info(
                                "clipboard image uploaded bytes=\(readyResult.byteCount) remote_path=\(readyResult.remotePath, privacy: .public)"
                            )
                        } else {
                            failedCount += 1
                            EsmaLog.terminal.error(
                                "clipboard image upload failed extension=\(readyResult.preferredExtension, privacy: .public)"
                            )
                        }
                        nextResultIndex += 1
                    }
                }
            }

            guard uploadedCount > 0 else {
                EsmaLog.terminal.error("clipboard image batch upload failed count=\(failedCount)")
                self.sendFallbackBytes(fallbackBytes)
                return
            }

            EsmaLog.terminal.info(
                "clipboard image batch pasted uploaded=\(uploadedCount) failed=\(failedCount)"
            )
        }
    }

    func insertClipboardFiles(_ fileProviders: [any TerminalClipboardItemProvider], fallbackBytes: [UInt8]) {
        guard !fileProviders.isEmpty else { return }
        guard let ssh else {
            EsmaLog.terminal.error("clipboard file insert failed: ssh unavailable")
            sendFallbackBytes(fallbackBytes)
            return
        }

        let generation = connectionGeneration
        let activeSSH = ssh
        clipboardFileInsertTask?.cancel()
        clipboardFileInsertTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var uploadedRemotePaths: [String] = []
            uploadedRemotePaths.reserveCapacity(fileProviders.count)
            var failedCount = 0

            for fileProvider in fileProviders {
                guard !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.ssh === activeSSH else {
                    EsmaLog.terminal.notice("clipboard file batch canceled before upload")
                    return
                }

                guard let filePayload = await fileProvider.loadFilePayload() else {
                    failedCount += 1
                    continue
                }

                guard !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.ssh === activeSSH else {
                    TerminalClipboard.removeTemporaryFile(at: filePayload.localFileURL)
                    EsmaLog.terminal.notice("clipboard file batch canceled after local file resolution")
                    return
                }

                let remotePath = filePayload.makeRemotePath()
                let didUpload = await activeSSH.writeRemoteFile(
                    from: filePayload.localFileURL,
                    remotePath: remotePath,
                    executable: false
                )
                guard !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.ssh === activeSSH else {
                    TerminalClipboard.removeTemporaryFile(at: filePayload.localFileURL)
                    EsmaLog.terminal.notice("clipboard file batch canceled during upload")
                    return
                }
                TerminalClipboard.removeTemporaryFile(at: filePayload.localFileURL)

                if didUpload {
                    uploadedRemotePaths.append(remotePath)
                    EsmaLog.terminal.info(
                        "clipboard file uploaded bytes=\(filePayload.byteCount) remote_path=\(remotePath, privacy: .public)"
                    )
                } else {
                    failedCount += 1
                    EsmaLog.terminal.error(
                        "clipboard file upload failed filename=\(filePayload.filename, privacy: .public)"
                    )
                }
            }

            guard !uploadedRemotePaths.isEmpty else {
                EsmaLog.terminal.error("clipboard file batch upload failed count=\(failedCount)")
                guard self.connectionGeneration == generation,
                      self.ssh === activeSSH else {
                    return
                }
                self.sendFallbackBytes(fallbackBytes)
                return
            }

            guard !Task.isCancelled,
                  self.connectionGeneration == generation,
                  self.ssh === activeSSH else {
                EsmaLog.terminal.notice("clipboard file batch canceled before final paste")
                return
            }

            let pastedRemotePaths = uploadedRemotePaths.joined(separator: " ")
            activeSSH.send(Self.bracketedPasteData(for: pastedRemotePaths))
            EsmaLog.terminal.info(
                "clipboard file batch pasted uploaded=\(uploadedRemotePaths.count) failed=\(failedCount)"
            )
        }
    }

    func captureActiveTmuxPaneTail(maxLines: Int) async -> String? {
        guard maxLines > 0 else { return nil }
        guard let ssh else {
            EsmaLog.terminal.error("dictation context capture failed: ssh unavailable")
            return nil
        }

        let command = Self.tmuxCapturePaneTailCommand(maxLines: maxLines)
        return await withCheckedContinuation { continuation in
            ssh.runTmuxCommand(command) { success, output in
                DispatchQueue.main.async {
                    guard success else {
                        EsmaLog.terminal.error("dictation context capture failed: tmux command failed")
                        continuation.resume(returning: nil)
                        return
                    }

                    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedOutput.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: trimmedOutput)
                }
            }
        }
    }

    @discardableResult
    func navigateTmuxShell(_ direction: TerminalShellSwipeDirection) -> Bool {
        guard let ssh else {
            EsmaLog.terminal.error("cannot swipe tmux shells: ssh unavailable")
            return false
        }

        queuedTmuxShellSwipes.append(direction)
        processQueuedTmuxShellSwipeIfNeeded(using: ssh)
        return true
    }

    private func processQueuedTmuxShellSwipeIfNeeded(using ssh: SSHClientSession? = nil) {
        guard !tmuxShellSwipeInFlight else { return }

        guard let ssh = ssh ?? self.ssh else {
            if !queuedTmuxShellSwipes.isEmpty {
                EsmaLog.terminal.error("dropping queued tmux shell swipes: ssh unavailable")
                let droppedSwipeCount = queuedTmuxShellSwipes.count
                queuedTmuxShellSwipes.removeAll(keepingCapacity: false)
                for _ in 0..<droppedSwipeCount {
                    tmuxShellSwipeDidComplete?(false)
                }
            }
            return
        }

        guard !queuedTmuxShellSwipes.isEmpty else { return }

        let direction = queuedTmuxShellSwipes.removeFirst()
        tmuxShellSwipeInFlight = true
        terminalInboundDataRouter.setSwipeNotifyActive(true)
        let command = Self.tmuxShellSwipeCommand(
            direction: direction,
            maxShellCount: maxTmuxShellCount,
            reuseRightmostWorkingDirectory: NewShellWorkingDirectorySetting.persistedValue()
        )

        ssh.runTmuxCommand(command, timeout: interactiveTmuxCommandTimeout) { [weak self] success, output in
            DispatchQueue.main.async {
                self?.handleTmuxShellSwipeCommandResult(
                    direction: direction,
                    success: success,
                    output: output
                )
            }
        }
    }

    private func finishTmuxShellSwipe(shouldPollShellState: Bool) {
        tmuxShellSwipeInFlight = false
        terminalInboundDataRouter.setSwipeNotifyActive(false)
        let hasPendingSwipe = !queuedTmuxShellSwipes.isEmpty

        processQueuedTmuxShellSwipeIfNeeded()

        if shouldPollShellState, !hasPendingSwipe {
            pollShellState(includeLineCounts: false)
        }
    }

    private func maybeStartSSHConnection(reason: String) {
        guard activeConnectionTarget != nil else { return }
        guard latestWindowSize != nil else {
            EsmaLog.terminal.info("deferring ssh connect until terminal size is available reason=\(reason, privacy: .public)")
            emitStatusLine("[agentty] waiting for terminal size before ssh connect...")
            return
        }
        startSSHConnection(reason: reason)
    }

    private func startSSHConnection(reason: String) {
        guard !isShuttingDown else { return }
        guard let activeConnectionTarget else {
            return
        }
        guard let activeHost else {
            return
        }
        guard let latestWindowSize else {
            preconditionFailure("terminal size must be known before starting SSH connection")
        }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        connectionGeneration += 1
        let generation = connectionGeneration
        let connectionTarget = activeConnectionTarget
        terminalInboundDataRouter.updateConnection(generation: generation, acceptingData: false)
        terminalInboundDataRouter.setSwipeNotifyActive(false)

        closeAndClearSSH()
        activeRouteMode = nil
        reconnectRetryDeadline = nil
        clearConnectionRecoveryRequest()
        setHostConnectionMethod(nil)
        setHostConnectionPhase(.connecting)
        // The phase may already have been `.connecting` through backoff, so the
        // screen still needs to learn that the countdown is over.
        refreshReconnectScreen()
        beginConnectionDiagnostics(generation: generation, reason: reason)

        emitStatusLine(
            "[agentty] connecting to \(connectionTarget.username)@\(connectionTarget.host):\(connectionTarget.port) (tmux: \(AgenTTYConnection.tmuxSessionName))..."
        )
        EsmaLog.terminal.info(
            "starting ssh generation=\(generation) reason=\(reason, privacy: .public) host=\(connectionTarget.host, privacy: .public)"
        )

        connectPreflightTask?.cancel()
        connectPreflightTask = Task { [weak self] in
            guard let self else { return }

            do {
                let userAuthentication = try await AgenTTYSSHUserAuthenticationResolver.resolve(
                    keyMaterialStore: self.keyMaterialStore,
                    passwordStore: self.passwordStore,
                    connectionTarget: connectionTarget
                )
                let resolvedRoute = try await AgenTTYConnectionRouteResolver.resolve(for: activeHost)
                try Task.checkCancellation()

                guard self.connectionGeneration == generation,
                      self.activeConnectionTarget == connectionTarget,
                      self.activeHost?.id == activeHost.id,
                      !self.isShuttingDown else {
                    resolvedRoute.bridge?.close()
                    return
                }

                self.relayBridge = resolvedRoute.bridge
                self.activeRouteMode = resolvedRoute.mode
                self.recordResolvedRoute(resolvedRoute.mode, generation: generation)
                switch resolvedRoute.mode {
                case .relay:
                    self.setHostConnectionMethod(.relay)
                    self.emitStatusLine("[agentty] direct path unavailable; using secure relay")
                case .direct:
                    // Do not hold up SSH on hostname classification. The saved
                    // address gives us an immediate best answer; refine it in
                    // parallel after the real connection has started.
                    self.setHostConnectionMethod(.directMethod(for: activeHost))
                }
                self.startSSHSession(
                    connectionTarget: resolvedRoute.connectionTarget,
                    userAuthentication: userAuthentication,
                    windowSize: latestWindowSize,
                    generation: generation
                )
                if resolvedRoute.mode == .direct,
                   let refinedDirectMethod = await AgenTTYHostConnectionMethodResolver.resolveDirectMethod(
                       for: activeHost
                   ),
                   !Task.isCancelled,
                   self.connectionGeneration == generation,
                   self.activeRouteMode == .direct {
                    self.setHostConnectionMethod(refinedDirectMethod)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.endConnectionDiagnostics(generation: generation, outcome: "preflight_failed")
                self.setHostConnectionMethod(nil)
                EsmaLog.terminal.error(
                    "connection preflight failed host=\(connectionTarget.host, privacy: .public) auth=\(Self.logDescription(for: connectionTarget.authentication), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )

                // Transient network/relay errors must keep the normal reconnect
                // loop alive; only configuration-class failures stop retrying.
                if Self.isTransientPreflightError(error), !self.isShuttingDown, self.activeConnectionTarget != nil {
                    self.emitStatusLine("[agentty] connection attempt failed: \(error.localizedDescription)")
                    if self.canPerformConnectionWorkNow {
                        self.setHostConnectionPhase(.connecting)
                        self.scheduleReconnect()
                    } else {
                        self.setHostConnectionPhase(.disconnected)
                        EsmaLog.terminal.info("deferring preflight retry until app becomes active")
                    }
                    return
                }

                self.setHostConnectionPhase(.disconnected)
                self.emitStatusLine("[agentty] connection blocked: \(error.localizedDescription)")
                AgenTTYSentryService.capture(
                    error: error,
                    context: "ssh_connection_preflight",
                    data: [
                        "host_id": connectionTarget.hostID.uuidString.lowercased(),
                        "authentication": Self.logDescription(for: connectionTarget.authentication),
                    ]
                )
            }
        }
    }

    /// Errors that the network can fix on its own (roaming, flaky cellular,
    /// relay hiccups). Configuration-class failures — bad keys, missing relay
    /// setup, rejected device identity — still block reconnect until fixed.
    private static func isTransientPreflightError(_ error: Error) -> Bool {
        if error is AgenTTYHostReachabilityError {
            return true
        }
        if let relayError = error as? AgenTTYSSHRelayError {
            switch relayError {
            case .invalidRelayHostID, .unauthorized, .resourceLimit:
                return false
            case .invalidResponse, .relayConnectorOffline, .unexpectedStatusCode,
                 .websocketOpenTimedOut:
                return true
            }
        }
        if error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
    }

    private var canPerformConnectionWorkNow: Bool {
        isApplicationActive
    }

    private func handleNetworkPathChange(isSatisfied: Bool) {
        AgenTTYConnectionRouteResolver.invalidateRouteMemory()
        guard !isShuttingDown, activeConnectionTarget != nil, isSatisfied else { return }

        if reconnectWorkItem != nil, canPerformConnectionWorkNow {
            EsmaLog.terminal.info("network path changed; firing pending reconnect immediately")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
            maybeStartSSHConnection(reason: "network path changed")
            return
        }

        if hostConnectionPhase == .connected {
            verifyTransportLiveness(reason: "network path changed")
        }
    }

    /// Probes the live transport end-to-end and reconnects when it is silently
    /// dead (typical after Wi-Fi <-> cellular transitions: the socket buffers
    /// writes for minutes before TCP gives up while the UI looks connected).
    func verifyTransportLiveness(reason: String) {
        guard !isShuttingDown, let ssh, hostConnectionPhase == .connected else { return }
        guard !livenessProbeInFlight else { return }
        livenessProbeInFlight = true
        let generation = connectionGeneration
        EsmaLog.terminal.info("verifying transport liveness reason=\(reason, privacy: .public)")

        ssh.runLivenessProbe { [weak self] isAlive in
            DispatchQueue.main.async {
                guard let self else { return }
                self.livenessProbeInFlight = false
                guard self.connectionGeneration == generation, !self.isShuttingDown else { return }
                if isAlive {
                    EsmaLog.terminal.info(
                        "transport liveness confirmed reason=\(reason, privacy: .public)"
                    )
                    return
                }

                EsmaLog.terminal.error(
                    "transport liveness probe failed; reconnecting reason=\(reason, privacy: .public)"
                )
                self.emitStatusLine("[agentty] connection unresponsive; reconnecting...")
                self.reconnectAttempt = 0
                self.maybeStartSSHConnection(reason: "liveness probe failed (\(reason))")
            }
        }
    }

    private func startSSHSession(
        connectionTarget: AgenTTYConnectionTarget,
        userAuthentication: AgenTTYSSHUserAuthentication,
        windowSize: TerminalWindowSize,
        generation: Int
    ) {
        beginAnalyticsSSHSession(connectionTarget: connectionTarget, generation: generation)
        terminalInboundDataRouter.updateConnection(generation: generation, acceptingData: true)
        let inboundDataRouter = terminalInboundDataRouter
        let ioQueue = terminalIOQueue
        let session = SSHClientSession(
            connectionTarget: connectionTarget,
            userAuthentication: userAuthentication,
            trustedHostKeyStore: trustedHostKeyStore,
            preShellProvisioner: { [weak self] ssh in
                guard let self else { return }
                try await self.runPasswordBootstrapIfNeeded(
                    ssh: ssh,
                    connectionTarget: connectionTarget,
                    generation: generation
                )
                try await AgenTTYHostRuntimeProvisioner.prepareBaseRuntime(ssh: ssh)
            },
            outputHandler: { [weak self] data in
                inboundDataRouter.routeRemoteData(
                    data,
                    generation: generation,
                    source: "ssh",
                    terminalIOQueue: ioQueue
                ) { [weak self] in
                    DispatchQueue.main.async {
                        self?.terminalDataDidUpdate?()
                    }
                }
            },
            readyHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.handleReady(generation: generation)
                }
            },
            disconnectHandler: { [weak self] outcome in
                NSLog("ssh disconnected: %@", outcome.rawReason)
                DispatchQueue.main.async {
                    self?.handleDisconnect(
                        outcome: outcome,
                        generation: generation,
                        connectionTarget: connectionTarget
                    )
                }
            }
        )
        ssh = session
        session.updateWindowSize(
            columns: windowSize.columns,
            rows: windowSize.rows,
            widthPx: windowSize.widthPx,
            heightPx: windowSize.heightPx
        )
        session.connect()
    }

    private func handleReady(generation: Int) {
        guard connectionGeneration == generation else { return }
        reconnectAttempt = 0
        preReadyFailureCircuitBreaker.reset()
        if activeRouteMode == .direct, let hostID = activeConnectionTarget?.hostID {
            AgenTTYConnectionRouteResolver.recordDirectRouteSuccess(for: hostID)
        }
        clearConnectionRecoveryRequest()
        lastPublishedShellStateSignature = nil
        lastPublishedActiveShellContextSignature = nil
        setHostConnectionPhase(.connected)
        markAnalyticsSSHSessionReady(generation: generation)
        if AgenTTYSSHSeedPolicy.isScreenshotMode {
            renderScreenshotFixture()
            EsmaLog.terminal.info("ssh generation=\(generation) connected in screenshot mode")
            endConnectionDiagnostics(generation: generation, outcome: "ready")
            return
        }
        emitStatusLine("[agentty] ssh connected (tmux session: \(AgenTTYConnection.tmuxSessionName))")
        EsmaLog.terminal.info("ssh generation=\(generation) connected")
        let diagnosticData = connectionDiagnosticData(generation: generation)
        endConnectionDiagnostics(generation: generation, outcome: "ready")
        AgenTTYSentryService.addBreadcrumb(
            message: "SSH connection ready",
            category: "ssh.connection",
            level: "info",
            data: diagnosticData
        )
        startShellPolling()
        processPendingShortcutShellCommands()
        scheduleNotificationsProvisioning(generation: generation)
        scheduleRelayConnectorMaintenance(generation: generation)
    }

    private func scheduleRelayConnectorMaintenance(generation: Int) {
        relayConnectorMaintenanceTask?.cancel()
        relayConnectorMaintenanceTask = nil
        // Only the main flavor owns immutable, release-matched connector
        // upgrades. Dev/exp follow the mutable latest runtime channel and must
        // not make a shared host oscillate between development and release
        // binaries when both apps are used.
        guard AgenTTYBuildFlavor.current() == .main,
              activeRouteMode == .direct,
              activeHost?.connectionRoutePolicy == .directThenRelay,
              activeHost?.relayHostID?.isEmpty == false,
              let ssh else { return }

        relayConnectorMaintenanceTask = Task { [weak self] in
            do {
                let updated = try await AgenTTYHostRuntimeProvisioner.refreshRelayConnectorIfNeeded(
                    ssh: ssh
                )
                guard let self,
                      !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.activeRouteMode == .direct else { return }
                if updated {
                    AgenTTYSentryService.addBreadcrumb(
                        message: "Relay connector refreshed",
                        category: "ssh.relay_connector",
                        level: "info",
                        data: ["generation": String(generation)]
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.connectionGeneration == generation else { return }
                EsmaLog.terminal.error(
                    "relay connector maintenance failed generation=\(generation) error=\(String(describing: error), privacy: .public)"
                )
                AgenTTYSentryService.addBreadcrumb(
                    message: "Relay connector maintenance failed",
                    category: "ssh.relay_connector",
                    level: "warning",
                    data: [
                        "generation": String(generation),
                        "error_type": String(reflecting: type(of: error)),
                    ]
                )
            }
        }
    }

    private func scheduleNotificationsProvisioning(generation: Int) {
        notificationsProvisionTask?.cancel()
        notificationsRefreshTask?.cancel()
        notificationsRefreshTask = nil
        notificationsProvisionTask = Task { [weak self] in
            await self?.configureNotifications(generation: generation)
        }
    }

    private func configureNotifications(generation: Int) async {
        guard connectionGeneration == generation,
              let ssh,
              let connectionTarget = activeConnectionTarget else { return }

        EsmaLog.notifications.notice(
            "event=provision_start generation=\(generation) host=\(connectionTarget.host, privacy: .public)"
        )

        do {
            guard let relaySession = try await AgenTTYNotifyRelayClient.shared.issueRelaySession() else {
                emitStatusLine("[agentty] notifications unavailable (push not ready)")
                EsmaLog.notifications.notice(
                    "event=provision_skip generation=\(generation) reason=push_not_ready"
                )
                return
            }

            let result = try await AgenTTYNotificationHostProvisioner.provision(
                ssh: ssh,
                relaySession: relaySession
            )

            guard !Task.isCancelled, connectionGeneration == generation else { return }
            scheduleNotificationsRefresh(
                expiresAtEpochSeconds: relaySession.expiresAtEpochSeconds,
                generation: generation
            )
            EsmaLog.notifications.notice(
                "event=provision_success generation=\(generation) claude_installed=\(result.claudeInstalled) codex_installed=\(result.codexInstalled) expires_at=\(relaySession.expiresAtEpochSeconds)"
            )
        } catch {
            guard !Task.isCancelled, connectionGeneration == generation else { return }
            emitStatusLine("[agentty] notifications unavailable")
            EsmaLog.notifications.error(
                "event=provision_failure generation=\(generation) error=\(String(describing: error), privacy: .public)"
            )
            AgenTTYSentryService.capture(
                error: error,
                context: "notification_provisioning",
                data: [
                    "generation": String(generation),
                    "host": connectionTarget.host,
                ]
            )
        }
    }

    private func scheduleNotificationsRefresh(expiresAtEpochSeconds: Int, generation: Int) {
        notificationsRefreshTask?.cancel()

        let now = Date().timeIntervalSince1970
        let refreshDelay = max(
            minimumNotificationsRefreshDelay,
            TimeInterval(expiresAtEpochSeconds) - now - notificationsRefreshLeadTime
        )
        notificationsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(refreshDelay))
            guard !Task.isCancelled else { return }
            await self?.configureNotifications(generation: generation)
        }
        EsmaLog.notifications.notice(
            "event=provision_refresh_scheduled generation=\(generation) refresh_in_seconds=\(Int(refreshDelay))"
        )
    }

    private func handleDisconnect(
        outcome: AgenTTYSSHTerminationOutcome,
        generation: Int,
        connectionTarget: AgenTTYConnectionTarget
    ) {
        guard connectionGeneration == generation else { return }
        endAnalyticsSSHSessionIfNeeded(outcome: outcome, generation: generation)

        // A direct-route connection that died from a network-class failure before
        // becoming ready means the direct path is suspect: forget the cached
        // route so the next attempt re-probes (and can fall back to relay).
        if !outcome.wasReady,
           activeRouteMode == .direct,
           !AgenTTYPreReadyFailureCircuitBreaker.countsTowardTrip(outcome.category) {
            AgenTTYConnectionRouteResolver.recordDirectRouteFailure(for: connectionTarget.hostID)
        }

        let diagnosticData = connectionDiagnosticData(
            generation: generation,
            outcome: outcome
        )
        endConnectionDiagnostics(generation: generation, outcome: "disconnected")
        clearTransportState()
        endBackgroundWarmHoldIfNeeded(reason: "transport_disconnected")

        let shouldTripCircuitBreaker = !outcome.wasReady
            && outcome.shouldReconnect
            && preReadyFailureCircuitBreaker.recordFailure(
                hostID: connectionTarget.hostID,
                authMode: Self.analyticsAuthMode(for: connectionTarget.authentication),
                category: outcome.category,
                at: Date()
            )
        let shouldPresentRecovery = !outcome.wasReady && (!outcome.shouldReconnect || shouldTripCircuitBreaker)
        let shouldReconnect = outcome.shouldReconnect && !shouldTripCircuitBreaker

        if shouldReconnect, !isShuttingDown, canPerformConnectionWorkNow, activeConnectionTarget != nil {
            setHostConnectionPhase(.connecting)
        } else {
            setHostConnectionPhase(.disconnected)
        }
        emitStatusLine("[agentty] disconnected: \(outcome.rawReason)")
        EsmaLog.terminal.error(
            "ssh generation=\(generation) disconnected reason=\(outcome.rawReason, privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "SSH connection disconnected",
            category: "ssh.connection",
            level: shouldPresentRecovery ? "error" : "warning",
            data: diagnosticData
        )

        guard !isShuttingDown else { return }
        if shouldPresentRecovery {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            setConnectionRecoveryRequest(
                AgenTTYConnectionRecoveryRequest(hostID: connectionTarget.hostID, outcome: outcome)
            )
            emitStatusLine("[agentty] connection needs attention before retrying")
            AgenTTYSentryService.captureHandledError(
                message: "SSH connection requires manual recovery",
                context: "ssh_connection_recovery",
                data: diagnosticData
            )
            return
        }
        guard shouldReconnect else {
            emitStatusLine("[agentty] reconnect disabled until configuration is updated")
            return
        }
        guard canPerformConnectionWorkNow else {
            EsmaLog.terminal.info("deferring reconnect until app becomes active")
            return
        }
        scheduleReconnect()
    }

    func handleApplicationWillResignActive() {
        isApplicationActive = false
        refreshReconnectScreen()
        applyConnectionLifecycleAction(
            AgenTTYConnectionLifecyclePolicy.action(
                for: .willResignActive,
                state: connectionLifecycleState()
            ),
            reason: "willResignActive"
        )
    }

    func handleApplicationDidEnterBackground() {
        isApplicationActive = false
        refreshReconnectScreen()
        applyConnectionLifecycleAction(
            AgenTTYConnectionLifecyclePolicy.action(
                for: .didEnterBackground,
                state: connectionLifecycleState()
            ),
            reason: "didEnterBackground"
        )
    }

    func handleApplicationDidBecomeActive() {
        isApplicationActive = true
        endBackgroundWarmHoldIfNeeded(reason: "didBecomeActive")
        refreshReconnectScreen()
        applyConnectionLifecycleAction(
            AgenTTYConnectionLifecyclePolicy.action(
                for: .didBecomeActive,
                state: connectionLifecycleState()
            ),
            reason: "app became active"
        )
        if hostConnectionPhase == .connected {
            pollShellState(includeLineCounts: false)
        }
    }

    private func applyConnectionLifecycleAction(_ action: AgenTTYConnectionLifecycleAction, reason: String) {
        switch action {
        case .none:
            return
        case .beginBackgroundWarmHold:
            beginBackgroundWarmHoldIfNeeded(reason: reason)
        case .reconnectActiveHost:
            reconnectAttempt = 0
            maybeStartSSHConnection(reason: reason)
        case .verifyTransportLiveness:
            verifyTransportLiveness(reason: reason)
        }
    }

    private func beginBackgroundWarmHoldIfNeeded(reason: String) {
#if os(iOS)
        guard backgroundWarmHoldTask == .invalid else {
            EsmaLog.terminal.info(
                "background warm hold already active reason=\(reason, privacy: .public) remaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)s"
            )
            return
        }
        let taskID = UIApplication.shared.beginBackgroundTask(
            withName: "AgenTTY SSH Warm Hold"
        ) { [weak self] in
            self?.handleBackgroundWarmHoldExpired()
        }
        guard taskID != .invalid else {
            EsmaLog.terminal.error(
                "failed to begin background warm hold reason=\(reason, privacy: .public)"
            )
            return
        }
        backgroundWarmHoldTask = taskID
        EsmaLog.terminal.info(
            "began background warm hold reason=\(reason, privacy: .public) remaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)s"
        )
#else
        _ = reason
#endif
    }

    private func endBackgroundWarmHoldIfNeeded(reason: String) {
#if os(iOS)
        guard backgroundWarmHoldTask != .invalid else { return }
        let taskID = backgroundWarmHoldTask
        backgroundWarmHoldTask = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        EsmaLog.terminal.info(
            "ended background warm hold reason=\(reason, privacy: .public)"
        )
#else
        _ = reason
#endif
    }

    private func handleBackgroundWarmHoldExpired() {
#if os(iOS)
        guard backgroundWarmHoldTask != .invalid else { return }
        EsmaLog.terminal.info(
            "background warm hold expired; leaving terminal connection state unchanged"
        )
        endBackgroundWarmHoldIfNeeded(reason: "expiration")
#endif
    }

    private func setHostConnectionPhase(_ phase: AgenTTYHostConnectionPhase) {
        guard hostConnectionPhase != phase else { return }
        hostConnectionPhase = phase
        hostConnectionPhaseDidChange?(phase)
        refreshReconnectScreen()
    }

    /// The in-terminal reconnect screen only owns the terminal while AgenTTY is
    /// retrying on its own. Manual recovery and permanently blocked states keep
    /// the recovery alert plus ordinary `[agentty]` status lines.
    private var reconnectScreenPhase: AgenTTYReconnectScreenPhase? {
        guard !AgenTTYSSHSeedPolicy.isScreenshotMode,
              !hasNoHosts,
              activeConnectionTarget != nil,
              connectionRecoveryRequest == nil,
              hostConnectionPhase == .connecting else {
            return nil
        }
        if let reconnectRetryDeadline, reconnectRetryDeadline.timeIntervalSinceNow > 0 {
            return .waitingToRetry(attempt: reconnectAttempt, retryAt: reconnectRetryDeadline)
        }
        return .connecting(attempt: reconnectAttempt)
    }

    private func refreshReconnectScreen() {
        reconnectScreen.update(
            AgenTTYReconnectScreenInput(
                phase: reconnectScreenPhase,
                hostLabel: activeHost?.label ?? "",
                columns: latestWindowSize?.columns ?? 0,
                rows: latestWindowSize?.rows ?? 0,
                isAnimating: isApplicationActive
            )
        )
    }

    private func setHostConnectionMethod(_ method: AgenTTYHostConnectionMethod?) {
        guard hostConnectionMethod != method else { return }
        hostConnectionMethod = method
        hostConnectionMethodDidChange?(method)
    }

    private func setConnectionRecoveryRequest(_ request: AgenTTYConnectionRecoveryRequest?) {
        guard connectionRecoveryRequest != request else { return }
        connectionRecoveryRequest = request
        connectionRecoveryRequestDidChange?(request)
        refreshReconnectScreen()
    }

    private func clearConnectionRecoveryRequest() {
        setConnectionRecoveryRequest(nil)
    }

    func dismissConnectionRecovery() {
        clearConnectionRecoveryRequest()
    }

    func retryConnectionRecovery() {
        preReadyFailureCircuitBreaker.reset()
        clearConnectionRecoveryRequest()
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        maybeStartSSHConnection(reason: "manual recovery retry")
    }

    private func scheduleReconnect() {
        guard activeConnectionTarget != nil else { return }
        reconnectAttempt += 1
        let delaySeconds = min(8, max(1, 1 << min(reconnectAttempt - 1, 3)))
        let attempt = reconnectAttempt

        emitStatusLine("[agentty] reconnecting in \(delaySeconds)s (attempt \(attempt))...")
        EsmaLog.terminal.info("scheduling reconnect attempt=\(attempt) delay=\(delaySeconds)s")
        reconnectRetryDeadline = Date().addingTimeInterval(TimeInterval(delaySeconds))
        refreshReconnectScreen()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.maybeStartSSHConnection(reason: "reconnect attempt \(attempt)")
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: work)
    }

    private func beginConnectionDiagnostics(generation: Int, reason: String) {
        endConnectionDiagnostics(outcome: "superseded")
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let id = connectionSignposter.makeSignpostID()
        let state = connectionSignposter.beginInterval("SSH Connection", id: id)
        connectionSignpost = (
            generation: generation,
            id: id,
            state: state,
            startedAtNanoseconds: startedAtNanoseconds
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "SSH connection started",
            category: "ssh.connection",
            level: "info",
            data: [
                "generation": String(generation),
                "reason": reason,
            ]
        )
    }

    private func recordResolvedRoute(
        _ routeMode: AgenTTYResolvedConnectionRouteMode,
        generation: Int
    ) {
        guard let connectionSignpost, connectionSignpost.generation == generation else { return }
        connectionSignposter.emitEvent("SSH Route Resolved", id: connectionSignpost.id)
        let route = routeMode == .direct ? "direct" : "relay"
        let elapsedMilliseconds = connectionElapsedMilliseconds(generation: generation)
        EsmaLog.terminal.info(
            "ssh route resolved generation=\(generation) route=\(route, privacy: .public) elapsed_ms=\(elapsedMilliseconds ?? 0)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "SSH route resolved",
            category: "ssh.connection",
            level: "info",
            data: [
                "generation": String(generation),
                "route": route,
                "elapsed_ms": String(elapsedMilliseconds ?? 0),
            ]
        )
    }

    private func endConnectionDiagnostics(generation: Int? = nil, outcome: String) {
        guard let connectionSignpost,
              generation == nil || connectionSignpost.generation == generation else { return }
        connectionSignposter.endInterval("SSH Connection", connectionSignpost.state)
        let elapsedMilliseconds = connectionElapsedMilliseconds(generation: connectionSignpost.generation)
        EsmaLog.terminal.info(
            "ssh connection interval ended generation=\(connectionSignpost.generation) outcome=\(outcome, privacy: .public) elapsed_ms=\(elapsedMilliseconds ?? 0)"
        )
        self.connectionSignpost = nil
    }

    private func connectionElapsedMilliseconds(generation: Int) -> UInt64? {
        guard let connectionSignpost,
              connectionSignpost.generation == generation else { return nil }
        return EsmaDiagnostics.elapsedMilliseconds(
            since: connectionSignpost.startedAtNanoseconds
        )
    }

    private func connectionDiagnosticData(
        generation: Int,
        outcome: AgenTTYSSHTerminationOutcome? = nil
    ) -> [String: String] {
        let route: String
        switch activeRouteMode {
        case .direct:
            route = "direct"
        case .relay:
            route = "relay"
        case nil:
            route = "unresolved"
        }
        var data = [
            "generation": String(generation),
            "route": route,
            "elapsed_ms": String(connectionElapsedMilliseconds(generation: generation) ?? 0),
        ]
        if let outcome {
            data["disconnect_category"] = outcome.category.analyticsValue.rawValue
            data["failure_stage"] = outcome.failureStage?.analyticsValue.rawValue ?? "none"
            data["was_ready"] = String(outcome.wasReady)
        }
        return data
    }

    private func closeAndClearSSH(localCloseReason: String = "local_close") {
        let wasReady = analyticsSSHSession?.wasReady ?? (hostConnectionPhase == .connected)
        endAnalyticsSSHSessionIfNeeded(
            outcome: AgenTTYSSHTerminationOutcome(
                category: .localClose,
                failureStage: wasReady ? .postReadySession : nil,
                rawReason: localCloseReason,
                wasReady: wasReady,
                shouldReconnect: false
            )
        )
        clearTransportState()
    }

    private func clearTransportState() {
        terminalInboundDataRouter.setAcceptingData(false)
        terminalInboundDataRouter.setSwipeNotifyActive(false)
        connectPreflightTask?.cancel()
        connectPreflightTask = nil
        clipboardFileInsertTask?.cancel()
        clipboardFileInsertTask = nil
        notificationsProvisionTask?.cancel()
        notificationsProvisionTask = nil
        notificationsRefreshTask?.cancel()
        notificationsRefreshTask = nil
        relayConnectorMaintenanceTask?.cancel()
        relayConnectorMaintenanceTask = nil
        endConnectionDiagnostics(outcome: "transport_cleared")
        if tmuxShellSwipeInFlight {
            tmuxShellSwipeDidComplete?(false)
        }
        if !queuedTmuxShellSwipes.isEmpty {
            let droppedSwipeCount = queuedTmuxShellSwipes.count
            for _ in 0..<droppedSwipeCount {
                tmuxShellSwipeDidComplete?(false)
            }
        }
        tmuxShellSwipeInFlight = false
        queuedTmuxShellSwipes.removeAll(keepingCapacity: false)
        if let shortcutShellCommandExecution {
            shortcutShellCommandExecution.completion(false)
            self.shortcutShellCommandExecution = nil
        }
        cancelShellPolling()
        cancelShellTitleGenerationTasks()
        lastPublishedShellStateSignature = nil
        lastPublishedActiveShellContextSignature = nil
        shellContextBranchLookupInFlight = nil
        setHostConnectionMethod(nil)
        ssh?.close()
        ssh = nil
        relayBridge?.close()
        relayBridge = nil
        activeRouteMode = nil
    }

    private func connectionLifecycleState() -> AgenTTYConnectionLifecycleState {
        AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: activeConnectionTarget != nil,
            hasLiveTransport: ssh != nil || relayBridge != nil,
            hasPendingConnectionWork: connectPreflightTask != nil || reconnectWorkItem != nil,
            hasRecoveryRequest: connectionRecoveryRequest != nil,
            isShuttingDown: isShuttingDown
        )
    }

    private func beginAnalyticsSSHSession(connectionTarget: AgenTTYConnectionTarget, generation: Int) {
        analyticsSSHSession = AgenTTYAnalyticsSSHSession(
            sessionID: UUID().uuidString.lowercased(),
            hostID: connectionTarget.hostID,
            generation: generation,
            startedAt: Date(),
            authMode: Self.analyticsAuthMode(for: connectionTarget.authentication),
            wasReady: false,
            hadTerminalInput: false,
            inputEventCount: 0
        )
    }

    private func markAnalyticsSSHSessionReady(generation: Int) {
        guard let current = analyticsSSHSession, current.generation == generation else { return }
        analyticsSSHSession?.wasReady = true
    }

    private func endAnalyticsSSHSessionIfNeeded(
        outcome: AgenTTYSSHTerminationOutcome,
        generation: Int? = nil
    ) {
        guard let current = analyticsSSHSession else { return }
        if let generation, current.generation != generation {
            return
        }

        analyticsSSHSession = nil
        let sessionDuration = Date().timeIntervalSince(current.startedAt)
        let analyticsClient = self.analyticsClient
        Task {
            await analyticsClient.recordSSHSessionCompleted(
                AgenTTYAnalyticsSSHSessionCompletedEvent(
                    sessionID: current.sessionID,
                    hostID: current.hostID,
                    duration: sessionDuration,
                    wasReady: current.wasReady,
                    disconnectCategory: outcome.category.analyticsValue,
                    disconnectReason: outcome.rawReason,
                    failureStage: outcome.failureStage?.analyticsValue
                        ?? (current.wasReady ? .postReadySession : nil),
                    hadTerminalInput: current.hadTerminalInput,
                    inputEventCount: current.inputEventCount,
                    authMode: current.authMode,
                    hostKeyHash: nil
                )
            )
        }
    }

    private func handleTmuxShellSwipeCommandResult(
        direction: TerminalShellSwipeDirection,
        success: Bool,
        output: String
    ) {
        let directionDescription = direction == .forward ? "forward" : "backward"
        let outputPreview = output
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")

        guard success else {
            EsmaLog.terminal.error(
                "tmux shell swipe failed direction=\(directionDescription, privacy: .public) output=\(outputPreview, privacy: .public)"
            )
            tmuxShellSwipeDidComplete?(false)
            terminalDataDidUpdate?()
            // Same escalation as a failed poll: a failed interactive command on
            // a "connected" transport probes, and probe failure reconnects.
            verifyTransportLiveness(reason: "shell swipe failed")
            finishTmuxShellSwipe(shouldPollShellState: true)
            return
        }

        let windows = Self.parseTmuxWindowStates(from: output)
        guard !windows.isEmpty else {
            EsmaLog.terminal.error(
                "tmux shell swipe failed direction=\(directionDescription, privacy: .public): command returned no windows"
            )
            tmuxShellSwipeDidComplete?(false)
            terminalDataDidUpdate?()
            finishTmuxShellSwipe(shouldPollShellState: true)
            return
        }

        let activePosition = windows.firstIndex(where: { $0.isActive }) ?? max(windows.count - 1, 0)
        publishShellState(from: windows)

        EsmaLog.terminal.info(
            "tmux shell swipe succeeded direction=\(directionDescription, privacy: .public) windows=\(windows.count) active_position=\(activePosition) output=\(outputPreview, privacy: .public)"
        )

        tmuxShellSwipeDidComplete?(true)

        // Ensures curtain fade can proceed even if inbound bytes landed
        // while tmuxShellSwipeInFlight was still true.
        terminalDataDidUpdate?()

        finishTmuxShellSwipe(shouldPollShellState: false)
    }

    func selectTmuxWindow(id windowId: Int) {
        guard let ssh else {
            EsmaLog.terminal.error("selectTmuxWindow failed: ssh unavailable")
            return
        }
        let command = Self.tmuxSelectWindowCommand(windowID: windowId)
        ssh.runTmuxCommand(command, timeout: interactiveTmuxCommandTimeout) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    EsmaLog.terminal.info("selectTmuxWindow succeeded windowId=\(windowId)")
                } else {
                    EsmaLog.terminal.error("selectTmuxWindow failed windowId=\(windowId)")
                    self.verifyTransportLiveness(reason: "select window failed")
                }
                self.pollShellState(includeLineCounts: false)
            }
        }
    }

    func createTmuxWindowAndSelect() {
        guard let ssh else {
            EsmaLog.terminal.error("createTmuxWindowAndSelect failed: ssh unavailable")
            return
        }

        ssh.runTmuxCommand(
            Self.tmuxCreateWindowAndSelectCommand(
                reuseRightmostWorkingDirectory: NewShellWorkingDirectorySetting.persistedValue()
            ),
            timeout: interactiveTmuxCommandTimeout
        ) { [weak self] success, output in
            DispatchQueue.main.async {
                guard let self else { return }
                guard success else {
                    EsmaLog.terminal.error("createTmuxWindowAndSelect failed")
                    self.verifyTransportLiveness(reason: "create window failed")
                    self.pollShellState(includeLineCounts: false)
                    return
                }

                let windows = Self.parseTmuxWindowStates(from: output)
                guard !windows.isEmpty else {
                    EsmaLog.terminal.error("createTmuxWindowAndSelect failed: command returned no windows")
                    self.pollShellState(includeLineCounts: false)
                    return
                }

                self.publishShellState(from: windows)
                self.pollShellState(includeLineCounts: false)
            }
        }
    }

    func enqueueShortcutShellCommand(
        requestID: UUID,
        hostID: UUID,
        command: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard shortcutShellCommandExecution?.requestID != requestID,
              !pendingShortcutShellCommands.contains(where: { $0.requestID == requestID }) else {
            return
        }
        pendingShortcutShellCommands.append(
            AgenTTYPendingShortcutShellCommand(
                requestID: requestID,
                hostID: hostID,
                command: command,
                completion: completion
            )
        )
        processPendingShortcutShellCommands()
    }

    private func processPendingShortcutShellCommands() {
        guard shortcutShellCommandExecution == nil,
              hostConnectionPhase == .connected,
              let ssh,
              let request = pendingShortcutShellCommands.first,
              activeConnectionTarget?.hostID == request.hostID else {
            return
        }

        pendingShortcutShellCommands.removeFirst()
        shortcutShellCommandExecution = request
        ssh.runTmuxCommand(
            Self.tmuxCreateWindowAndRunCommand(
                request.command,
                maxShellCount: maxTmuxShellCount,
                reuseRightmostWorkingDirectory: NewShellWorkingDirectorySetting.persistedValue()
            )
        ) { [weak self] success, output in
            DispatchQueue.main.async {
                guard let self,
                      self.shortcutShellCommandExecution?.requestID == request.requestID else {
                    return
                }
                self.shortcutShellCommandExecution = nil

                if success {
                    let windows = Self.parseTmuxWindowStates(from: output)
                    if windows.isEmpty {
                        EsmaLog.terminal.error(
                            "shortcut shell command succeeded without returning window state"
                        )
                        self.pollShellState(includeLineCounts: false)
                    } else {
                        self.publishShellState(from: windows)
                        self.pollShellState(includeLineCounts: false)
                    }
                    request.completion(true)
                } else {
                    EsmaLog.terminal.error(
                        "shortcut shell command failed host_id=\(request.hostID.uuidString, privacy: .public) output=\(output, privacy: .private(mask: .hash))"
                    )
                    self.emitStatusLine("[agentty] failed to start the shortcut command in a new shell")
                    self.pollShellState(includeLineCounts: false)
                    request.completion(false)
                }

                self.processPendingShortcutShellCommands()
            }
        }
    }

    private func discardPendingShortcutShellCommands(notFor hostID: UUID?) {
        let droppedCommands: [AgenTTYPendingShortcutShellCommand]
        if let hostID {
            droppedCommands = pendingShortcutShellCommands.filter { $0.hostID != hostID }
            pendingShortcutShellCommands.removeAll(where: { $0.hostID != hostID })
        } else {
            droppedCommands = pendingShortcutShellCommands
            pendingShortcutShellCommands.removeAll(keepingCapacity: false)
        }
        for command in droppedCommands {
            command.completion(false)
        }
        if !droppedCommands.isEmpty {
            EsmaLog.terminal.info(
                "dropped queued shortcut shell commands after host change count=\(droppedCommands.count)"
            )
        }
    }

    private func sendFallbackBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        ssh?.send(Data(bytes))
    }

    private static func remoteClipboardImagePath(preferredExtension: String) -> String {
        let filteredScalars = preferredExtension.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let ext = filteredScalars.isEmpty ? "png" : String(String.UnicodeScalarView(filteredScalars))
        return "/tmp/agentty-clipboard-\(UUID().uuidString).\(ext)"
    }

    static func clipboardImagePasteEventDelayNanoseconds(forImageCount imageCount: Int) -> UInt64? {
        guard imageCount > 1 else { return nil }
        return clipboardImagePasteEventDelayNanosecondsValue
    }

    private static func bracketedPasteData(for text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\u{1B}", with: "")
            .replacingOccurrences(of: "\u{00}", with: "")
        let payload = "\u{1B}[200~\(escaped)\u{1B}[201~"
        return Data(payload.utf8)
    }

    private static func cursorStyleControlSequence(isDirectionalPadActive: Bool) -> Data {
        // DECSCUSR (CSI Ps SP q): 2 = steady block, 5 = blinking bar.
        let sequence = isDirectionalPadActive ? "\u{1B}[2 q" : "\u{1B}[5 q"
        return Data(sequence.utf8)
    }

    private static let noHostsOnboardingLines = [
        "",
        " __        __   _                              _          ",
        " \\ \\      / /__| | ___ ___  _ __ ___   ___    | |_ ___    ",
        "  \\ \\ /\\ / / _ \\ |/ __/ _ \\| '_ ` _ \\ / _ \\   | __/ _ \\   ",
        "   \\ V  V /  __/ | (_| (_) | | | | | |  __/   | || (_) |  ",
        "    \\_/\\_/ \\___|_|\\___\\___/|_| |_| |_|\\___|    \\__\\___/   ",
        "",
        " █████   ██████  ███████ ███   ██ ████████ ████████ ██    ██",
        "██   ██ ██       ██      ████  ██    ██       ██     ██  ██ ",
        "███████ ██   ███ █████   ██ ██ ██    ██       ██      ████  ",
        "██   ██ ██    ██ ██      ██  ████    ██       ██       ██   ",
        "██   ██  ██████  ███████ ██   ███    ██       ██       ██   ",
        "",
        "Please add a host to get started.",
        "Tap the menu button in the top-left, then open Hosts."
    ]

    private static let terminalFocusLostSequence = Data("\u{1B}[O".utf8)
    private static let terminalFocusGainedSequence = Data("\u{1B}[I".utf8)

    private static func shouldForceRenderAfterSyntheticFocusRefresh(_ reason: SyntheticFocusRefreshReason) -> Bool {
        switch reason {
        case .themeChange, .didBecomeActive:
            true
        case .other:
            false
        }
    }

    private static func shouldApplyRenderBeforeFocusPulse(_ reason: SyntheticFocusRefreshReason) -> Bool {
        if case .themeChange = reason {
            return true
        }
        return false
    }

    private func injectTerminalOutputLocally(_ data: Data, source: String) {
        guard !data.isEmpty else { return }
        EsmaLog.terminal.debug(
            "inject local terminal output source=\(source, privacy: .public) bytes=\(data.count)"
        )

        let surfaceBits = unsafe UInt(bitPattern: self.surface)
        terminalIOQueue.async {
            guard let surface = unsafe UnsafeMutableRawPointer(bitPattern: surfaceBits) else { return }
            unsafe data.withUnsafeBytes { rawBuffer in
                guard let base = unsafe rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                unsafe ghostty_surface_write_pty_output(surface, base, UInt(data.count))
            }
        }
    }

    private func receiveRemoteData(_ data: Data, source: String) {
        injectTerminalOutputLocally(data, source: source)
    }

    private func emitStatusLine(_ line: String) {
        if !hasSizedSurface {
            pendingStatusLines.append(line)
            EsmaLog.terminal.debug("queued status line until surface ready: \(line, privacy: .public)")
            return
        }

        // The reconnect screen owns the whole terminal while it is up; letting
        // status lines through would scroll the centered block apart.
        if reconnectScreen.isPresenting {
            EsmaLog.terminal.info("status line (suppressed by reconnect screen): \(line, privacy: .public)")
            return
        }

        EsmaLog.terminal.info("status line: \(line, privacy: .public)")
        let text = "\u{1B}[0m\(line)\u{1B}[0m\r\n"
        guard let data = text.data(using: .utf8) else { return }
        receiveRemoteData(data, source: "status")
    }

    private func renderScreenshotFixture() {
        terminalInboundDataRouter.setAcceptingData(false)
        let lines = [
            "\u{1B}[2J\u{1B}[H",
            "\u{1B}[1;35m╭─ Claude Code ───────────────╮\u{1B}[0m",
            "\u{1B}[1;35m│\u{1B}[0m  AgenTTY release workspace    \u{1B}[1;35m│\u{1B}[0m",
            "\u{1B}[1;35m╰──────────────────────────────╯\u{1B}[0m",
            "",
            "\u{1B}[1;36m›\u{1B}[0m Finish the App Store release.",
            "",
            "\u{1B}[2m⏺ I’ll build and verify the full\u{1B}[0m",
            "\u{1B}[2m  iPhone + iPad screenshot flow.\u{1B}[0m",
            "",
            "\u{1B}[1;32m✓\u{1B}[0m Captured the production UI",
            "\u{1B}[1;32m✓\u{1B}[0m Framed official Apple devices",
            "\u{1B}[1;32m✓\u{1B}[0m Exported App Store artwork",
            "\u{1B}[1;32m✓\u{1B}[0m Verified every output size",
            "",
            "\u{1B}[1;34mReady for App Review.\u{1B}[0m",
            "",
            "\u{1B}[2m────────────────────────────────\u{1B}[0m",
            "\u{1B}[33mAgenTTY\u{1B}[0m  Claude Code & Codex anywhere",
        ]
        injectTerminalOutputLocally(
            Data(lines.joined(separator: "\r\n").utf8),
            source: "screenshot-fixture"
        )
        if let screen = AgenTTYScreenshotScreen.current {
            AgenTTYScreenshotReadySignal.markReady(screen)
        }
    }

    private func emitNoHostsOnboardingIfNeeded(force: Bool, reason: String) {
        guard hasNoHosts else { return }
        guard force || !didRenderNoHostsOnboarding else { return }

        guard hasSizedSurface else {
            pendingNoHostsOnboarding = true
            EsmaLog.terminal.debug(
                "queued no-host onboarding until surface ready reason=\(reason, privacy: .public)"
            )
            return
        }

        let columns = max(latestWindowSize?.columns ?? 80, 1)
        let rows = max(latestWindowSize?.rows ?? 24, 1)
        let centeredBlock = Self.centeredTextBlock(
            lines: Self.noHostsOnboardingLines,
            columns: columns,
            rows: rows
        )
        let onboardingText = "\u{1B}[2J\u{1B}[H\u{1B}[0m\(centeredBlock)\r\n\u{1B}[0m"
        guard let data = onboardingText.data(using: .utf8) else { return }

        pendingNoHostsOnboarding = false
        didRenderNoHostsOnboarding = true
        lastRenderedNoHostsOnboardingSize = (columns, rows)
        EsmaLog.terminal.info(
            "rendered no-host onboarding screen reason=\(reason, privacy: .public) cols=\(columns) rows=\(rows)"
        )
        receiveRemoteData(data, source: "onboarding")
    }

    private func flushPendingNoHostsOnboardingIfNeeded() {
        guard pendingNoHostsOnboarding else { return }
        emitNoHostsOnboardingIfNeeded(force: true, reason: "surface became size-ready")
    }

    private func flushPendingStatusLines() {
        guard !pendingStatusLines.isEmpty else { return }
        let queued = pendingStatusLines
        pendingStatusLines.removeAll(keepingCapacity: false)
        for line in queued {
            emitStatusLine(line)
        }
    }

    private static func centeredTextBlock(lines: [String], columns: Int, rows: Int) -> String {
        let availableColumns = max(columns, 1)
        let availableRows = max(rows, 1)
        let fittedLines = lines.map { line in
            if line.count <= availableColumns {
                return line
            }
            return String(line.prefix(availableColumns))
        }
        let topPaddingLineCount = max((availableRows - fittedLines.count) / 2, 0)
        let topPadding = String(repeating: "\r\n", count: topPaddingLineCount)
        let centeredLines = fittedLines.map { line -> String in
            let horizontalPadding = max((availableColumns - line.count) / 2, 0)
            return String(repeating: " ", count: horizontalPadding) + line
        }.joined(separator: "\r\n")
        return "\(topPadding)\(centeredLines)"
    }

    private func renderSurface(reason: String) {
        renderCallCount += 1
        if EsmaDiagnostics.shouldLog(counter: renderCallCount, defaultLimit: 4) {
            EsmaLog.terminal.info("render #\(self.renderCallCount) reason=\(reason, privacy: .public)")
        }
        unsafe runtime.render(surface: surface)
    }

    private func scheduleSyntheticFocusRefreshFollowUpRender(
        refreshReason: SyntheticFocusRefreshReason,
        rawReason: String
    ) {
        syntheticFocusRefreshRenderGeneration &+= 1
        let generation = syntheticFocusRefreshRenderGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + syntheticFocusRefreshFollowUpRenderDelay) { [weak self] in
            guard let self else { return }
            guard self.syntheticFocusRefreshRenderGeneration == generation else { return }
            guard self.hasSizedSurface, self.ssh != nil else { return }
            guard Self.shouldForceRenderAfterSyntheticFocusRefresh(refreshReason) else { return }
            self.performSyntheticFocusRefreshPass(
                refreshReason: refreshReason,
                rawReason: rawReason,
                passLabel: "pass2"
            )
        }
    }

    private func performSyntheticFocusRefreshPass(
        refreshReason: SyntheticFocusRefreshReason,
        rawReason: String,
        passLabel: String
    ) {
        if Self.shouldApplyRenderBeforeFocusPulse(refreshReason) {
            sendSyntheticWindowSizeRefresh(reason: "\(rawReason)-\(passLabel)-pre")
            renderSurface(reason: "focus-refresh:\(rawReason)-\(passLabel)-pre")
            emitSyntheticFocusPulse(reason: "\(rawReason)-\(passLabel)-post")
            return
        }

        sendSyntheticWindowSizeRefresh(reason: "\(rawReason)-\(passLabel)")
        renderSurface(reason: "focus-refresh:\(rawReason)-\(passLabel)")
    }

    private func emitSyntheticFocusPulse(reason: String) {
        // Focus bytes may only travel once the tmux attach is up. Bytes sent
        // while connecting are queued and flushed exactly when the bootstrap
        // starts, so an ESC[O can reach the tmux server's tty before the
        // attaching client has a session bound — tmux (through master) derefs
        // c->session->curw for focus events without a null check and the
        // whole server segfaults, killing every shell.
        guard hostConnectionPhase == .connected else {
            EsmaLog.terminal.debug(
                "skip synthetic focus-refresh pulse: not connected reason=\(reason, privacy: .public)"
            )
            return
        }
        EsmaLog.terminal.info(
            "sending synthetic focus-refresh pulse reason=\(reason, privacy: .public)"
        )
        ssh?.send(Self.terminalFocusLostSequence)
        ssh?.send(Self.terminalFocusGainedSequence)
    }

    private func sendSyntheticWindowSizeRefresh(reason: String) {
        guard let windowSize = latestWindowSize else {
            EsmaLog.terminal.debug(
                "skip synthetic window-size refresh: missing latest size reason=\(reason, privacy: .public)"
            )
            return
        }
        forwardWindowSizeToSSH(windowSize)
        EsmaLog.terminal.info(
            "sent synthetic window-size refresh reason=\(reason, privacy: .public) cols=\(windowSize.columns) rows=\(windowSize.rows)"
        )
    }

    private func shouldAdoptConnectionTargetWithoutReconnect(
        current: AgenTTYConnectionTarget,
        next: AgenTTYConnectionTarget
    ) -> Bool {
        guard ssh != nil else { return false }
        guard current.hostID == next.hostID,
              current.host == next.host,
              current.username == next.username,
              current.port == next.port else {
            return false
        }

        if case .passwordBootstrap(let currentTargetKeyID, _) = current.authentication,
           case .key(let nextKeyID) = next.authentication,
           currentTargetKeyID == nextKeyID {
            EsmaLog.terminal.info(
                "adopting converted key auth for live ssh session host=\(next.host, privacy: .public)"
            )
            return true
        }

        return false
    }

    private func forwardWindowSizeToSSH(_ windowSize: TerminalWindowSize) {
        ssh?.updateWindowSize(
            columns: windowSize.columns,
            rows: windowSize.rows,
            widthPx: windowSize.widthPx,
            heightPx: windowSize.heightPx
        )
    }

    @concurrent
    nonisolated private static func loadPrivateKeyMaterial(
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        keyID: UUID
    ) async throws -> AgenTTYStoredSSHPrivateKey {
        try keyMaterialStore.loadMaterial(for: keyID)
    }

    private func runPasswordBootstrapIfNeeded(
        ssh: SSHClientSession,
        connectionTarget: AgenTTYConnectionTarget,
        generation: Int
    ) async throws {
        guard case .passwordBootstrap(let targetKeyID, let credentialID) = connectionTarget.authentication else {
            return
        }

        let targetKeyMaterial = try await Self.loadPrivateKeyMaterial(
            keyMaterialStore: keyMaterialStore,
            keyID: targetKeyID
        )
        let publicKey = try targetKeyMaterial.openSSHPublicKey()
        let command = AgenTTYSSHAuthorizedKeysInstaller.installPublicKeyCommand(publicKey: publicKey)
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        guard success else {
            throw AgenTTYPasswordBootstrapError.keyInstallFailed(output)
        }

        guard connectionGeneration == generation else {
            return
        }

        _ = hostStore.updateHostAuthentication(id: connectionTarget.hostID, authentication: .key(targetKeyID))
        do {
            try passwordStore.deletePassword(for: credentialID)
        } catch {
            EsmaLog.terminal.error(
                "failed clearing bootstrap password credential_id=\(credentialID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        emitStatusLine("[agentty] converted password bootstrap to key auth")
    }

    private static func logDescription(for authentication: AgenTTYConnectionAuthentication) -> String {
        switch authentication {
        case .key(let keyID):
            "key:\(keyID.uuidString)"
        case .passwordBootstrap(let targetKeyID, let credentialID):
            "passwordBootstrap:key=\(targetKeyID.uuidString):credential=\(credentialID.uuidString)"
        }
    }

    private static func analyticsAuthMode(
        for authentication: AgenTTYConnectionAuthentication
    ) -> AgenTTYAnalyticsSSHAuthMode {
        switch authentication {
        case .key:
            .key
        case .passwordBootstrap:
            .passwordBootstrap
        }
    }

    private func startShellPolling() {
        cancelShellPolling()
        shellTitleObservationsByWindowID.removeAll(keepingCapacity: true)
        shellPollTicksSinceLineCountRefresh = shellLineCountPollCadence
        let work = DispatchWorkItem { [weak self] in
            self?.pollShellState(includeLineCounts: true)
        }
        shellPollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + initialShellPollDelay, execute: work)
    }

    private func cancelShellPolling() {
        shellPollWorkItem?.cancel()
        shellPollWorkItem = nil
        shellPollTicksSinceLineCountRefresh = 0
        cancelImmediateShellPolls()
    }

    private func pollShellState(includeLineCounts: Bool) {
        guard !isShuttingDown, let ssh else {
            cancelShellPolling()
            return
        }

        if includeLineCounts {
            shellPollTicksSinceLineCountRefresh = 0
        }

        let command = includeLineCounts ? Self.tmuxListWindowsWithLineCountsCommand : Self.tmuxListWindowsCommand
        ssh.runTmuxCommand(command, timeout: interactiveTmuxCommandTimeout) { [weak self] success, output in
            DispatchQueue.main.async {
                guard let self, !self.isShuttingDown else { return }

                if success {
                    if includeLineCounts {
                        let windows = Self.parseTmuxWindowStatesWithLineCounts(from: output)
                        self.publishShellState(from: windows)
                        self.updateShellTitleTracking(for: windows)
                    } else {
                        let windows = Self.parseTmuxWindowStates(from: output)
                        self.publishShellState(from: windows)
                    }
                } else {
                    // A failed/timed-out poll on a "connected" transport is the
                    // first sign of a silently dead socket. Escalate to a probe;
                    // probe failure forces an immediate reconnect.
                    self.verifyTransportLiveness(reason: "shell poll failed")
                }

                self.scheduleNextShellPoll()
            }
        }
    }

    private func publishShellState(from windows: [TmuxWindowState]) {
        guard !windows.isEmpty else { return }
        let activePosition = windows.firstIndex(where: { $0.isActive }) ?? 0
        let windowIds = windows.map(\.id)
        publishShellState(windowCount: windows.count, activePosition: activePosition, windowIds: windowIds)
        publishShellWorkingDirectories(from: windows)
        publishActiveShellContext(from: windows)
    }

    private func publishShellState(windowCount: Int, activePosition: Int, windowIds: [Int]) {
        let signature = ShellStateSignature(windowIds: windowIds, activePosition: activePosition)
        if lastPublishedShellStateSignature == signature {
            return
        }
        lastPublishedShellStateSignature = signature
        shellStateDidChange?(windowCount, activePosition, windowIds)
        publishKnownShellTitles(for: windowIds)
    }

    private func publishActiveShellContext(from windows: [TmuxWindowState]) {
        guard let activeWindow = windows.first(where: { $0.isActive }) ?? windows.first else { return }
        let normalizedPath = Self.normalizeWorkingDirectoryPath(activeWindow.workingDirectoryPath)
        let cachedResolution = shellContextGitHeadByWorkingDirectory[normalizedPath] ?? .unknown
        publishActiveShellContext(
            windowID: activeWindow.id,
            workingDirectoryPath: normalizedPath,
            gitHead: cachedResolution
        )
        maybeResolveGitHeadForActiveShell(
            windowID: activeWindow.id,
            workingDirectoryPath: normalizedPath
        )
    }

    private func publishShellWorkingDirectories(from windows: [TmuxWindowState]) {
        for window in windows {
            shellWorkingDirectoryDidChange?(
                window.id,
                Self.normalizeWorkingDirectoryPath(window.workingDirectoryPath)
            )
        }
    }

    private func publishActiveShellContext(
        windowID: Int,
        workingDirectoryPath: String,
        gitHead: GitHeadResolution
    ) {
        let signature = ActiveShellContextSignature(
            windowID: windowID,
            workingDirectoryPath: workingDirectoryPath,
            branchName: gitHead.branchName
        )
        guard signature != lastPublishedActiveShellContextSignature else { return }
        lastPublishedActiveShellContextSignature = signature
        activeShellContextDidChange?(
            windowID,
            workingDirectoryPath,
            gitHead.branchName
        )
    }

    private func maybeResolveGitHeadForActiveShell(
        windowID: Int,
        workingDirectoryPath: String
    ) {
        guard let ssh else { return }
        guard !workingDirectoryPath.isEmpty else { return }

        let now = Date()
        let lastLookupDate = shellContextLastLookupDateByWorkingDirectory[workingDirectoryPath]
        let shouldRefresh: Bool
        if let lastLookupDate {
            shouldRefresh = now.timeIntervalSince(lastLookupDate) >= shellContextBranchRefreshInterval
        } else {
            shouldRefresh = true
        }
        guard shouldRefresh else { return }

        if let inFlightLookup = shellContextBranchLookupInFlight,
           inFlightLookup.workingDirectoryPath == workingDirectoryPath {
            return
        }

        shellContextBranchLookupRequestSequence += 1
        let request = ShellContextBranchLookupRequest(
            requestID: shellContextBranchLookupRequestSequence,
            windowID: windowID,
            workingDirectoryPath: workingDirectoryPath
        )
        shellContextBranchLookupInFlight = request
        shellContextLastLookupDateByWorkingDirectory[workingDirectoryPath] = now

        let command = Self.gitHeadStateCommand(forWorkingDirectoryPath: workingDirectoryPath)
        ssh.runTmuxCommand(command) { [weak self] success, output in
            DispatchQueue.main.async {
                self?.handleGitHeadLookupResult(
                    success: success,
                    output: output,
                    request: request
                )
            }
        }
    }

    private func handleGitHeadLookupResult(
        success: Bool,
        output: String,
        request: ShellContextBranchLookupRequest
    ) {
        guard shellContextBranchLookupInFlight?.requestID == request.requestID else { return }
        shellContextBranchLookupInFlight = nil

        let resolvedHead: GitHeadResolution
        if success {
            resolvedHead = Self.parseGitHeadResolution(from: output)
        } else {
            resolvedHead = .unknown
        }
        shellContextGitHeadByWorkingDirectory[request.workingDirectoryPath] = resolvedHead

        guard
            let activeSignature = lastPublishedActiveShellContextSignature,
            activeSignature.windowID == request.windowID,
            activeSignature.workingDirectoryPath == request.workingDirectoryPath
        else {
            return
        }

        publishActiveShellContext(
            windowID: request.windowID,
            workingDirectoryPath: request.workingDirectoryPath,
            gitHead: resolvedHead
        )
    }

    private func updateShellTitleTracking(for windows: [TmuxWindowState]) {
        guard !windows.isEmpty, let hostID = activeHost?.id else { return }

        let now = Date()
        var didMutateState = false
        let liveWindowIDs = Set(windows.map(\.id))
        let staleWindowIDs = shellTitleObservationsByWindowID.keys.filter { !liveWindowIDs.contains($0) }
        for staleWindowID in staleWindowIDs {
            shellTitleObservationsByWindowID[staleWindowID] = nil
        }

        for window in windows {
            guard let sessionCreated = window.sessionCreated else { continue }

            let identity: ShellTitleIdentity
            let progress: Int
            let milestone: Int
            let sourceRevision: Int
            let contextCommand: String
            let usesHostAgentState: Bool

            if let provider = window.agentTitleProvider,
               let providerSessionID = window.agentTitleSessionID,
               let completedTurnCount = window.agentCompletedTurnCount,
               let agentTitleRevision = window.agentTitleRevision {
                identity = ShellTitleIdentity(
                    hostID: hostID,
                    sessionCreated: sessionCreated,
                    windowID: window.id,
                    provider: provider,
                    providerSessionID: providerSessionID
                )
                progress = max(completedTurnCount, 0)
                milestone = Self.shellTitleTurnMilestone(for: progress)
                sourceRevision = max(agentTitleRevision, 0)
                contextCommand = Self.shellTitleHostStateCommand(
                    sessionCreated: sessionCreated,
                    windowID: window.id
                )
                usesHostAgentState = true
            } else {
                if window.hasAnyAgentTitleMetadata {
                    if shellTitleObservationsByWindowID.removeValue(forKey: window.id) != nil {
                        shellTitleDidChange?(window.id, "")
                    }
                    continue
                }
                guard !window.alternateScreenActive else {
                    if shellTitleObservationsByWindowID.removeValue(forKey: window.id) != nil {
                        shellTitleDidChange?(window.id, "")
                    }
                    continue
                }
                identity = ShellTitleIdentity(
                    hostID: hostID,
                    sessionCreated: sessionCreated,
                    windowID: window.id,
                    provider: "shell",
                    providerSessionID: "shell"
                )
                progress = max(window.lineCount, 0)
                milestone = Self.shellTitleGenerationMilestone(
                    for: progress,
                    initialThreshold: shellTitleInitialGenerationLineThreshold,
                    secondThreshold: shellTitleSecondGenerationLineThreshold,
                    earlyRefreshLineCutoff: shellTitleEarlyRefreshLineCutoff,
                    earlyRefreshInterval: shellTitleEarlyRefreshInterval,
                    frequentRefreshLineCutoff: shellTitleFrequentRefreshLineCutoff,
                    frequentRefreshInterval: shellTitleFrequentRefreshInterval,
                    steadyRefreshInterval: shellTitleSteadyRefreshInterval
                )
                sourceRevision = progress
                contextCommand = Self.tmuxCapturePaneTailCommand(
                    windowID: window.id,
                    maxLines: shellTitleContextLineLimit
                )
                usesHostAgentState = false
            }

            let previousObservation = shellTitleObservationsByWindowID.updateValue(
                ShellTitleObservation(identity: identity, sourceRevision: sourceRevision),
                forKey: window.id
            )
            var state = shellTitleStatesByIdentity[identity] ?? ShellTitleState(
                latestProgress: progress,
                lastGeneratedMilestone: 0,
                title: "",
                consecutiveFailureCount: 0,
                retryAfter: nil,
                updatedAt: now
            )

            if progress < state.latestProgress {
                state.lastGeneratedMilestone = 0
                state.consecutiveFailureCount = 0
                state.retryAfter = nil
                didMutateState = true
            }
            if state.latestProgress != progress {
                state.latestProgress = progress
                state.updatedAt = now
                didMutateState = true
            }
            shellTitleStatesByIdentity[identity] = state

            if previousObservation?.identity != identity {
                shellTitleDidChange?(window.id, state.title)
            }

            guard Self.shouldScheduleShellTitleGeneration(
                currentMilestone: milestone,
                lastGeneratedMilestone: state.lastGeneratedMilestone,
                retryAfter: state.retryAfter,
                now: now
            ) else {
                continue
            }
            guard shellTitleAIEnabled else { continue }
            guard shellTitleGenerationTasksByIdentity[identity] == nil else { continue }

            startShellTitleGeneration(
                ShellTitleGenerationRequest(
                    identity: identity,
                    windowID: window.id,
                    milestone: milestone,
                    sourceRevision: sourceRevision,
                    connectionGeneration: connectionGeneration,
                    contextCommand: contextCommand,
                    usesHostAgentState: usesHostAgentState,
                    currentTitle: state.title
                )
            )
        }

        if didMutateState {
            scheduleShellTitlePersistence()
        }
    }

    private func publishKnownShellTitles(for windowIDs: [Int]) {
        for windowID in windowIDs {
            guard let identity = shellTitleObservationsByWindowID[windowID]?.identity,
                  let title = shellTitleStatesByIdentity[identity]?.title else {
                continue
            }
            shellTitleDidChange?(windowID, title)
        }
    }

    private func startShellTitleGeneration(_ request: ShellTitleGenerationRequest) {
        guard shellTitleAIEnabled else { return }
        guard let ssh else { return }

        let task = Task { [weak self] in
            guard let self else { return }

            let capturedOutput = await self.captureTmuxOutput(
                using: ssh,
                command: request.contextCommand
            )
            let context: String?
            if request.usesHostAgentState {
                context = await Self.shellTitleContext(fromHostStateJSON: capturedOutput)
            } else {
                context = capturedOutput
            }
            let outcome: ShellTitleGenerationOutcome
            if let context,
               !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outcome = await self.generateShellTitle(
                    from: context,
                    currentTitle: request.currentTitle
                )
            } else {
                outcome = .failure
            }
            self.finishShellTitleGeneration(
                request: request,
                outcome: outcome
            )
        }

        shellTitleGenerationTasksByIdentity[request.identity] = task
    }

    private func finishShellTitleGeneration(
        request: ShellTitleGenerationRequest,
        outcome: ShellTitleGenerationOutcome
    ) {
        defer {
            shellTitleGenerationTasksByIdentity[request.identity] = nil
        }

        let currentObservation = shellTitleObservationsByWindowID[request.windowID]
        guard Self.isShellTitleGenerationResultCurrent(
            requestIdentity: request.identity,
            requestRevision: request.sourceRevision,
            requestConnectionGeneration: request.connectionGeneration,
            currentIdentity: currentObservation?.identity,
            currentRevision: currentObservation?.sourceRevision,
            currentConnectionGeneration: connectionGeneration
        ) else {
            return
        }
        guard var state = shellTitleStatesByIdentity[request.identity] else { return }

        let now = Date()
        switch outcome {
        case .success(let generatedTitle):
            state.lastGeneratedMilestone = max(
                state.lastGeneratedMilestone,
                request.milestone
            )
            state.consecutiveFailureCount = 0
            state.retryAfter = nil
            if generatedTitle != state.title {
                state.title = generatedTitle
                shellTitleDidChange?(request.windowID, generatedTitle)
            }
        case .failure:
            state.consecutiveFailureCount += 1
            state.retryAfter = now.addingTimeInterval(
                Self.shellTitleRetryDelay(
                    consecutiveFailureCount: state.consecutiveFailureCount
                )
            )
        }
        state.updatedAt = now
        shellTitleStatesByIdentity[request.identity] = state
        scheduleShellTitlePersistence()
    }

    private func captureTmuxOutput(using ssh: SSHClientSession, command: String) async -> String {
        await withCheckedContinuation { continuation in
            ssh.runTmuxCommand(command) { success, output in
                DispatchQueue.main.async {
                    guard success else {
                        continuation.resume(returning: "")
                        return
                    }
                    continuation.resume(returning: output)
                }
            }
        }
    }

    private func generateShellTitle(
        from shellText: String,
        currentTitle: String
    ) async -> ShellTitleGenerationOutcome {
        let trimmedShellText = shellText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShellText.isEmpty else {
            return .failure
        }
        let characterLimit = shellTitleCharacterLimit

        do {
            let generated = try await AgenTTYLLMClient.generateShellTitle(
                from: trimmedShellText,
                provider: shellTitleGenerationProvider,
                model: shellTitleGenerationModel,
                maxCharacters: characterLimit,
                currentTitle: currentTitle
            )
            let title = Self.sanitizeShellTitle(generated, maxCharacters: characterLimit)
            guard !title.isEmpty else {
                return .failure
            }
            return .success(title)
        } catch {
            let provider = self.shellTitleGenerationProvider.rawValue
            let model = self.shellTitleGenerationModel
            let errorSummary = Self.logErrorSummary(error)
            EsmaLog.terminal.error(
                "shell title generation failed provider=\(provider, privacy: .public) model=\(model, privacy: .public) error=\(errorSummary, privacy: .public)"
            )
            shellTitleGenerationDidFail?("[\(provider)/\(model)] \(errorSummary)")
            NotificationCenter.default.post(
                name: .shellTitleGenerationFailed,
                object: nil,
                userInfo: ["error": "[\(provider)/\(model)] \(errorSummary)"]
            )
            return .failure
        }
    }

    private func scheduleShellTitlePersistence() {
        shellTitlePersistWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistShellTitleStates()
            self.shellTitlePersistWorkItem = nil
        }
        shellTitlePersistWorkItem = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + shellTitlePersistenceDebounce,
            execute: work
        )
    }

    private func persistShellTitleStates() {
        ShellTitlePersistence.saveStates(shellTitleStatesByIdentity)
    }

    private func trimPersistedShellTitles(to maxCharacters: Int) {
        var didMutateState = false
        for (identity, state) in shellTitleStatesByIdentity {
            let trimmedTitle = Self.sanitizeShellTitle(state.title, maxCharacters: maxCharacters)
            guard trimmedTitle != state.title else { continue }
            var updatedState = state
            updatedState.title = trimmedTitle
            updatedState.updatedAt = Date()
            shellTitleStatesByIdentity[identity] = updatedState
            if shellTitleObservationsByWindowID[identity.windowID]?.identity == identity {
                shellTitleDidChange?(identity.windowID, trimmedTitle)
            }
            didMutateState = true
        }
        if didMutateState {
            scheduleShellTitlePersistence()
        }
    }

    private func cancelShellTitleGenerationTasks() {
        for task in shellTitleGenerationTasksByIdentity.values {
            task.cancel()
        }
        shellTitleGenerationTasksByIdentity.removeAll(keepingCapacity: false)
    }

    private func scheduleNextShellPoll() {
        guard !isShuttingDown else { return }
        let includeLineCounts = shouldIncludeLineCountsInNextPoll()
        let work = DispatchWorkItem { [weak self] in
            self?.pollShellState(includeLineCounts: includeLineCounts)
        }
        shellPollWorkItem?.cancel()
        shellPollWorkItem = work
        let interval = isApplicationActive ? shellPollInterval : backgroundShellPollInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func shouldIncludeLineCountsInNextPoll() -> Bool {
        if shellPollTicksSinceLineCountRefresh >= shellLineCountPollCadence {
            shellPollTicksSinceLineCountRefresh = 0
            return true
        }
        shellPollTicksSinceLineCountRefresh += 1
        return false
    }

    private func scheduleImmediateShellPollingIfNeeded(for data: Data) {
        guard data.contains(0x04) else { return }
        guard !isShuttingDown, ssh != nil else { return }
        // Ctrl+D often closes the active tmux window. Run a short burst of refresh polls so
        // the shell indicator updates immediately instead of waiting for the next periodic poll.
        scheduleImmediateShellPollBurst(delays: [0.12, 0.35, 0.75])
    }

    private func scheduleImmediateShellPollBurst(delays: [TimeInterval]) {
        cancelImmediateShellPolls()
        let lastDelayIndex = delays.indices.last
        for (delayIndex, delay) in delays.enumerated() {
            let includeLineCounts = delayIndex == lastDelayIndex
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isShuttingDown, self.ssh != nil else { return }
                self.pollShellState(includeLineCounts: includeLineCounts)
            }
            shellImmediatePollWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelImmediateShellPolls() {
        for work in shellImmediatePollWorkItems {
            work.cancel()
        }
        shellImmediatePollWorkItems.removeAll(keepingCapacity: false)
    }


}

extension Notification.Name {
    static let shellTitleGenerationFailed = Notification.Name("dev.tuist.agentty.shellTitleGenerationFailed")
}
