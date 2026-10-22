import Foundation
#if canImport(UIKit)
import UIKit
#endif

private nonisolated struct AgenTTYAnalyticsQueuedEvent: Codable, Equatable, Sendable {
    let eventID: String
    let eventType: AgenTTYAnalyticsEventType
    let occurredAtEpochSeconds: Int
    let payloadVersion: Int?
    let payload: AgenTTYAnalyticsJSONValue

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventType = "event_type"
        case occurredAtEpochSeconds = "occurred_at_epoch_seconds"
        case payloadVersion = "payload_version"
        case payload
    }
}

private nonisolated struct AgenTTYAnalyticsRequestContext: Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let identity: AgenTTYAnalyticsResolvedIdentity
    let appVersion: String
    let buildNumber: String
    let flavor: AgenTTYAnalyticsFlavor
    let platform: AgenTTYAnalyticsPlatform
    let deviceContext: AgenTTYAnalyticsDeviceContext
}

private nonisolated struct AgenTTYAnalyticsAppSessionStart: Sendable {
    let sessionID: String
    let startedAt: Date
    var hadPaywallVisible: Bool
    var sshSessionCount: Int
    var readySSHSessionCount: Int
    var hadTerminalInput: Bool
}

private nonisolated struct AgenTTYAnalyticsValidationRejection: Sendable {
    let statusCode: Int
    let detail: String
    let eventID: String?
    let eventType: AgenTTYAnalyticsEventType?
    let field: String?
    let rule: String?
}

private nonisolated struct AgenTTYAnalyticsValidationRejectionBody: Decodable {
    let detail: String?
    let eventID: String?
    let eventType: AgenTTYAnalyticsEventType?
    let field: String?
    let rule: String?
}

private nonisolated enum AgenTTYAnalyticsClientError: LocalizedError {
    case invalidPayloadObject
    case invalidResponse
    case unauthorized
    case validationRejected(AgenTTYAnalyticsValidationRejection)
    case unexpectedStatusCode(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidPayloadObject:
            "Failed to convert analytics payload into a JSON object."
        case .invalidResponse:
            "Invalid analytics backend response."
        case .unauthorized:
            "Analytics backend rejected device credentials."
        case .validationRejected(let rejection):
            "Analytics backend rejected validation for \(rejection.eventType?.rawValue ?? "unknown_event"): \(rejection.detail)"
        case .unexpectedStatusCode(let statusCode, let preview):
            "Analytics backend returned \(statusCode): \(preview)"
        }
    }
}

private nonisolated struct AgenTTYAnalyticsPartialFlushError: Error {
    let flushedEvents: [AgenTTYAnalyticsQueuedEvent]
    let underlyingError: Error
}

