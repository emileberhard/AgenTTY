import Foundation
import XCTest
@testable import AgenTTY_iOS

private func makePendingAutomaticSetupSession(
    sessionID: String = "session-1",
    keyID: UUID = UUID(uuidString: "9EF63F48-8AE5-41F5-9E73-01A847FF556C")!,
    flowID: String = "flow-1",
    claimedAtEpochSeconds: Int = 1_777_000_000,
    expiresAtEpochSeconds: Int = 1_777_000_600
) -> AgenTTYAutomaticSetupPendingSession {
    AgenTTYAutomaticSetupPendingSession(
        sessionID: sessionID,
        keyID: keyID,
        flowID: flowID,
        claimedAtEpochSeconds: claimedAtEpochSeconds,
        expiresAtEpochSeconds: expiresAtEpochSeconds
    )
}

private func makePendingAutomaticSetupClaim(
    pairingCode: String = "ABCD-EFGH",
    keyID: UUID = UUID(uuidString: "9EF63F48-8AE5-41F5-9E73-01A847FF556C")!,
    flowID: String = "flow-1",
    startedAtEpochSeconds: Int = 1_777_000_000,
    expiresAtEpochSeconds: Int = 1_777_000_600
) -> AgenTTYAutomaticSetupPendingClaim {
    AgenTTYAutomaticSetupPendingClaim(
        pairingCode: pairingCode,
        keyID: keyID,
        flowID: flowID,
        startedAtEpochSeconds: startedAtEpochSeconds,
        expiresAtEpochSeconds: expiresAtEpochSeconds
    )
}

final class RelayAndAutomaticSetupTests: XCTestCase {
    func testAutomaticSetupModeRecommendedCommand() {
        XCTAssertEqual(AgenTTYAutomaticSetupMode.recommended.title, "Full AgenTTY Setup")
        XCTAssertEqual(AgenTTYAutomaticSetupMode.recommended.badge, "Recommended")
        XCTAssertEqual(AgenTTYAutomaticSetupMode.recommended.command, "npx -y @agentty-app/pair")
    }

    func testAutomaticSetupModeDirectOnlyCommand() {
        XCTAssertEqual(AgenTTYAutomaticSetupMode.directOnly.title, "Direct Connection Only")
        XCTAssertNil(AgenTTYAutomaticSetupMode.directOnly.badge)
        XCTAssertEqual(AgenTTYAutomaticSetupMode.directOnly.command, "npx -y @agentty-app/pair --direct-only")
    }

    func testPendingAutomaticSetupStateStoreRoundTripsActiveClaim() {
        let suiteName = "AgenTTYTests.pendingAutomaticSetup.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let claim = makePendingAutomaticSetupClaim()
        AgenTTYAutomaticSetupPendingStateStore.save(.claiming(claim), userDefaults: userDefaults)

        let loaded = AgenTTYAutomaticSetupPendingStateStore.load(
            userDefaults: userDefaults,
            date: Date(timeIntervalSince1970: 1_777_000_100)
        )

        XCTAssertEqual(loaded, .claiming(claim))
    }

    func testPendingAutomaticSetupStateStoreRoundTripsActiveClaimedSession() {
        let suiteName = "AgenTTYTests.pendingAutomaticSetupClaimed.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let session = makePendingAutomaticSetupSession()
        AgenTTYAutomaticSetupPendingStateStore.save(.claimed(session), userDefaults: userDefaults)

        let loaded = AgenTTYAutomaticSetupPendingStateStore.load(
            userDefaults: userDefaults,
            date: Date(timeIntervalSince1970: 1_777_000_100)
        )

        XCTAssertEqual(loaded, .claimed(session))
    }

    func testPendingAutomaticSetupStateStoreClearsExpiredSession() {
        let suiteName = "AgenTTYTests.pendingAutomaticSetupExpired.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let session = makePendingAutomaticSetupSession(expiresAtEpochSeconds: 100)
        AgenTTYAutomaticSetupPendingStateStore.save(.claimed(session), userDefaults: userDefaults)

        let loaded = AgenTTYAutomaticSetupPendingStateStore.load(
            userDefaults: userDefaults,
            date: Date(timeIntervalSince1970: 200)
        )

        XCTAssertNil(loaded)
        XCTAssertNil(userDefaults.data(forKey: "automatic_setup_pending_session"))
    }

    func testPendingAutomaticSetupStateStoreClearsExpiredClaim() {
        let suiteName = "AgenTTYTests.pendingAutomaticSetupClaimExpired.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let claim = makePendingAutomaticSetupClaim(expiresAtEpochSeconds: 100)
        AgenTTYAutomaticSetupPendingStateStore.save(.claiming(claim), userDefaults: userDefaults)

        let loaded = AgenTTYAutomaticSetupPendingStateStore.load(
            userDefaults: userDefaults,
            date: Date(timeIntervalSince1970: 200)
        )

        XCTAssertNil(loaded)
        XCTAssertNil(userDefaults.data(forKey: "automatic_setup_pending_session"))
    }

