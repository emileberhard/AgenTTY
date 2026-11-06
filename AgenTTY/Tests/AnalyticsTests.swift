import Foundation
import Testing
@testable import AgenTTY_iOS

@Suite
struct AnalyticsTests {
    @MainActor
    @Test
    func saveSucceededUnverifiedAnalyticsIncludesVerificationFailure() {
        let verificationFailure = AgenTTYSSHTerminationOutcome(
            category: .authFailed,
            failureStage: .sshAuth,
            rawReason: "Public-key authentication was rejected by the server.",
            wasReady: false,
            shouldReconnect: false
        )

        let outcome = HostSetupSaveAnalyticsOutcome(
            overrideValidationWarning: true,
            verificationFailureOutcome: verificationFailure
        )

        #expect(outcome.stage == .saveSucceededUnverified)
        #expect(outcome.verificationAttemptCount == 1)
        #expect(outcome.verificationFailureOutcome == verificationFailure)
    }

    @MainActor
    @Test
    func saveSucceededUnreachableAnalyticsDoesNotAttachVerificationPayload() {
        let outcome = HostSetupSaveAnalyticsOutcome(
            overrideValidationWarning: true,
            verificationFailureOutcome: nil
        )

        #expect(outcome.stage == .saveSucceededUnreachable)
        #expect(outcome.verificationAttemptCount == nil)
        #expect(outcome.verificationFailureOutcome == nil)
    }

    @MainActor
    @Test
    func analyticsHostSetupPayloadEncodesStructuredDiagnosticsKeys() throws {
        let payload = AgenTTYAnalyticsHostSetupFlowPayload(
            context: AgenTTYAnalyticsContextInfo(appSessionID: "app-session-1"),
            flow: AgenTTYAnalyticsHostSetupFlowInfoPayload(
                id: "flow-1",
                method: .automatic,
                stage: .reviewPresented,
                isEdit: false,
                usesTailscaleAddress: false
            ),
            host: AgenTTYAnalyticsHostReferencePayload(
                idHash: "host-id-hash-1",
                keyHash: nil,
                savedHostCount: 1
            ),
            detectedUsername: AgenTTYAnalyticsDetectedUsernamePayload(
                value: "developer",
                source: .whoamiCommand,
                suspicious: true
            ),
            edits: AgenTTYAnalyticsHostSetupEditsPayload(host: false, port: false, username: false),
            candidates: AgenTTYAnalyticsCandidateSummaryPayload(
                selected: AgenTTYAnalyticsSelectedCandidatePayload(
                    value: "agentty",
                    kind: .singleLabel,
                    source: .hostname,
                    rank: 1
                ),
                allValues: ["agentty"],
                count: 1,
                highConfidenceCount: 0,
                allLowConfidence: true
            ),
            hostEnvironment: AgenTTYAnalyticsHostEnvironmentPayload(
                platform: .linux,
                flags: [.wsl]
            ),
            reachability: AgenTTYAnalyticsReachabilityPayload(
                attemptCount: 2,
                failureSubtype: .dns
            ),
            verification: nil,
            error: AgenTTYAnalyticsHostSetupErrorPayload(
                category: .reachability,
                message: "dial tcp agentty: no route to host"
            )
        )

        let object = try analyticsJSONObject(payload)
        let context = try #require(object["context"] as? [String: Any])
        let flow = try #require(object["flow"] as? [String: Any])
        let detectedUsername = try #require(object["detected_username"] as? [String: Any])
        let candidates = try #require(object["candidates"] as? [String: Any])
        let selectedCandidate = try #require(candidates["selected"] as? [String: Any])
        let hostEnvironment = try #require(object["host_environment"] as? [String: Any])

        #expect(context["app_session_id"] as? String == "app-session-1")
        #expect(flow["id"] as? String == "flow-1")
        #expect(detectedUsername["source"] as? String == "whoami_command")
        #expect(selectedCandidate["source"] as? String == "hostname")
        #expect(candidates["count"] as? Int == 1)
        #expect(candidates["all_low_confidence"] as? Bool == true)
        #expect(hostEnvironment["platform"] as? String == "linux")
        #expect(hostEnvironment["flags"] as? [String] == ["wsl"])
    }