actor AgenTTYAnalyticsClient {
    typealias IdentityResolver = @Sendable (AgenTTYBuildFlavor, Bundle) async -> AgenTTYAnalyticsResolvedIdentity?
    typealias DeviceIdentityProvider = @Sendable () -> AgenTTYNotificationDeviceIdentity
    typealias DeviceIdentityEnsurer = @Sendable (URL, URLSession) async throws -> Void
    typealias DeviceContextProvider = @Sendable () async -> AgenTTYAnalyticsDeviceContext
    typealias DateProvider = @Sendable () -> Date
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let outboxFilename = "analytics-outbox.v1.json"
    private static let maximumBatchSize = 50
    private static let validationRejectionSentryMinimumInterval: TimeInterval = 5 * 60

    private let flavor: AgenTTYBuildFlavor
    private let urlSession: URLSession
    private let fileManager: FileManager
    private let bundle: Bundle
    private let appVersionOverride: String?
    private let buildNumberOverride: String?
    private let outboxDirectoryURL: URL?
    private let identityResolver: IdentityResolver
    private let deviceIdentityProvider: DeviceIdentityProvider
    private let deviceIdentityEnsurer: DeviceIdentityEnsurer
    private let deviceContextProvider: DeviceContextProvider
    private let dateProvider: DateProvider
    private let activeFlushInterval: Duration
    private let sleep: Sleep
    private let encoder = AgenTTYAnalyticsCodec.makeEncoder()
    private let decoder = AgenTTYAnalyticsCodec.makeDecoder()

    private var didLoadOutbox = false
    private var outbox: [AgenTTYAnalyticsQueuedEvent] = []
    private var cachedIdentity: AgenTTYAnalyticsResolvedIdentity?
    private var cachedDeviceContext: AgenTTYAnalyticsDeviceContext?
    private var didLogUnavailableIdentity = false
    private var isFlushing = false
    private var currentAppSessionStart: AgenTTYAnalyticsAppSessionStart?
    private var foregroundFlushTask: Task<Void, Never>?
    private var lastValidationRejectionSentryCaptureAt: Date?

    init(
        flavor: AgenTTYBuildFlavor = .current(),
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        appVersionOverride: String? = nil,
        buildNumberOverride: String? = nil,
        outboxDirectoryURL: URL? = nil,
        identityResolver: @escaping IdentityResolver = AgenTTYAppTransactionAnalyticsResolver.resolve,
        deviceIdentityProvider: @escaping DeviceIdentityProvider = AgenTTYRelayTransport.currentDeviceIdentity,
        deviceIdentityEnsurer: @escaping DeviceIdentityEnsurer = { baseURL, urlSession in
            try await AgenTTYRelayTransport.ensureCurrentDeviceIdentity(
                baseURL: baseURL,
                urlSession: urlSession
            )
        },
        deviceContextProvider: @escaping DeviceContextProvider = AgenTTYAnalyticsClient.defaultDeviceContext,
        dateProvider: @escaping DateProvider = Date.init,
        activeFlushInterval: Duration = .seconds(15),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.flavor = flavor
        self.urlSession = urlSession
        self.fileManager = fileManager
        self.bundle = bundle
        self.appVersionOverride = appVersionOverride
        self.buildNumberOverride = buildNumberOverride
        self.outboxDirectoryURL = outboxDirectoryURL
        self.identityResolver = identityResolver
        self.deviceIdentityProvider = deviceIdentityProvider
        self.deviceIdentityEnsurer = deviceIdentityEnsurer
        self.deviceContextProvider = deviceContextProvider
        self.dateProvider = dateProvider
        self.activeFlushInterval = activeFlushInterval
        self.sleep = sleep
    }

    func setSceneActive(
        _ isActive: Bool,
        accessState: AgenTTYAnalyticsAccessState,
        savedHostCount: Int,
        activeHostPresent: Bool
    ) async {
        guard flavor == .main else { return }

        if isActive {
            if currentAppSessionStart == nil {
                currentAppSessionStart = AgenTTYAnalyticsAppSessionStart(
                    sessionID: UUID().uuidString.lowercased(),
                    startedAt: dateProvider(),
                    hadPaywallVisible: false,
                    sshSessionCount: 0,
                    readySSHSessionCount: 0,
                    hadTerminalInput: false
                )
            }
            startForegroundFlushLoopIfNeeded()
            await flushPendingEvents()
            return
        }

        stopForegroundFlushLoop()

        guard let currentAppSessionStart else { return }
        self.currentAppSessionStart = nil

        let duration = dateProvider().timeIntervalSince(currentAppSessionStart.startedAt)
        let event = AgenTTYAnalyticsAppSessionCompletedEvent(
            appSessionID: currentAppSessionStart.sessionID,
            durationSeconds: Self.durationSeconds(from: duration),
            accessState: accessState,
            savedHostCount: savedHostCount,
            activeHostPresent: activeHostPresent,
            hadPaywallVisible: currentAppSessionStart.hadPaywallVisible,
            sshSessionCount: currentAppSessionStart.sshSessionCount,
            readySSHSessionCount: currentAppSessionStart.readySSHSessionCount,
            hadTerminalInput: currentAppSessionStart.hadTerminalInput
        )
        await recordAppSessionCompleted(event)
        await flushPendingEvents()
    }

    private func startForegroundFlushLoopIfNeeded() {
        guard foregroundFlushTask == nil else { return }

        let interval = activeFlushInterval
        let sleep = self.sleep
        foregroundFlushTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                await self.flushPendingEvents()
            }
        }
    }

    private func stopForegroundFlushLoop() {
        foregroundFlushTask?.cancel()
        foregroundFlushTask = nil
    }

    func recordAppSessionCompleted(_ event: AgenTTYAnalyticsAppSessionCompletedEvent) async {
        let payload = AgenTTYAnalyticsAppSessionCompletedPayload(
            session: AgenTTYAnalyticsAppSessionInfoPayload(
                id: event.appSessionID,
                durationSeconds: event.durationSeconds,
                savedHostCount: event.savedHostCount,
                activeHostPresent: event.activeHostPresent,
                hadPaywallVisible: event.hadPaywallVisible,
                sshSessionCount: event.sshSessionCount,
                readySSHSessionCount: event.readySSHSessionCount,
                hadTerminalInput: event.hadTerminalInput
            ),
            accessState: event.accessState
        )
        await enqueueEvent(type: .appSessionCompleted, payload: payload)
    }

    func recordAccessStateSnapshot(_ event: AgenTTYAnalyticsAccessStateSnapshotEvent) async {
        let payload = AgenTTYAnalyticsAccessStateSnapshotPayload(
            context: makeContextInfo(appSessionID: currentAppSessionStart?.sessionID),
            reason: event.reason,
            accessState: event.accessState
        )
        await enqueueEvent(type: .accessStateSnapshot, payload: payload)
    }

    func recordPurchaseFlow(_ event: AgenTTYAnalyticsPurchaseFlowEvent) async {
        let payload = AgenTTYAnalyticsPurchaseFlowPayload(
            kind: event.kind,
            state: event.state,
            error: event.errorMessage.map(AgenTTYAnalyticsPurchaseFlowErrorPayload.init(message:))
        )
        await enqueueEvent(type: .purchaseFlowEvent, payload: payload)
    }

    func recordHostSetupFlow(_ event: AgenTTYAnalyticsHostSetupFlowEvent) async {
        let payload = AgenTTYAnalyticsHostSetupFlowPayload(
            context: makeContextInfo(appSessionID: currentAppSessionStart?.sessionID),
            flow: AgenTTYAnalyticsHostSetupFlowInfoPayload(
                id: event.flowID,
                method: event.method,
                stage: event.stage,
                isEdit: event.isEdit,
                usesTailscaleAddress: event.usesTailscaleAddress
            ),
            host: makeHostReferencePayload(
                hostID: event.hostID,
                hostKeyHash: nil,
                savedHostCount: event.savedHostCount
            ),
            detectedUsername: makeDetectedUsernamePayload(
                value: event.detectedUsername,
                source: event.detectedUsernameSource,
                suspicious: event.usernameSuspicious
            ),
            edits: makeHostSetupEditsPayload(
                hostEdited: event.hostEdited,
                portEdited: event.portEdited,
                usernameEdited: event.usernameEdited
            ),
            candidates: makeCandidateSummaryPayload(from: event),
            hostEnvironment: makeHostEnvironmentPayload(
                platform: event.hostPlatform,
                flags: event.hostEnvironmentFlags
            ),
            reachability: makeReachabilityPayload(
                attemptCount: event.probeAttemptCount,
                failureSubtype: event.reachabilityFailureSubtype
            ),
            verification: makeVerificationPayload(
                attemptCount: event.verificationAttemptCount,
                failureStage: event.verificationFailureStage,
                disconnectCategory: event.verificationDisconnectCategory
            ),
            error: makeHostSetupErrorPayload(
                category: event.errorCategory,
                message: event.errorMessage
            )
        )
        await enqueueEvent(type: .hostSetupFlowEvent, payload: payload)
    }

    func recordKeyMaterial(_ event: AgenTTYAnalyticsKeyMaterialEvent) async {
        let payload = AgenTTYAnalyticsKeyMaterialEventPayload(
            context: makeContextInfo(appSessionID: currentAppSessionStart?.sessionID),
            operation: event.operation,
            stage: event.stage,
            key: event.keyType.map(AgenTTYAnalyticsKeyPayload.init(type:)),
            error: event.failureReason.map { failureReason in
                AgenTTYAnalyticsKeyMaterialErrorPayload(
                    reason: failureReason,
                    detail: event.failureDetail
                )
            }
        )
        await enqueueEvent(type: .keyMaterialEvent, payload: payload)
    }

    func recordPaywall(_ event: AgenTTYAnalyticsPaywallEvent) async {
        guard flavor == .main else { return }
        if event.stage == .shown, currentAppSessionStart?.hadPaywallVisible == true {
            return
        }
        currentAppSessionStart?.hadPaywallVisible = true
        let payload = AgenTTYAnalyticsPaywallPayload(
            context: makeContextInfo(appSessionID: currentAppSessionStart?.sessionID),
            stage: event.stage,
            accessState: event.accessState
        )
        await enqueueEvent(type: .paywallEvent, payload: payload)
    }

    func recordSSHSessionCompleted(_ event: AgenTTYAnalyticsSSHSessionCompletedEvent) async {
        if currentAppSessionStart != nil {
            currentAppSessionStart?.sshSessionCount += 1
            if event.wasReady {
                currentAppSessionStart?.readySSHSessionCount += 1
            }
            if event.hadTerminalInput {
                currentAppSessionStart?.hadTerminalInput = true
            }
        }

        let payload = AgenTTYAnalyticsSSHSessionCompletedPayload(
            context: makeContextInfo(appSessionID: currentAppSessionStart?.sessionID),
            session: AgenTTYAnalyticsSSHSessionInfoPayload(
                id: event.sessionID,
                durationSeconds: Self.durationSeconds(from: event.duration),
                wasReady: event.wasReady
            ),
            host: makeHostReferencePayload(
                hostID: event.hostID,
                hostKeyHash: event.hostKeyHash,
                savedHostCount: nil
            ),
            auth: AgenTTYAnalyticsSSHAuthPayload(mode: event.authMode),
            disconnect: AgenTTYAnalyticsSSHDisconnectPayload(
                category: event.disconnectCategory,
                reason: event.disconnectReason,
                failureStage: event.failureStage
            ),
            input: AgenTTYAnalyticsSSHInputPayload(
                hadTerminalInput: event.hadTerminalInput,
                eventCount: event.inputEventCount
            )
        )
        await enqueueEvent(type: .sshSessionCompleted, payload: payload)
    }

    func flushPendingEvents() async {
        guard flavor == .main else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        await loadOutboxIfNeeded()
        guard !outbox.isEmpty else { return }
        guard let requestContext = await requestContextIfAvailable() else { return }

        do {
            try await deviceIdentityEnsurer(AgenTTYRelayConfiguration.baseURL, urlSession)
        } catch {
            EsmaLog.app.error(
                "event=analytics_ensure_device_failed error=\(String(describing: error), privacy: .public)"
            )
            AgenTTYSentryService.capture(error: error, context: "analytics_ensure_device_failed")
            return
        }

        var didRetryUnauthorizedBatch = false
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(Self.maximumBatchSize))
            do {
                let flushedEvents = try await flushBatchWithValidationIsolation(batch, context: requestContext)
                try removeAndPersistFlushedEvents(flushedEvents)
                didRetryUnauthorizedBatch = false
            } catch let partialError as AgenTTYAnalyticsPartialFlushError {
                do {
                    try removeAndPersistFlushedEvents(partialError.flushedEvents)
                } catch {
                    EsmaLog.app.error(
                        "event=analytics_flush_failed reason=partial_persist error=\(String(describing: error), privacy: .public)"
                    )
                    AgenTTYSentryService.capture(
                        error: error,
                        context: "analytics_flush_failed_partial_persist",
                        data: analyticsBatchDiagnosticData(batch)
                    )
                    return
                }

                if isUnauthorized(partialError.underlyingError), !didRetryUnauthorizedBatch {
                    do {
                        try await deviceIdentityEnsurer(AgenTTYRelayConfiguration.baseURL, urlSession)
                        didRetryUnauthorizedBatch = true
                        continue
                    } catch {
                        EsmaLog.app.error(
                            "event=analytics_flush_failed retry=after_partial_ensure error=\(String(describing: error), privacy: .public)"
                        )
                        AgenTTYSentryService.capture(
                            error: error,
                            context: "analytics_flush_failed",
                            data: analyticsBatchDiagnosticData(batch)
                        )
                        return
                    }
                }

                EsmaLog.app.error(
                    "event=analytics_flush_failed reason=partial underlying_error=\(String(describing: partialError.underlyingError), privacy: .public)"
                )
                var data = analyticsBatchDiagnosticData(batch)
                data["partial_flushed_count"] = String(partialError.flushedEvents.count)
                AgenTTYSentryService.capture(
                    error: partialError.underlyingError,
                    context: "analytics_flush_failed",
                    data: data
                )
                return
            } catch AgenTTYAnalyticsClientError.unauthorized {
                guard !didRetryUnauthorizedBatch else {
                    EsmaLog.app.error("event=analytics_flush_failed retry=after_ensure error=unauthorized")
                    AgenTTYSentryService.capture(
                        error: AgenTTYAnalyticsClientError.unauthorized,
                        context: "analytics_flush_failed",
                        data: analyticsBatchDiagnosticData(batch)
                    )
                    return
                }

                do {
                    try await deviceIdentityEnsurer(AgenTTYRelayConfiguration.baseURL, urlSession)
                    didRetryUnauthorizedBatch = true
                    continue
                } catch {
                    EsmaLog.app.error(
                        "event=analytics_flush_failed retry=after_ensure error=\(String(describing: error), privacy: .public)"
                    )
                    AgenTTYSentryService.capture(
                        error: error,
                        context: "analytics_flush_failed",
                        data: analyticsBatchDiagnosticData(batch)
                    )
                    return
                }
            } catch {
                EsmaLog.app.error(
                    "event=analytics_flush_failed error=\(String(describing: error), privacy: .public)"
                )
                AgenTTYSentryService.capture(
                    error: error,
                    context: "analytics_flush_failed",
                    data: analyticsBatchDiagnosticData(batch)
                )
                return
            }
        }
    }

    private func flushBatchWithValidationIsolation(
        _ events: [AgenTTYAnalyticsQueuedEvent],
        context: AgenTTYAnalyticsRequestContext,
        originalBatch: [AgenTTYAnalyticsQueuedEvent]? = nil
    ) async throws -> [AgenTTYAnalyticsQueuedEvent] {
        let rootBatch = originalBatch ?? events
        do {
            try await sendBatch(events, context: context)
            return events
        } catch AgenTTYAnalyticsClientError.validationRejected(let rejection) {
            guard events.count > 1 else {
                if let rejectedEvent = events.first {
                    recordValidationRejection(rejection, rejectedEvent: rejectedEvent, originalBatch: rootBatch)
                }
                return events
            }

            let splitIndex = events.count / 2
            let left = Array(events[..<splitIndex])
            let right = Array(events[splitIndex...])
            let flushedLeft = try await flushBatchWithValidationIsolation(left, context: context, originalBatch: rootBatch)
            let flushedRight: [AgenTTYAnalyticsQueuedEvent]
            do {
                flushedRight = try await flushBatchWithValidationIsolation(right, context: context, originalBatch: rootBatch)
            } catch let partialError as AgenTTYAnalyticsPartialFlushError {
                throw AgenTTYAnalyticsPartialFlushError(
                    flushedEvents: flushedLeft + partialError.flushedEvents,
                    underlyingError: partialError.underlyingError
                )
            } catch {
                throw AgenTTYAnalyticsPartialFlushError(
                    flushedEvents: flushedLeft,
                    underlyingError: error
                )
            }
            return flushedLeft + flushedRight
        }
    }

    private func removeAndPersistFlushedEvents(_ events: [AgenTTYAnalyticsQueuedEvent]) throws {
        guard !events.isEmpty else { return }
        removeFlushedEvents(events)
        try persistOutbox()
    }

    private func removeFlushedEvents(_ events: [AgenTTYAnalyticsQueuedEvent]) {
        let eventIDs = Set(events.map(\.eventID))
        outbox.removeAll { eventIDs.contains($0.eventID) }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        if case AgenTTYAnalyticsClientError.unauthorized = error {
            return true
        }
        return false
    }

    private func recordValidationRejection(
        _ rejection: AgenTTYAnalyticsValidationRejection,
        rejectedEvent: AgenTTYAnalyticsQueuedEvent,
        originalBatch: [AgenTTYAnalyticsQueuedEvent]
    ) {
        EsmaLog.app.error(
            "event=analytics_validation_rejected status=\(rejection.statusCode, privacy: .public) event_id=\(rejectedEvent.eventID, privacy: .public) event_type=\(rejectedEvent.eventType.rawValue, privacy: .public) field=\(rejection.field ?? "none", privacy: .public) rule=\(rejection.rule ?? "none", privacy: .public)"
        )

        let now = dateProvider()
        if let lastValidationRejectionSentryCaptureAt,
           now.timeIntervalSince(lastValidationRejectionSentryCaptureAt) < Self.validationRejectionSentryMinimumInterval {
            return
        }
        lastValidationRejectionSentryCaptureAt = now

        var data = analyticsBatchDiagnosticData(originalBatch)
        data["status_code"] = String(rejection.statusCode)
        data["server_detail"] = rejection.detail
        data["rejected_event_id"] = rejectedEvent.eventID
        data["rejected_event_type"] = rejectedEvent.eventType.rawValue
        data["rejected_payload_version"] = rejectedEvent.payloadVersion.map(String.init) ?? "none"
        data["server_event_id"] = rejection.eventID ?? "none"
        data["server_event_type"] = rejection.eventType?.rawValue ?? "none"
        data["validation_field"] = rejection.field ?? "none"
        data["validation_rule"] = rejection.rule ?? "none"

        AgenTTYSentryService.captureHandledError(
            message: "Analytics validation rejection",
            context: "analytics_validation_rejected",
            data: data
        )
    }

    private func analyticsBatchDiagnosticData(
        _ events: [AgenTTYAnalyticsQueuedEvent]
    ) -> [String: String] {
        [
            "batch_count": String(events.count),
            "event_type_counts": eventTypeCounts(events),
            "first_event_ids": events.prefix(5).map(\.eventID).joined(separator: ","),
        ]
    }

    private func eventTypeCounts(_ events: [AgenTTYAnalyticsQueuedEvent]) -> String {
        let counts = events.reduce(into: [AgenTTYAnalyticsEventType: Int]()) { partialResult, event in
            partialResult[event.eventType, default: 0] += 1
        }
        return counts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
    }

    private func enqueueEvent<T: Encodable>(
        type: AgenTTYAnalyticsEventType,
        payload: T,
        payloadVersion: Int = 2
    ) async {
        guard flavor == .main else { return }
        guard await identityIfAvailable() != nil else { return }
        guard let payloadObject = encodePayloadObject(payload) else {
            EsmaLog.app.error("event=analytics_payload_encode_failed type=\(type.rawValue, privacy: .public)")
            return
        }

        await loadOutboxIfNeeded()
        outbox.append(
            AgenTTYAnalyticsQueuedEvent(
                eventID: UUID().uuidString.lowercased(),
                eventType: type,
                occurredAtEpochSeconds: Int(dateProvider().timeIntervalSince1970.rounded()),
                payloadVersion: payloadVersion,
                payload: payloadObject
            )
        )

        do {
            try persistOutbox()
        } catch {
            EsmaLog.app.error(
                "event=analytics_outbox_persist_failed error=\(String(describing: error), privacy: .public)"
            )
            AgenTTYSentryService.capture(error: error, context: "analytics_outbox_persist_failed")
            return
        }

        if currentAppSessionStart != nil {
            await flushPendingEvents()
        }
    }

    private func identityIfAvailable() async -> AgenTTYAnalyticsResolvedIdentity? {
        if let cachedIdentity {
            return cachedIdentity
        }

        guard let identity = await identityResolver(flavor, bundle) else {
            if !didLogUnavailableIdentity {
                didLogUnavailableIdentity = true
                EsmaLog.app.notice("event=analytics_identity_unavailable")
            }
            return nil
        }

        cachedIdentity = identity
        return identity
    }

    private func requestContextIfAvailable() async -> AgenTTYAnalyticsRequestContext? {
        guard let identity = await identityIfAvailable() else { return nil }
        return await makeRequestContext(identity: identity)
    }

    private func makeRequestContext(
        identity: AgenTTYAnalyticsResolvedIdentity
    ) async -> AgenTTYAnalyticsRequestContext? {
        let deviceIdentity = deviceIdentityProvider()
        let appVersion = appVersionOverride ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = buildNumberOverride ?? bundle.infoDictionary?["CFBundleVersion"] as? String
        guard let appVersion,
              !appVersion.isEmpty,
              let buildNumber,
              !buildNumber.isEmpty else {
            return nil
        }

        let deviceContext = await currentDeviceContext()

        return AgenTTYAnalyticsRequestContext(
            deviceID: deviceIdentity.deviceID,
            deviceSecret: deviceIdentity.deviceSecret,
            identity: identity,
            appVersion: appVersion,
            buildNumber: buildNumber,
            flavor: .main,
            platform: .ios,
            deviceContext: deviceContext
        )
    }

    private func sendBatch(
        _ events: [AgenTTYAnalyticsQueuedEvent],
        context: AgenTTYAnalyticsRequestContext
    ) async throws {
        let request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: AgenTTYRelayConfiguration.baseURL,
            path: "v1/analytics/events",
            body: AgenTTYAnalyticsIngestRequest(
                deviceID: context.deviceID.uuidString.lowercased(),
                deviceSecret: context.deviceSecret,
                appTransactionID: context.identity.appTransactionID,
                originalPurchaseDateEpochSeconds: context.identity.originalPurchaseDateEpochSeconds,
                bundleID: context.identity.bundleID,
                appTransactionEnvironment: context.identity.appTransactionEnvironment,
                appVersion: context.appVersion,
                buildNumber: context.buildNumber,
                flavor: context.flavor,
                platform: context.platform,
                deviceContext: context.deviceContext,
                events: try events.map { event in
                    guard case .object = event.payload else {
                        throw AgenTTYAnalyticsClientError.invalidPayloadObject
                    }

                    return AgenTTYAnalyticsRequestEvent(
                        eventID: event.eventID,
                        eventType: event.eventType,
                        occurredAtEpochSeconds: event.occurredAtEpochSeconds,
                        payloadVersion: event.payloadVersion,
                        payload: event.payload
                    )
                }
            )
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYAnalyticsClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 204:
            EsmaLog.app.notice(
                "event=analytics_flush_success events=\(events.count, privacy: .public)"
            )
        case 401:
            throw AgenTTYAnalyticsClientError.unauthorized
        case 400:
            throw AgenTTYAnalyticsClientError.validationRejected(
                validationRejection(from: data, statusCode: httpResponse.statusCode)
            )
        default:
            let responsePreview = AgenTTYRelayTransport.responsePreview(from: data)
            throw AgenTTYAnalyticsClientError.unexpectedStatusCode(
                httpResponse.statusCode,
                responsePreview
            )
        }
    }

    private func validationRejection(
        from data: Data,
        statusCode: Int
    ) -> AgenTTYAnalyticsValidationRejection {
        let body = try? decoder.decode(AgenTTYAnalyticsValidationRejectionBody.self, from: data)
        return AgenTTYAnalyticsValidationRejection(
            statusCode: statusCode,
            detail: body?.detail ?? AgenTTYRelayTransport.responsePreview(from: data),
            eventID: body?.eventID,
            eventType: body?.eventType,
            field: body?.field,
            rule: body?.rule
        )
    }

    private func loadOutboxIfNeeded() async {
        guard !didLoadOutbox else { return }
        didLoadOutbox = true

        do {
            let url = try outboxURL()
            guard fileManager.fileExists(atPath: url.path) else {
                outbox = []
                return
            }
            let data = try Data(contentsOf: url)
            do {
                outbox = try decoder.decode([AgenTTYAnalyticsQueuedEvent].self, from: data)
            } catch {
                // Older queued analytics files predate the centralized analytics codec.
                // Keep a plain decoder fallback so local legacy outbox entries still flush.
                outbox = try JSONDecoder().decode([AgenTTYAnalyticsQueuedEvent].self, from: data)
            }
        } catch {
            outbox = []
            EsmaLog.app.error(
                "event=analytics_outbox_load_failed error=\(String(describing: error), privacy: .public)"
            )
            AgenTTYSentryService.capture(error: error, context: "analytics_outbox_load_failed")
        }
    }

    private func persistOutbox() throws {
        let outboxURL = try outboxURL()
        try fileManager.createDirectory(
            at: outboxURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let data = try encoder.encode(outbox)
        try data.write(to: outboxURL, options: .atomic)
    }

    private func outboxURL() throws -> URL {
        let rootURL: URL
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AgenTTYSharedDefaults.appGroupIdentifier
        ) {
            if let outboxDirectoryURL {
                rootURL = outboxDirectoryURL
            } else {
                rootURL = containerURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("Analytics", isDirectory: true)
            }
        } else {
            if let outboxDirectoryURL {
                rootURL = outboxDirectoryURL
            } else {
                rootURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Analytics", isDirectory: true)
            }
        }
        return rootURL.appendingPathComponent(Self.outboxFilename)
    }

    private func encodePayloadObject<T: Encodable>(_ payload: T) -> AgenTTYAnalyticsJSONValue? {
        guard let data = try? encoder.encode(payload),
              let payloadObject = try? decoder.decode(AgenTTYAnalyticsJSONValue.self, from: data) else {
            return nil
        }
        guard case .object = payloadObject else { return nil }
        return payloadObject
    }

    private static func durationSeconds(from duration: TimeInterval) -> Int {
        Int(max(0, duration).rounded())
    }

    private func makeContextInfo(appSessionID: String?) -> AgenTTYAnalyticsContextInfo? {
        guard let appSessionID, !appSessionID.isEmpty else { return nil }
        return AgenTTYAnalyticsContextInfo(appSessionID: appSessionID)
    }

    private func makeHostReferencePayload(
        hostID: UUID,
        hostKeyHash: String?,
        savedHostCount: Int?
    ) -> AgenTTYAnalyticsHostReferencePayload {
        AgenTTYAnalyticsHostReferencePayload(
            idHash: AgenTTYAnalyticsHashing.sha256Hex(hostID.uuidString.lowercased()),
            keyHash: hostKeyHash,
            savedHostCount: savedHostCount
        )
    }

    private func makeHostReferencePayload(
        hostID: UUID?,
        hostKeyHash: String?,
        savedHostCount: Int?
    ) -> AgenTTYAnalyticsHostReferencePayload? {
        let idHash = hostID.map { AgenTTYAnalyticsHashing.sha256Hex($0.uuidString.lowercased()) }
        guard idHash != nil || hostKeyHash != nil || savedHostCount != nil else {
            return nil
        }
        return AgenTTYAnalyticsHostReferencePayload(
            idHash: idHash,
            keyHash: hostKeyHash,
            savedHostCount: savedHostCount
        )
    }

    private func makeDetectedUsernamePayload(
        value: String?,
        source: AgenTTYPairingDetectedUsernameSource?,
        suspicious: Bool?
    ) -> AgenTTYAnalyticsDetectedUsernamePayload? {
        guard value != nil || source != nil || suspicious != nil else {
            return nil
        }
        return AgenTTYAnalyticsDetectedUsernamePayload(
            value: value,
            source: source,
            suspicious: suspicious
        )
    }

    private func makeHostSetupEditsPayload(
        hostEdited: Bool?,
        portEdited: Bool?,
        usernameEdited: Bool?
    ) -> AgenTTYAnalyticsHostSetupEditsPayload? {
        guard hostEdited != nil || portEdited != nil || usernameEdited != nil else {
            return nil
        }
        return AgenTTYAnalyticsHostSetupEditsPayload(
            host: hostEdited,
            port: portEdited,
            username: usernameEdited
        )
    }

    private func makeCandidateSummaryPayload(
        from event: AgenTTYAnalyticsHostSetupFlowEvent
    ) -> AgenTTYAnalyticsCandidateSummaryPayload? {
        let selectedCandidate: AgenTTYAnalyticsSelectedCandidatePayload? =
            if let selectedCandidateValue = event.selectedCandidateValue,
               let selectedCandidateKind = event.selectedCandidateKind,
               let selectedCandidateSource = event.selectedCandidateSource,
               let selectedCandidateRank = event.selectedCandidateRank {
                AgenTTYAnalyticsSelectedCandidatePayload(
                    value: selectedCandidateValue,
                    kind: selectedCandidateKind,
                    source: selectedCandidateSource,
                    rank: selectedCandidateRank
                )
            } else {
                nil
            }

        guard selectedCandidate != nil
            || event.candidateValues != nil
            || event.candidateCount != nil
            || event.highConfidenceCandidateCount != nil
            || event.allLowConfidenceCandidates != nil else {
            return nil
        }

        return AgenTTYAnalyticsCandidateSummaryPayload(
            selected: selectedCandidate,
            allValues: event.candidateValues,
            count: event.candidateCount,
            highConfidenceCount: event.highConfidenceCandidateCount,
            allLowConfidence: event.allLowConfidenceCandidates
        )
    }

    private func makeHostEnvironmentPayload(
        platform: AgenTTYAnalyticsHostPlatform?,
        flags: [AgenTTYAnalyticsHostEnvironmentFlag]
    ) -> AgenTTYAnalyticsHostEnvironmentPayload? {
        guard let platform else { return nil }
        return AgenTTYAnalyticsHostEnvironmentPayload(platform: platform, flags: flags)
    }

    private func makeReachabilityPayload(
        attemptCount: Int?,
        failureSubtype: AgenTTYAnalyticsReachabilityFailureSubtype?
    ) -> AgenTTYAnalyticsReachabilityPayload? {
        guard let attemptCount else { return nil }
        return AgenTTYAnalyticsReachabilityPayload(
            attemptCount: attemptCount,
            failureSubtype: failureSubtype
        )
    }

    private func makeVerificationPayload(
        attemptCount: Int?,
        failureStage: AgenTTYAnalyticsSSHFailureStage?,
        disconnectCategory: AgenTTYAnalyticsSSHDisconnectCategory?
    ) -> AgenTTYAnalyticsVerificationPayload? {
        guard let attemptCount else { return nil }
        return AgenTTYAnalyticsVerificationPayload(
            attemptCount: attemptCount,
            failureStage: failureStage,
            disconnectCategory: disconnectCategory
        )
    }

    private func makeHostSetupErrorPayload(
        category: AgenTTYAnalyticsHostSetupErrorCategory?,
        message: String?
    ) -> AgenTTYAnalyticsHostSetupErrorPayload? {
        guard let category else { return nil }
        return AgenTTYAnalyticsHostSetupErrorPayload(category: category, message: message)
    }

    private func currentDeviceContext() async -> AgenTTYAnalyticsDeviceContext {
        if let cachedDeviceContext {
            return cachedDeviceContext
        }

        let deviceContext = await deviceContextProvider()
        cachedDeviceContext = deviceContext
        return deviceContext
    }

    private static func currentDeviceContext() async -> AgenTTYAnalyticsDeviceContext {
        await MainActor.run {
            AgenTTYAnalyticsDeviceContext(
                systemVersion: Self.currentSystemVersion(),
                deviceModelIdentifier: Self.currentDeviceModelIdentifier(),
                deviceFamily: Self.currentDeviceFamily(),
                localeIdentifier: Locale.current.identifier,
                preferredLanguages: Locale.preferredLanguages
            )
        }
    }

    private static func defaultDeviceContext() async -> AgenTTYAnalyticsDeviceContext {
        await currentDeviceContext()
    }

    @MainActor
    private static func currentSystemVersion() -> String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    @MainActor
    private static func currentDeviceFamily() -> AgenTTYAnalyticsDeviceFamily {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            .phone
        case .pad:
            .pad
        case .mac:
            .mac
        case .tv:
            .tv
        case .carPlay:
            .carPlay
        case .vision:
            .vision
        default:
            .unspecified
        }
        #else
        .unspecified
        #endif
    }

    @MainActor
    private static func currentDeviceModelIdentifier() -> String {
        var systemInfo = utsname()
        unsafe uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { identifier, child in
            guard let value = child.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
