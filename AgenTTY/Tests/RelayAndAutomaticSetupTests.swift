import Foundation
import Testing
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

@Suite
struct RelayAndAutomaticSetupTests {
    @Test
    func automaticSetupModeRecommendedCommand() {
        #expect(AgenTTYAutomaticSetupMode.recommended.title == "Full AgenTTY Setup")
        #expect(AgenTTYAutomaticSetupMode.recommended.badge == "Recommended")
        #expect(AgenTTYAutomaticSetupMode.recommended.command == "npx -y @agentty-app/pair")
    }

    @Test
    func automaticSetupModeDirectOnlyCommand() {
        #expect(AgenTTYAutomaticSetupMode.directOnly.title == "Direct Connection Only")
        #expect(AgenTTYAutomaticSetupMode.directOnly.badge == nil)
        #expect(AgenTTYAutomaticSetupMode.directOnly.command == "npx -y @agentty-app/pair --direct-only")
    }

    @Test
    func pendingAutomaticSetupStateStoreRoundTripsActiveClaim() {
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

        #expect(loaded == .claiming(claim))
    }

    @Test
    func pendingAutomaticSetupStateStoreRoundTripsActiveClaimedSession() {
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

        #expect(loaded == .claimed(session))
    }

    @Test
    func pendingAutomaticSetupStateStoreClearsExpiredSession() {
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

        #expect(loaded == nil)
        #expect(userDefaults.data(forKey: "automatic_setup_pending_session") == nil)
    }

    @Test
    func pendingAutomaticSetupStateStoreClearsExpiredClaim() {
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

        #expect(loaded == nil)
        #expect(userDefaults.data(forKey: "automatic_setup_pending_session") == nil)
    }

    @Test
    func pendingAutomaticSetupStateStoreLoadsLegacyClaimedSessionPayload() throws {
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

        #expect(loaded == .claimed(session))
    }

    @MainActor
    @Test
    func pairingRelayClientRetriesUnauthorizedClaimAfterEnsuringIdentity() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            deviceSecret: "device-secret"
        )
        let transport = PairingClientTestTransport { request, transport in
            let url = try #require(request.url)
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

        #expect(claim.sessionID == "session-1")
        #expect(claim.expiresAtEpochSeconds == 123)
        #expect(transport.claimAttemptCount == 2)
        #expect(transport.ensureDeviceIdentityCallCount == 1)

        let claimRequests = transport.requests.filter { $0.url?.path == "/v1/pairing-sessions/claim" }
        #expect(claimRequests.count == 2)

        let firstBody = try jsonObject(from: try #require(claimRequests.first))
        #expect(firstBody["code"] as? String == "ABCD-EFGH")
        #expect(firstBody["public_key"] as? String == "ssh-ed25519 AAAATEST test")
        #expect(firstBody["device_id"] as? String == identity.deviceID.uuidString)
        #expect(firstBody["device_secret"] as? String == identity.deviceSecret)
    }

    @MainActor
    @Test
    func sshRelayClientRetriesUnauthorizedAfterEnsuringIdentity() async throws {
        let baseURL = URL(string: "https://agentty.esmadil.se")!
        let identity = AgenTTYNotificationDeviceIdentity(
            deviceID: UUID(uuidString: "88888888-2222-3333-4444-555555555555")!,
            deviceSecret: "relay-device-secret-2"
        )
        let transport = PairingClientTestTransport { request, transport in
            let url = try #require(request.url)
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

        #expect(session.relaySessionID == "relay-session-2")
        #expect(transport.claimAttemptCount == 2)
        #expect(transport.ensureDeviceIdentityCallCount == 1)
    }

    @MainActor
    @Test
    func sshRelayClientMapsUncodedForbiddenToRelayConnectorOffline() async throws {
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                let url = try #require(request.url)
                return try makeJSONResponse(
                    url: url,
                    statusCode: 403,
                    body: ["error": "connector offline"]
                )
            }
        )

        let error = try await #require(throws: AgenTTYSSHRelayError.self) {
            try await client.issueRelaySession(relayHostID: "relay-host-3")
        }
        guard case .relayConnectorOffline = error else {
            Issue.record("Expected relayConnectorOffline, got \(error)")
            return
        }
    }
    @MainActor
    @Test
    func sshRelayClientSurfacesTypedResourceLimitWithoutIdentityRepair() async throws {
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                #expect(request.value(forHTTPHeaderField: "x-agentty-resource-errors") == "1")
                return try makeJSONResponse(url: #require(request.url), statusCode: 429, body: ["code": "relay_bandwidth", "detail": "Relay data allowance reached."])
            },
            deviceIdentityEnsurer: { _, _ in Issue.record("A resource limit must not repair device identity") }
        )
        let error = try await #require(throws: AgenTTYSSHRelayError.self) {
            try await client.issueRelaySession(relayHostID: "relay-host")
        }
        guard case .resourceLimit(let detail) = error else {
            Issue.record("Expected resource limit, got \(error)")
            return
        }
        #expect(detail == "Relay data allowance reached.")
    }

}