    @MainActor
    @Test
    func analyticsHostSetupPayloadEncodesVerificationFields() throws {
        let payload = AgenTTYAnalyticsHostSetupFlowPayload(
            context: AgenTTYAnalyticsContextInfo(appSessionID: "app-session-1"),
            flow: AgenTTYAnalyticsHostSetupFlowInfoPayload(
                id: "flow-1",
                method: .automatic,
                stage: .verificationFailed,
                isEdit: false,
                usesTailscaleAddress: false
            ),
            host: AgenTTYAnalyticsHostReferencePayload(
                idHash: "host-id-hash-1",
                keyHash: nil,
                savedHostCount: nil
            ),
            detectedUsername: AgenTTYAnalyticsDetectedUsernamePayload(
                value: "developer",
                source: .whoamiCommand,
                suspicious: false
            ),
            edits: AgenTTYAnalyticsHostSetupEditsPayload(host: false, port: false, username: false),
            candidates: AgenTTYAnalyticsCandidateSummaryPayload(
                selected: AgenTTYAnalyticsSelectedCandidatePayload(
                    value: "agentty.tail123.ts.net",
                    kind: .fqdn,
                    source: .hostnameFQDN,
                    rank: 1
                ),
                allValues: ["agentty.tail123.ts.net"],
                count: 1,
                highConfidenceCount: 1,
                allLowConfidence: false
            ),
            hostEnvironment: AgenTTYAnalyticsHostEnvironmentPayload(platform: .linux, flags: []),
            reachability: nil,
            verification: AgenTTYAnalyticsVerificationPayload(
                attemptCount: 2,
                failureStage: .sshAuth,
                disconnectCategory: .authFailed
            ),
            error: AgenTTYAnalyticsHostSetupErrorPayload(
                category: .connectionVerification,
                message: "Public-key authentication was rejected by the server."
            )
        )

        let object = try analyticsJSONObject(payload)
        let flow = try #require(object["flow"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let verification = try #require(object["verification"] as? [String: Any])

        #expect(flow["stage"] as? String == "verification_failed")
        #expect(error["category"] as? String == "connection_verification")
        #expect(verification["attempt_count"] as? Int == 2)
        #expect(verification["failure_stage"] as? String == "ssh_auth")
        #expect(verification["disconnect_category"] as? String == "auth_failed")
    }

    @Test
    func analyticsHashingIsDeterministic() {
        #expect(AgenTTYAnalyticsHashing.sha256Hex("host-id") == AgenTTYAnalyticsHashing.sha256Hex("host-id"))
        #expect(AgenTTYAnalyticsHashing.sha256Hex("host-id") != AgenTTYAnalyticsHashing.sha256Hex("host-id-2"))
    }

    @MainActor
    @Test
    func expiredTrialPreviewProducesBlockedAnalyticsAccessState() {
        let state = AgenTTYLifetimeAccessController.previewExpiredTrial().analyticsAccessState

        #expect(!state.hasLifetimeAccess)
        #expect(state.trialExpired)
        #expect(abs(state.trialRemainingUsageSeconds - 0) <= 0.000_000_1)
        #expect(abs(state.trialConsumedUsageSeconds - AgenTTYTrialPolicy.usageLimit) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func unlockedPreviewProducesUnlockedAnalyticsAccessState() {
        let state = AgenTTYLifetimeAccessController.previewUnlocked().analyticsAccessState

        #expect(state.hasLifetimeAccess)
        #expect(!state.trialExpired)
        #expect(abs(state.trialConsumedUsageSeconds - 0) <= 0.000_000_1)
        #expect(abs(state.trialRemainingUsageSeconds - 0) <= 0.000_000_1)
    }

