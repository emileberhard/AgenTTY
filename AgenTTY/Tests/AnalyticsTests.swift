import Foundation
import XCTest
@testable import AgenTTY_iOS

final class AnalyticsTests: XCTestCase {
    @MainActor
    func testSaveSucceededUnverifiedAnalyticsIncludesVerificationFailure() {
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

        XCTAssertEqual(outcome.stage, .saveSucceededUnverified)
        XCTAssertEqual(outcome.verificationAttemptCount, 1)
        XCTAssertEqual(outcome.verificationFailureOutcome, verificationFailure)
    }

    @MainActor
    func testSaveSucceededUnreachableAnalyticsDoesNotAttachVerificationPayload() {
        let outcome = HostSetupSaveAnalyticsOutcome(
            overrideValidationWarning: true,
            verificationFailureOutcome: nil
        )

        XCTAssertEqual(outcome.stage, .saveSucceededUnreachable)
        XCTAssertNil(outcome.verificationAttemptCount)
        XCTAssertNil(outcome.verificationFailureOutcome)
    }

    @MainActor
    func testAnalyticsHostSetupPayloadEncodesStructuredDiagnosticsKeys() throws {
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
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        let flow = try XCTUnwrap(object["flow"] as? [String: Any])
        let detectedUsername = try XCTUnwrap(object["detected_username"] as? [String: Any])
        let candidates = try XCTUnwrap(object["candidates"] as? [String: Any])
        let selectedCandidate = try XCTUnwrap(candidates["selected"] as? [String: Any])
        let hostEnvironment = try XCTUnwrap(object["host_environment"] as? [String: Any])

        XCTAssertEqual(context["app_session_id"] as? String, "app-session-1")
        XCTAssertEqual(flow["id"] as? String, "flow-1")
        XCTAssertEqual(detectedUsername["source"] as? String, "whoami_command")
        XCTAssertEqual(selectedCandidate["source"] as? String, "hostname")
        XCTAssertEqual(candidates["count"] as? Int, 1)
        XCTAssertEqual(candidates["all_low_confidence"] as? Bool, true)
        XCTAssertEqual(hostEnvironment["platform"] as? String, "linux")
        XCTAssertEqual(hostEnvironment["flags"] as? [String], ["wsl"])
    }