    func testPendingAutomaticSetupStateStoreLoadsLegacyClaimedSessionPayload() throws {
        let suiteName = "AgenTTYTests.pendingAutomaticSetupLegacy.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let session = makePendingAutomaticSetupSession()
        let encodedLegacySession = try JSONEncoder().encode(session)
        userDefaults.set(encodedLegacySession, forKey: "automatic_setup_pending_session")

        let loaded = AgenTTYAutomaticSetupPendingStateStore.load(
            userDefaults: userDefaults,
            date: Date(timeIntervalSince1970: 1_777_000_100)
        )

        XCTAssertEqual(loaded, .claimed(session))
    }

    @MainActor
    func testPairingRelayClientRetriesUnauthorizedClaimAfterEnsuringIdentity() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            deviceSecret: "device-secret"
        )
        let transport = PairingClientTestTransport { request, transport in
            let url = try XCTUnwrap(request.url)
            switch url.path {
            case "/v1/pairing-sessions/claim":
                let attempt = transport.incrementClaimAttemptCount()
                if attempt == 1 {
                    return try makeJSONResponse(
                        url: url,
                        statusCode: 401,
                        body: ["error": "unauthorized"]
                    )
                }
                return try makeJSONResponse(
                    url: url,
                    statusCode: 200,
                    body: [
                        "session_id": "session-1",
                        "expires_at_epoch_seconds": 123,
                    ]
                )
            default:
                throw NSError(domain: "PairingClientTestTransport", code: 1)
            }
        }
        let client = AgenTTYPairingRelayClient(
            urlSession: makeRequestHandlerURLSession(handler: transport.handle),
            baseURLProvider: { baseURL },
            deviceIdentityProvider: { identity },
            deviceIdentityEnsurer: { _, _, _ in
                transport.incrementEnsureDeviceIdentityCallCount()
            }
        )

        let claim = try await client.claimPairingSession(
            code: "ABCD-EFGH",
            publicKey: "ssh-ed25519 AAAATEST test"
        )

        XCTAssertEqual(claim.sessionID, "session-1")
        XCTAssertEqual(claim.expiresAtEpochSeconds, 123)
        XCTAssertEqual(transport.claimAttemptCount, 2)
        XCTAssertEqual(transport.ensureDeviceIdentityCallCount, 1)

        let claimRequests = transport.requests.filter { $0.url?.path == "/v1/pairing-sessions/claim" }
        XCTAssertEqual(claimRequests.count, 2)

        let firstBody = try jsonObject(from: try XCTUnwrap(claimRequests.first))
        XCTAssertEqual(firstBody["code"] as? String, "ABCD-EFGH")
        XCTAssertEqual(firstBody["public_key"] as? String, "ssh-ed25519 AAAATEST test")
        XCTAssertEqual(firstBody["device_id"] as? String, identity.deviceID.uuidString)
        XCTAssertEqual(firstBody["device_secret"] as? String, identity.deviceSecret)
    }

    @MainActor
    func testPairingRelayClientFetchStatusPostsIdentityAndDecodesCompletion() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            deviceSecret: "device-secret-2"
        )
        let transport = PairingClientTestTransport { request, _ in
            let url = try XCTUnwrap(request.url)
            switch url.path {
            case "/v1/pairing-sessions/session-1/status":
                return try makeJSONResponse(
                    url: url,
                    statusCode: 200,
                    body: [
                        "session_id": "session-1",
                        "status": "completed",
                        "expires_at_epoch_seconds": 456,
                        "completion": [
                            "detected_username": "developer",
                            "detected_username_source": "env_user",
                            "detected_username_suspicious": false,
                            "hostname_candidates": ["dev-host", "dev-host.local"],
                            "host_candidates": [
                                [
                                    "value": "dev-host",
                                    "kind": "single_label",
                                    "source": "hostname",
                                    "rank": 1,
                                ],
                            ],
                            "host_environment_flags": [],
                            "uses_tailscale": true,
                            "ssh_host_public_keys": ["ssh-ed25519 AAAAHOSTKEY"],
                            "relay_host_id": "relay-host-1",
                            "relay_capable": true,
                            "port": 22,
                            "platform": "macos",
                        ],
                    ]
                )
            default:
                throw NSError(domain: "PairingClientTestTransport", code: 1)
            }
        }
        let client = AgenTTYPairingRelayClient(
            urlSession: makeRequestHandlerURLSession(handler: transport.handle),
            baseURLProvider: { baseURL },
            deviceIdentityProvider: { identity }
        )

        let status = try await client.fetchPairingSessionStatus(sessionID: "session-1")

        XCTAssertEqual(status.sessionID, "session-1")
        XCTAssertEqual(status.status, .completed)
        XCTAssertEqual(status.expiresAtEpochSeconds, 456)
        let completion = try XCTUnwrap(status.completion)
        XCTAssertEqual(completion.detectedUsername, "developer")
        XCTAssertEqual(completion.hostnameCandidates, ["dev-host", "dev-host.local"])
        XCTAssertEqual(completion.sshHostPublicKeys, ["ssh-ed25519 AAAAHOSTKEY"])
        XCTAssertEqual(completion.relayHostID, "relay-host-1")
        XCTAssertEqual(completion.relayCapable, true)
        XCTAssertEqual(completion.port, 22)
        XCTAssertEqual(completion.platform, "macos")
        XCTAssertTrue(completion.shouldUseTailscale)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://agentty.esmadil.se/v1/pairing-sessions/session-1/status"
        )
        let requestBody = try jsonObject(from: request)
        XCTAssertEqual(requestBody["device_id"] as? String, identity.deviceID.uuidString)
        XCTAssertEqual(requestBody["device_secret"] as? String, identity.deviceSecret)
    }

    @MainActor
    func testSSHRelayClientPostsIdentityAndRelayHostIDAndDecodesResponse() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!,
            deviceSecret: "relay-device-secret"
        )
        var capturedRequests: [URLRequest] = []
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                capturedRequests.append(request)
                let url = try XCTUnwrap(request.url)
                return try makeJSONResponse(
                    url: url,
                    statusCode: 200,
                    body: [
                        "relay_session_id": "relay-session-1",
                        "expires_at_epoch_seconds": 123,
                        "authorization_token": "relay-token-1",
                        "websocket_url": "wss://agentty.esmadil.se/v1/ssh-relay-sessions/relay-session-1/ws",
                    ]
                )
            },
            baseURLProvider: { baseURL },
            deviceIdentityProvider: { identity }
        )

        let session = try await client.issueRelaySession(relayHostID: "relay-host-1")

        XCTAssertEqual(session.relaySessionID, "relay-session-1")
        XCTAssertEqual(session.expiresAtEpochSeconds, 123)
        XCTAssertEqual(session.authorizationToken, "relay-token-1")
        XCTAssertEqual(
            session.websocketURL,
            "wss://agentty.esmadil.se/v1/ssh-relay-sessions/relay-session-1/ws"
        )

        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://agentty.esmadil.se/v1/ssh-relay-sessions")
        let body = try jsonObject(from: request)
        XCTAssertEqual(body["device_id"] as? String, identity.deviceID.uuidString)
        XCTAssertEqual(body["device_secret"] as? String, identity.deviceSecret)
        XCTAssertEqual(body["relay_host_id"] as? String, "relay-host-1")
    }

    @MainActor
    func testSSHRelayClientRetriesUnauthorizedAfterEnsuringIdentity() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "88888888-2222-3333-4444-555555555555")!,
            deviceSecret: "relay-device-secret-2"
        )
        let transport = PairingClientTestTransport { request, transport in
            let url = try XCTUnwrap(request.url)
            let attempt = transport.incrementClaimAttemptCount()
            if attempt == 1 {
                return try makeJSONResponse(
                    url: url,
                    statusCode: 401,
                    body: ["error": "unauthorized"]
                )
            }
            return try makeJSONResponse(
                url: url,
                statusCode: 200,
                body: [
                    "relay_session_id": "relay-session-2",
                    "expires_at_epoch_seconds": 456,
                    "authorization_token": "relay-token-2",
                    "websocket_url": "wss://agentty.esmadil.se/v1/ssh-relay-sessions/relay-session-2/ws",
                ]
            )
        }
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession(handler: transport.handle),
            baseURLProvider: { baseURL },
            deviceIdentityProvider: { identity },
            deviceIdentityEnsurer: { _, _ in
                transport.incrementEnsureDeviceIdentityCallCount()
            }
        )

        let session = try await client.issueRelaySession(relayHostID: "relay-host-2")

        XCTAssertEqual(session.relaySessionID, "relay-session-2")
        XCTAssertEqual(transport.claimAttemptCount, 2)
        XCTAssertEqual(transport.ensureDeviceIdentityCallCount, 1)
    }

    @MainActor
    func testSSHRelayClientMapsForbiddenToRelayConnectorOffline() async {
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                let url = try XCTUnwrap(request.url)
                return try makeJSONResponse(
                    url: url,
                    statusCode: 403,
                    body: ["error": "connector offline"]
                )
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await client.issueRelaySession(relayHostID: "relay-host-3")
        ) { error in
            guard case AgenTTYSSHRelayError.relayConnectorOffline = error else {
                return XCTFail("Expected relayConnectorOffline, got \(error)")
            }
        }
    }
    @MainActor
    func testSSHRelayClientSurfacesTypedResourceLimitWithoutIdentityRepair() async {
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-agentty-resource-errors"), "1")
                return try makeJSONResponse(url: XCTUnwrap(request.url), statusCode: 429, body: ["code": "relay_bandwidth", "detail": "Relay data allowance reached."])
            },
            deviceIdentityEnsurer: { _, _ in XCTFail("A resource limit must not repair device identity") }
        )
        await XCTAssertThrowsErrorAsync(try await client.issueRelaySession(relayHostID: "relay-host")) { error in
            guard case AgenTTYSSHRelayError.resourceLimit(let detail) = error else {
                return XCTFail("Expected resource limit, got \(error)")
            }
            XCTAssertEqual(detail, "Relay data allowance reached.")
        }
    }

}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