    @Test
    func analyticsClientFlushEncodesDeviceContextAndRicherEvents() async throws {
        let transport = AnalyticsClientTestTransport()
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .automatic,
                stage: .saveSucceeded,
                isEdit: false,
                usesTailscaleAddress: true,
                flowID: nil,
                savedHostCount: 1,
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                errorCategory: nil,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: nil,
                portEdited: nil,
                usernameEdited: nil,
                selectedCandidateKind: nil,
                selectedCandidateSource: nil,
                selectedCandidateRank: nil,
                selectedCandidateValue: nil,
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: nil,
                reachabilityFailureSubtype: nil,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )
        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )
        await client.recordSSHSessionCompleted(
            AgenTTYAnalyticsSSHSessionCompletedEvent(
                sessionID: "ssh-session-1",
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                duration: 45,
                wasReady: true,
                disconnectCategory: .shellClosed,
                disconnectReason: nil,
                failureStage: nil,
                hadTerminalInput: true,
                inputEventCount: 3,
                authMode: .key,
                hostKeyHash: nil
            )
        )
        await client.flushPendingEvents()

        #expect(transport.ensureDeviceIdentityCallCount == 1)
        #expect(transport.requests.count == 1)

        let requestBody = try #require(transport.requestBodies.first)
        let requestJSON = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])

        #expect(requestJSON["device_id"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(requestJSON["device_secret"] as? String == "device-secret")

        let deviceContext = try #require(requestJSON["device_context"] as? [String: Any])
        #expect(deviceContext["system_version"] as? String == "26.2")
        #expect(deviceContext["device_model_identifier"] as? String == "iPhone17,3")
        #expect(deviceContext["device_family"] as? String == "phone")
        #expect(deviceContext["locale_identifier"] as? String == "en_SE")
        #expect(deviceContext["preferred_languages"] as? [String] == ["en-SE", "sv-SE"])

        let events = try #require(requestJSON["events"] as? [[String: Any]])
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0["payload_version"] as? Int == 2 })

        let payloadObjects = events.compactMap { $0["payload"] as? [String: Any] }
        #expect(payloadObjects.count == 3)
        #expect(payloadObjects.contains(where: { payload in
            let flow = payload["flow"] as? [String: Any]
            return flow?["stage"] as? String == "save_succeeded"
        }))
        #expect(payloadObjects.contains(where: { $0["stage"] as? String == "shown" }))
        #expect(payloadObjects.contains(where: { payload in
                let disconnect = payload["disconnect"] as? [String: Any]
                let input = payload["input"] as? [String: Any]
                return disconnect?["category"] as? String == "shell_closed"
                    && input?["event_count"] as? Int == 3
            }))
    }

    @Test
    func analyticsClientHostSetupFlowEncodesExtendedAutomaticSetupFields() async throws {
        let transport = AnalyticsClientTestTransport()
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .automatic,
                stage: .failed,
                isEdit: false,
                usesTailscaleAddress: false,
                flowID: nil,
                savedHostCount: nil,
                hostID: nil,
                errorCategory: .reachability,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: true,
                portEdited: false,
                usernameEdited: true,
                selectedCandidateKind: .localDomain,
                selectedCandidateSource: .hostnameFQDN,
                selectedCandidateRank: 1,
                selectedCandidateValue: "agentty.local",
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: 2,
                reachabilityFailureSubtype: .dns,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )
        await client.flushPendingEvents()

        let requestBody = try #require(transport.requestBodies.first)
        let requestJSON = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let events = try #require(requestJSON["events"] as? [[String: Any]])
        let hostSetupPayload = try #require(events.first?["payload"] as? [String: Any])

        let edits = try #require(hostSetupPayload["edits"] as? [String: Any])
        let candidates = try #require(hostSetupPayload["candidates"] as? [String: Any])
        let reachability = try #require(hostSetupPayload["reachability"] as? [String: Any])
        let error = try #require(hostSetupPayload["error"] as? [String: Any])

        #expect(edits["host"] as? Bool == true)
        #expect(edits["port"] as? Bool == false)
        #expect(edits["username"] as? Bool == true)
        #expect((candidates["selected"] as? [String: Any])?["kind"] as? String == "local_domain")
        #expect(reachability["attempt_count"] as? Int == 2)
        #expect(reachability["failure_subtype"] as? String == "dns")
        #expect(error["category"] as? String == "reachability")
    }

    @Test
    func analyticsClientAppSessionCompletedIncludesSessionCounters() async throws {
        let transport = AnalyticsClientTestTransport()
        let dateBox = AnalyticsClientDateBox(Date(timeIntervalSince1970: 1_715_000_000))
        let client = makeAnalyticsClient(
            transport: transport,
            nowProvider: { dateBox.current },
            outboxDirectoryURL: nil
        )

        await client.setSceneActive(
            true,
            accessState: Self.blockedAnalyticsAccessState,
            savedHostCount: 0,
            activeHostPresent: false
        )
        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )
        await client.recordSSHSessionCompleted(
            AgenTTYAnalyticsSSHSessionCompletedEvent(
                sessionID: "ssh-session-2",
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                duration: 30,
                wasReady: true,
                disconnectCategory: .shellClosed,
                disconnectReason: nil,
                failureStage: nil,
                hadTerminalInput: true,
                inputEventCount: 5,
                authMode: .key,
                hostKeyHash: nil
            )
        )

        dateBox.current = dateBox.current.addingTimeInterval(90)

        await client.setSceneActive(
            false,
            accessState: Self.blockedAnalyticsAccessState,
            savedHostCount: 2,
            activeHostPresent: true
        )

        #expect(transport.requests.count >= 1)

        let appSessionEvent = try #require(try transport.requestBodies
                .compactMap { requestBody in
                    try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
                }
                .compactMap { $0["events"] as? [[String: Any]] }
                .flatMap { $0 }
                .first(where: { $0["event_type"] as? String == "app_session_completed" }))
        let payload = try #require(appSessionEvent["payload"] as? [String: Any])
        let session = try #require(payload["session"] as? [String: Any])

        #expect(session["saved_host_count"] as? Int == 2)
        #expect(session["active_host_present"] as? Bool == true)
        #expect(session["had_paywall_visible"] as? Bool == true)
        #expect(session["ssh_session_count"] as? Int == 1)
        #expect(session["ready_ssh_session_count"] as? Int == 1)
        #expect(session["had_terminal_input"] as? Bool == true)
        #expect(session["duration_seconds"] as? Int == 90)
    }

    @Test
    func analyticsClientFlushesPendingEventsWhileSceneRemainsActive() async throws {
        let transport = AnalyticsClientTestTransport()
        let client = makeAnalyticsClient(
            transport: transport,
            nowProvider: { Date(timeIntervalSince1970: 1_715_000_000) },
            outboxDirectoryURL: nil
        )

        await client.setSceneActive(
            true,
            accessState: Self.blockedAnalyticsAccessState,
            savedHostCount: 1,
            activeHostPresent: true
        )
        await client.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .manual,
                stage: .saveSucceeded,
                isEdit: false,
                usesTailscaleAddress: false,
                flowID: nil,
                savedHostCount: 1,
                hostID: nil,
                errorCategory: nil,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: nil,
                portEdited: nil,
                usernameEdited: nil,
                selectedCandidateKind: nil,
                selectedCandidateSource: nil,
                selectedCandidateRank: nil,
                selectedCandidateValue: nil,
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: nil,
                reachabilityFailureSubtype: nil,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )

        for _ in 0..<20 where transport.requests.isEmpty {
            await Task.yield()
        }

        #expect(transport.requests.count == 1)

        await client.setSceneActive(
            false,
            accessState: Self.blockedAnalyticsAccessState,
            savedHostCount: 1,
            activeHostPresent: true
        )
    }

    @Test
    func analyticsClientFlushLoadsLegacyOutboxEventsWithoutPayloadVersion() async throws {
        let transport = AnalyticsClientTestTransport()
        let outboxDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: outboxDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: outboxDirectoryURL)
        }

        let writerClient = makeAnalyticsClient(
            transport: transport,
            nowProvider: { Date(timeIntervalSince1970: 1_715_000_000) },
            outboxDirectoryURL: outboxDirectoryURL
        )
        await writerClient.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .manual,
                stage: .saveSucceeded,
                isEdit: false,
                usesTailscaleAddress: false,
                flowID: nil,
                savedHostCount: 1,
                hostID: nil,
                errorCategory: nil,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: nil,
                portEdited: nil,
                usernameEdited: nil,
                selectedCandidateKind: nil,
                selectedCandidateSource: nil,
                selectedCandidateRank: nil,
                selectedCandidateValue: nil,
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: nil,
                reachabilityFailureSubtype: nil,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )

        let outboxFileURL = outboxDirectoryURL.appendingPathComponent("analytics-outbox.v1.json")
        var persistedOutbox = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: outboxFileURL)) as? [[String: Any]])
        persistedOutbox[0]["payload_version"] = nil
        let legacyOutboxData = try JSONSerialization.data(withJSONObject: persistedOutbox)
        try legacyOutboxData.write(to: outboxFileURL, options: .atomic)

        let client = makeAnalyticsClient(
            transport: transport,
            nowProvider: { Date(timeIntervalSince1970: 1_715_000_100) },
            outboxDirectoryURL: outboxDirectoryURL
        )

        await client.flushPendingEvents()

        #expect(transport.requests.count == 1)
        let requestBody = try #require(transport.requestBodies.first)
        let requestJSON = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let events = try #require(requestJSON["events"] as? [[String: Any]])
        let event = try #require(events.first)
        let payload = try #require(event["payload"] as? [String: Any])

        #expect(event["payload_version"] == nil)
        #expect((payload["flow"] as? [String: Any])?["method"] as? String == "manual")
        #expect((payload["flow"] as? [String: Any])?["stage"] as? String == "save_succeeded")
        #expect((payload["host"] as? [String: Any])?["saved_host_count"] as? Int == 1)
    }

    @Test
    func analyticsClientConcurrentFlushesCoalesce() async throws {
        let transport = AnalyticsClientTestTransport()
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await client.flushPendingEvents()
                }
            }
        }

        #expect(transport.ensureDeviceIdentityCallCount == 1)
        #expect(transport.requests.count == 1)
    }

    @Test
    func analyticsClientQuarantinesSingleValidationRejectedEventAndFlushesLaterEvents() async throws {
        let transport = AnalyticsClientTestTransport { request, body, _ in
            let url = try #require(request.url)
            let requestBody = try #require(body)
            let requestJSON = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let events = try #require(requestJSON["events"] as? [[String: Any]])
            let rejectedEvent = events.first { $0["event_type"] as? String == "host_setup_flow_event" }

            if let rejectedEvent {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 400,
                    body: [
                        "detail": "Analytics host-setup payload is invalid.",
                        "event_id": rejectedEvent["event_id"] as? String ?? "unknown",
                        "event_type": "host_setup_flow_event",
                        "field": "verification",
                        "rule": "failure_requires_stage_and_disconnect_category",
                    ]
                )
            }

            return (
                try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
                Data()
            )
        }
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .automatic,
                stage: .verificationFailed,
                isEdit: false,
                usesTailscaleAddress: false,
                flowID: "flow-rejected",
                savedHostCount: nil,
                hostID: nil,
                errorCategory: .connectionVerification,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: nil,
                portEdited: nil,
                usernameEdited: nil,
                selectedCandidateKind: nil,
                selectedCandidateSource: nil,
                selectedCandidateRank: nil,
                selectedCandidateValue: nil,
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: nil,
                reachabilityFailureSubtype: nil,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )
        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )

        await client.flushPendingEvents()

        #expect(transport.requests.count == 3)
        let sentBatches = try transport.requestBodies.map { body in
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(object["events"] as? [[String: Any]])
        }
        #expect(sentBatches.map(\.count) == [2, 1, 1])
        #expect(sentBatches[1].first?["event_type"] as? String == "host_setup_flow_event")
        #expect(sentBatches[2].first?["event_type"] as? String == "paywall_event")

        await client.flushPendingEvents()
        #expect(transport.requests.count == 3)
    }

    @Test
    func analyticsClientRetryableFailureKeepsEventInOutbox() async throws {
        let transport = AnalyticsClientTestTransport { request, _, transport in
            let url = try #require(request.url)
            if transport.requests.count == 1 {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 500,
                    body: ["detail": "temporary failure"]
                )
            }

            return (
                try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
                Data()
            )
        }
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )

        await client.flushPendingEvents()
        await client.flushPendingEvents()

        #expect(transport.requests.count == 2)
        let eventIDs = try transport.requestBodies.map { body in
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try #require(object["events"] as? [[String: Any]])
            return try #require(events.first?["event_id"] as? String)
        }
        #expect(Set(eventIDs).count == 1)
    }

    @Test
    func analyticsClientPersistsPartialFlushBeforeRetryableFailure() async throws {
        let transport = AnalyticsClientTestTransport { request, body, transport in
            let url = try #require(request.url)
            let requestBody = try #require(body)
            let requestJSON = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let events = try #require(requestJSON["events"] as? [[String: Any]])
            let eventTypes = events.compactMap { $0["event_type"] as? String }

            if let rejectedEvent = events.first(where: { $0["event_type"] as? String == "host_setup_flow_event" }) {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 400,
                    body: [
                        "detail": "Analytics host-setup payload is invalid.",
                        "event_id": rejectedEvent["event_id"] as? String ?? "unknown",
                        "event_type": "host_setup_flow_event",
                        "field": "verification",
                        "rule": "failure_requires_stage_and_disconnect_category",
                    ]
                )
            }

            if eventTypes == ["key_material_event"], transport.requests.count == 5 {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 500,
                    body: ["detail": "temporary failure"]
                )
            }

            return (
                try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
                Data()
            )
        }
        let client = makeAnalyticsClient(
            transport: transport,
            now: Date(timeIntervalSince1970: 1_715_000_000)
        )

        await client.recordPaywall(
            AgenTTYAnalyticsPaywallEvent(stage: .shown, accessState: Self.blockedAnalyticsAccessState)
        )
        await client.recordHostSetupFlow(
            AgenTTYAnalyticsHostSetupFlowEvent(
                method: .automatic,
                stage: .verificationFailed,
                isEdit: false,
                usesTailscaleAddress: false,
                flowID: "flow-rejected",
                savedHostCount: nil,
                hostID: nil,
                errorCategory: .connectionVerification,
                errorMessage: nil,
                detectedUsername: nil,
                detectedUsernameSource: nil,
                usernameSuspicious: nil,
                hostEdited: nil,
                portEdited: nil,
                usernameEdited: nil,
                selectedCandidateKind: nil,
                selectedCandidateSource: nil,
                selectedCandidateRank: nil,
                selectedCandidateValue: nil,
                candidateValues: nil,
                candidateCount: nil,
                highConfidenceCandidateCount: nil,
                allLowConfidenceCandidates: nil,
                hostPlatform: nil,
                hostEnvironmentFlags: [],
                probeAttemptCount: nil,
                reachabilityFailureSubtype: nil,
                verificationAttemptCount: nil,
                verificationFailureStage: nil,
                verificationDisconnectCategory: nil
            )
        )
        await client.recordKeyMaterial(
            AgenTTYAnalyticsKeyMaterialEvent(
                operation: .generate,
                stage: .succeeded,
                keyType: .ed25519,
                failureReason: nil,
                failureDetail: nil
            )
        )

        await client.flushPendingEvents()
        await client.flushPendingEvents()

        #expect(transport.requests.count == 6)
        let sentBatches = try transport.requestBodies.map { body in
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try #require(object["events"] as? [[String: Any]])
            return events.compactMap { $0["event_type"] as? String }
        }
        #expect(sentBatches == [
                ["paywall_event", "host_setup_flow_event", "key_material_event"],
                ["paywall_event"],
                ["host_setup_flow_event", "key_material_event"],
                ["host_setup_flow_event"],
                ["key_material_event"],
                ["key_material_event"],
            ])
    }

    private func makeAnalyticsClient(
        transport: AnalyticsClientTestTransport,
        now: Date
    ) -> AgenTTYAnalyticsClient {
        makeAnalyticsClient(
            transport: transport,
            nowProvider: { now },
            outboxDirectoryURL: nil,
            activeFlushInterval: .seconds(15),
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    private func makeAnalyticsClient(
        transport: AnalyticsClientTestTransport,
        nowProvider: @escaping @Sendable () -> Date,
        outboxDirectoryURL: URL?,
        activeFlushInterval: Duration = .seconds(15),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> AgenTTYAnalyticsClient {
        let identity = AgenTTYAnalyticsResolvedIdentity(
            appTransactionID: "app-transaction-id",
            originalPurchaseDateEpochSeconds: 1_715_000_000,
            bundleID: "com.example.agentty.tests",
            appTransactionEnvironment: .production
        )
        let session = makeRequestHandlerURLSession(handler: transport.handle)
        let resolvedOutboxDirectoryURL = outboxDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)

        return AgenTTYAnalyticsClient(
            flavor: .main,
            urlSession: session,
            fileManager: .default,
            bundle: .main,
            appVersionOverride: "1.0.7",
            buildNumberOverride: "2",
            outboxDirectoryURL: resolvedOutboxDirectoryURL,
            identityResolver: { _, _ in identity },
            deviceIdentityProvider: {
                AgenTTYNotificationDeviceIdentity(
                    deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    deviceSecret: "device-secret"
                )
            },
            deviceIdentityEnsurer: { _, _ in
                transport.incrementEnsureDeviceIdentityCallCount()
            },
            deviceContextProvider: {
                AgenTTYAnalyticsDeviceContext(
                    systemVersion: "26.2",
                    deviceModelIdentifier: "iPhone17,3",
                    deviceFamily: .phone,
                    localeIdentifier: "en_SE",
                    preferredLanguages: ["en-SE", "sv-SE"]
                )
            },
            dateProvider: nowProvider,
            activeFlushInterval: activeFlushInterval,
            sleep: sleep
        )
    }

    @MainActor
    private static var blockedAnalyticsAccessState: AgenTTYAnalyticsAccessState {
        AgenTTYAnalyticsAccessState(
            hasFinishedInitialAccessLoad: true,
            hasLifetimeAccess: false,
            trialExpired: true,
            trialConsumedUsageSeconds: AgenTTYTrialPolicy.usageLimit,
            trialRemainingUsageSeconds: 0,
            interactiveContentAllowed: false,
            gateBlocking: true
        )
    }
}