    @MainActor
    func testAnalyticsHostSetupPayloadEncodesVerificationFields() throws {
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
        let flow = try XCTUnwrap(object["flow"] as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        let verification = try XCTUnwrap(object["verification"] as? [String: Any])

        XCTAssertEqual(flow["stage"] as? String, "verification_failed")
        XCTAssertEqual(error["category"] as? String, "connection_verification")
        XCTAssertEqual(verification["attempt_count"] as? Int, 2)
        XCTAssertEqual(verification["failure_stage"] as? String, "ssh_auth")
        XCTAssertEqual(verification["disconnect_category"] as? String, "auth_failed")
    }

    func testAnalyticsHashingIsDeterministic() {
        XCTAssertEqual(
            AgenTTYAnalyticsHashing.sha256Hex("host-id"),
            AgenTTYAnalyticsHashing.sha256Hex("host-id")
        )
        XCTAssertNotEqual(
            AgenTTYAnalyticsHashing.sha256Hex("host-id"),
            AgenTTYAnalyticsHashing.sha256Hex("host-id-2")
        )
    }

    @MainActor
    func testExpiredTrialPreviewProducesBlockedAnalyticsAccessState() {
        let state = AgenTTYLifetimeAccessController.previewExpiredTrial().analyticsAccessState

        XCTAssertFalse(state.hasLifetimeAccess)
        XCTAssertTrue(state.trialExpired)
        XCTAssertEqual(state.trialRemainingUsageSeconds, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(
            state.trialConsumedUsageSeconds,
            AgenTTYTrialPolicy.usageLimit,
            accuracy: 0.000_000_1
        )
    }

    @MainActor
    func testUnlockedPreviewProducesUnlockedAnalyticsAccessState() {
        let state = AgenTTYLifetimeAccessController.previewUnlocked().analyticsAccessState

        XCTAssertTrue(state.hasLifetimeAccess)
        XCTAssertFalse(state.trialExpired)
        XCTAssertEqual(state.trialConsumedUsageSeconds, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(state.trialRemainingUsageSeconds, 0, accuracy: 0.000_000_1)
    }

    func testAnalyticsClientFlushEncodesDeviceContextAndRicherEvents() async throws {
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

        XCTAssertEqual(transport.ensureDeviceIdentityCallCount, 1)
        XCTAssertEqual(transport.requests.count, 1)

        let requestBody = try XCTUnwrap(transport.requestBodies.first)
        let requestJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )

        XCTAssertEqual(requestJSON["device_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(requestJSON["device_secret"] as? String, "device-secret")

        let deviceContext = try XCTUnwrap(requestJSON["device_context"] as? [String: Any])
        XCTAssertEqual(deviceContext["system_version"] as? String, "26.2")
        XCTAssertEqual(deviceContext["device_model_identifier"] as? String, "iPhone17,3")
        XCTAssertEqual(deviceContext["device_family"] as? String, "phone")
        XCTAssertEqual(deviceContext["locale_identifier"] as? String, "en_SE")
        XCTAssertEqual(deviceContext["preferred_languages"] as? [String], ["en-SE", "sv-SE"])

        let events = try XCTUnwrap(requestJSON["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy { $0["payload_version"] as? Int == 2 })

        let payloadObjects = events.compactMap { $0["payload"] as? [String: Any] }
        XCTAssertEqual(payloadObjects.count, 3)
        XCTAssertTrue(payloadObjects.contains(where: { payload in
            let flow = payload["flow"] as? [String: Any]
            return flow?["stage"] as? String == "save_succeeded"
        }))
        XCTAssertTrue(payloadObjects.contains(where: { $0["stage"] as? String == "shown" }))
        XCTAssertTrue(
            payloadObjects.contains(where: { payload in
                let disconnect = payload["disconnect"] as? [String: Any]
                let input = payload["input"] as? [String: Any]
                return disconnect?["category"] as? String == "shell_closed"
                    && input?["event_count"] as? Int == 3
            })
        )
    }

    func testAnalyticsClientHostSetupFlowEncodesExtendedAutomaticSetupFields() async throws {
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

        let requestBody = try XCTUnwrap(transport.requestBodies.first)
        let requestJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let events = try XCTUnwrap(requestJSON["events"] as? [[String: Any]])
        let hostSetupPayload = try XCTUnwrap(events.first?["payload"] as? [String: Any])

        let edits = try XCTUnwrap(hostSetupPayload["edits"] as? [String: Any])
        let candidates = try XCTUnwrap(hostSetupPayload["candidates"] as? [String: Any])
        let reachability = try XCTUnwrap(hostSetupPayload["reachability"] as? [String: Any])
        let error = try XCTUnwrap(hostSetupPayload["error"] as? [String: Any])

        XCTAssertEqual(edits["host"] as? Bool, true)
        XCTAssertEqual(edits["port"] as? Bool, false)
        XCTAssertEqual(edits["username"] as? Bool, true)
        XCTAssertEqual((candidates["selected"] as? [String: Any])?["kind"] as? String, "local_domain")
        XCTAssertEqual(reachability["attempt_count"] as? Int, 2)
        XCTAssertEqual(reachability["failure_subtype"] as? String, "dns")
        XCTAssertEqual(error["category"] as? String, "reachability")
    }

    func testAnalyticsClientAppSessionCompletedIncludesSessionCounters() async throws {
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

        XCTAssertGreaterThanOrEqual(transport.requests.count, 1)

        let appSessionEvent = try XCTUnwrap(
            try transport.requestBodies
                .compactMap { requestBody in
                    try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
                }
                .compactMap { $0["events"] as? [[String: Any]] }
                .flatMap { $0 }
                .first(where: { $0["event_type"] as? String == "app_session_completed" })
        )
        let payload = try XCTUnwrap(appSessionEvent["payload"] as? [String: Any])
        let session = try XCTUnwrap(payload["session"] as? [String: Any])

        XCTAssertEqual(session["saved_host_count"] as? Int, 2)
        XCTAssertEqual(session["active_host_present"] as? Bool, true)
        XCTAssertEqual(session["had_paywall_visible"] as? Bool, true)
        XCTAssertEqual(session["ssh_session_count"] as? Int, 1)
        XCTAssertEqual(session["ready_ssh_session_count"] as? Int, 1)
        XCTAssertEqual(session["had_terminal_input"] as? Bool, true)
        XCTAssertEqual(session["duration_seconds"] as? Int, 90)
    }

    func testAnalyticsClientFlushesPendingEventsWhileSceneRemainsActive() async throws {
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

        XCTAssertEqual(transport.requests.count, 1)

        await client.setSceneActive(
            false,
            accessState: Self.blockedAnalyticsAccessState,
            savedHostCount: 1,
            activeHostPresent: true
        )
    }

    func testAnalyticsClientFlushLoadsLegacyOutboxEventsWithoutPayloadVersion() async throws {
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
        var persistedOutbox = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: outboxFileURL)) as? [[String: Any]]
        )
        persistedOutbox[0]["payload_version"] = nil
        let legacyOutboxData = try JSONSerialization.data(withJSONObject: persistedOutbox)
        try legacyOutboxData.write(to: outboxFileURL, options: .atomic)

        let client = makeAnalyticsClient(
            transport: transport,
            nowProvider: { Date(timeIntervalSince1970: 1_715_000_100) },
            outboxDirectoryURL: outboxDirectoryURL
        )

        await client.flushPendingEvents()

        XCTAssertEqual(transport.requests.count, 1)
        let requestBody = try XCTUnwrap(transport.requestBodies.first)
        let requestJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let events = try XCTUnwrap(requestJSON["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])

        XCTAssertNil(event["payload_version"])
        XCTAssertEqual((payload["flow"] as? [String: Any])?["method"] as? String, "manual")
        XCTAssertEqual((payload["flow"] as? [String: Any])?["stage"] as? String, "save_succeeded")
        XCTAssertEqual((payload["host"] as? [String: Any])?["saved_host_count"] as? Int, 1)
    }

    func testAnalyticsClientConcurrentFlushesCoalesce() async throws {
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

        XCTAssertEqual(transport.ensureDeviceIdentityCallCount, 1)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAnalyticsClientQuarantinesSingleValidationRejectedEventAndFlushesLaterEvents() async throws {
        let transport = AnalyticsClientTestTransport { request, body, _ in
            let url = try XCTUnwrap(request.url)
            let requestBody = try XCTUnwrap(body)
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let events = try XCTUnwrap(requestJSON["events"] as? [[String: Any]])
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
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
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

        XCTAssertEqual(transport.requests.count, 3)
        let sentBatches = try transport.requestBodies.map { body in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(object["events"] as? [[String: Any]])
        }
        XCTAssertEqual(sentBatches.map(\.count), [2, 1, 1])
        XCTAssertEqual(sentBatches[1].first?["event_type"] as? String, "host_setup_flow_event")
        XCTAssertEqual(sentBatches[2].first?["event_type"] as? String, "paywall_event")

        await client.flushPendingEvents()
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAnalyticsClientRetryableFailureKeepsEventInOutbox() async throws {
        let transport = AnalyticsClientTestTransport { request, _, transport in
            let url = try XCTUnwrap(request.url)
            if transport.requests.count == 1 {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 500,
                    body: ["detail": "temporary failure"]
                )
            }

            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
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

        XCTAssertEqual(transport.requests.count, 2)
        let eventIDs = try transport.requestBodies.map { body in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            return try XCTUnwrap(events.first?["event_id"] as? String)
        }
        XCTAssertEqual(Set(eventIDs).count, 1)
    }

    func testAnalyticsClientPersistsPartialFlushBeforeRetryableFailure() async throws {
        let transport = AnalyticsClientTestTransport { request, body, transport in
            let url = try XCTUnwrap(request.url)
            let requestBody = try XCTUnwrap(body)
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let events = try XCTUnwrap(requestJSON["events"] as? [[String: Any]])
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
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)),
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

        XCTAssertEqual(transport.requests.count, 6)
        let sentBatches = try transport.requestBodies.map { body in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            return events.compactMap { $0["event_type"] as? String }
        }
        XCTAssertEqual(
            sentBatches,
            [
                ["paywall_event", "host_setup_flow_event", "key_material_event"],
                ["paywall_event"],
                ["host_setup_flow_event", "key_material_event"],
                ["host_setup_flow_event"],
                ["key_material_event"],
                ["key_material_event"],
            ]
        )
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
        let bundle = Bundle(for: Self.self)
        let identity = AgenTTYAnalyticsResolvedIdentity(
            appTransactionID: "app-transaction-id",
            originalPurchaseDateEpochSeconds: 1_715_000_000,
            bundleID: bundle.bundleIdentifier ?? "com.example.agentty.tests",
            appTransactionEnvironment: .production
        )
        let session = makeRequestHandlerURLSession(handler: transport.handle)
        let resolvedOutboxDirectoryURL = outboxDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)

        return AgenTTYAnalyticsClient(
            flavor: .main,
            urlSession: session,
            fileManager: .default,
            bundle: bundle,
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
