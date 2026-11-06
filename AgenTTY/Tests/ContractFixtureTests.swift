import Foundation
import Testing
@testable import AgenTTY_iOS

private final class ContractFixtureBundleMarker {}

private let fixtureBaseURL = URL(string: "https://relay.example.test")!
private let fixtureIdentity = AgenTTYNotificationDeviceIdentity(
    deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
    deviceSecret: "device-secret"
)

private func fixtureData(_ path: String) throws -> Data {
    let root = try #require(Bundle(for: ContractFixtureBundleMarker.self).url(forResource: "contract-fixtures", withExtension: nil))
    return try Data(contentsOf: root.appending(path: path))
}

private func fixtureObject(_ path: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: fixtureData(path)) as? NSDictionary, "\(path)")
}

private func encodedObject(_ value: some Encodable) throws -> NSDictionary {
    let data = try AgenTTYRelayTransport.makeEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func requestObject(_ request: URLRequest?) throws -> NSDictionary {
    let request = try #require(request)
    let body = try #require(requestBodyData(from: request))
    return try #require(JSONSerialization.jsonObject(with: body) as? NSDictionary)
}

private func fixtureResponse(
    _ request: URLRequest,
    statusCode: Int,
    fixture path: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    return (response, try fixtureData(path))
}

private final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var all: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private struct PairingEnumValues: Decodable {
    let status: [AgenTTYPairingSessionState]
    let detectedUsernameSource: [AgenTTYPairingDetectedUsernameSource]
    let hostEnvironmentFlags: [AgenTTYPairingHostEnvironmentFlag]
    let hostCandidateKind: [AgenTTYPairingHostCandidateKind]
    let hostCandidateSource: [AgenTTYPairingHostCandidateSource]

    private enum CodingKeys: String, CodingKey {
        case status
        case detectedUsernameSource = "detected_username_source"
        case hostEnvironmentFlags = "host_environment_flags"
        case hostCandidateKind = "host_candidate_kind"
        case hostCandidateSource = "host_candidate_source"
    }
}

@Suite
struct ContractFixtureTests {
    @Test
    func requestTypesEncodeToTheirFixtures() throws {
        #expect((try encodedObject(AgenTTYRelayEnsureDeviceRequest(
                deviceID: fixtureIdentity.deviceID,
                deviceSecret: fixtureIdentity.deviceSecret,
                bundleID: "dev.tuist.agentty.iOS.dev",
                pushEnvironment: .development,
                signedAppTransaction: nil
            ))) == (try fixtureObject("devices-ensure/request/ensure.json")))
        #expect((try encodedObject(AgenTTYRelaySessionRequest(
                deviceID: fixtureIdentity.deviceID,
                deviceSecret: fixtureIdentity.deviceSecret
            ))) == (try fixtureObject("relay-sessions/request/notify.json")))
        #expect((try encodedObject(AgenTTYLegacyDictationSessionRequest(
                deviceID: fixtureIdentity.deviceID,
                deviceSecret: fixtureIdentity.deviceSecret
            ))) == (try fixtureObject("relay-sessions/request/unsigned-dictation.json")))
        #expect((try encodedObject(AgenTTYDictationSessionRequest(
                deviceID: fixtureIdentity.deviceID,
                deviceSecret: fixtureIdentity.deviceSecret,
                signedAppTransaction: "signed-app-transaction",
                signedLifetimeTransaction: "signed-lifetime-transaction"
            ))) == (try fixtureObject("dictation-sessions/request/signed.json")))
    }

    @Test
    func responseFixturesDecodeWithTheClientDecoders() throws {
        let decoder = AgenTTYRelayTransport.makeDecoder()
        let notify = try decoder.decode(
            AgenTTYNotifyRelaySession.self,
            from: fixtureData("relay-sessions/response/session.json")
        )
        #expect(notify.relayToken == "relay-token")
        #expect(notify.expiresAtEpochSeconds == 1_800_000_000)

        for (path, tier) in [
            ("dictation-sessions/response/free.json", AgenTTYDictationRelaySession.Tier.free),
            ("dictation-sessions/response/lifetime.json", .lifetime),
        ] {
            let session = try decoder.decode(AgenTTYDictationRelaySession.self, from: fixtureData(path))
            #expect(session.dictationTier == tier, "\(path)")
        }

        let enums = try JSONDecoder().decode(
            PairingEnumValues.self,
            from: fixtureData("pairing-status/response/enum-values.json")
        )
        let raw = try fixtureObject("pairing-status/response/enum-values.json")
        #expect(enums.status.map(\.rawValue) == raw["status"] as? [String])
        #expect(enums.detectedUsernameSource.map(\.rawValue) == raw["detected_username_source"] as? [String])
        #expect(enums.hostEnvironmentFlags.map(\.rawValue) == raw["host_environment_flags"] as? [String])
        #expect(enums.hostCandidateKind.map(\.rawValue) == raw["host_candidate_kind"] as? [String])
        #expect(enums.hostCandidateSource.map(\.rawValue) == raw["host_candidate_source"] as? [String])

        let rejection = AgenTTYAnalyticsValidationRejection(
            status: 400,
            body: try fixtureData("analytics-events/response/validation-error.json")
        )
        #expect(rejection.eventID == "event-1")
        #expect(rejection.eventType == .hostSetupFlowEvent)
        #expect(rejection.field == "saved_host_count")
        #expect(rejection.rule == "positive")
        #expect(rejection.backendError.detail == "Analytics host-setup payload is invalid.")
    }

    @MainActor
    @Test
    func pairingClientMatchesClaimAndStatusFixtures() async throws {
        let requests = CapturedRequests()
        let client = AgenTTYPairingRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                requests.append(request)
                switch request.url?.path {
                case "/v1/pairing-sessions/claim":
                    return try fixtureResponse(request, statusCode: 200, fixture: "pairing-claim/response/claimed.json")
                case "/v1/pairing-sessions/session-1/status":
                    return try fixtureResponse(request, statusCode: 200, fixture: "pairing-status/response/completed.json")
                default:
                    throw URLError(.unsupportedURL)
                }
            },
            baseURLProvider: { fixtureBaseURL },
            deviceIdentityProvider: { fixtureIdentity },
            deviceIdentityEnsurer: { _, _, _ in Issue.record("Fixture responses never reject the device") }
        )

        let claim = try await client.claimPairingSession(
            code: "ABCD-EFGH",
            publicKey: "ssh-ed25519 AAAATEST agentty@fixture"
        )
        let status = try await client.fetchPairingSessionStatus(sessionID: claim.sessionID)

        #expect(claim.sessionID == "session-1")
        #expect(claim.expiresAtEpochSeconds == 1_800_000_000)
        #expect(status.status == .completed)
        let completion = try #require(status.completion)
        #expect(completion.detectedUsername == "developer")
        #expect(completion.detectedUsernameSource == .accountLookup)
        #expect(completion.hostCandidates.first?.kind == .localDomain)
        #expect(completion.hostEnvironmentFlags == [.wsl])
        #expect(completion.relayHostID == "relay-host-1")
        #expect(completion.platform == "linux")

        #expect((try requestObject(requests.all.first)) == (try fixtureObject("pairing-claim/request/claim.json")))
        #expect((try requestObject(requests.all.last)) == (try fixtureObject("pairing-status/request/status.json")))
    }

    @MainActor
    @Test
    func pairingClaimRejectionShowsTheBackendDetail() async throws {
        let client = AgenTTYPairingRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                try fixtureResponse(request, statusCode: 400, fixture: "pairing-claim/response/invalid-code-error.json")
            },
            baseURLProvider: { fixtureBaseURL },
            deviceIdentityProvider: { fixtureIdentity }
        )

        do {
            _ = try await client.claimPairingSession(code: "ABCD-EFGH", publicKey: "ssh-ed25519 AAAATEST agentty@fixture")
            Issue.record("Expected the claim to be rejected")
        } catch {
            #expect(error.localizedDescription == "Invalid or unavailable pairing code.")
        }
    }

    @MainActor
    @Test
    func sshRelayClientMatchesSessionFixtures() async throws {
        let requests = CapturedRequests()
        let client = AgenTTYSSHRelayClient(
            urlSession: makeRequestHandlerURLSession { request in
                requests.append(request)
                return try fixtureResponse(request, statusCode: 200, fixture: "ssh-relay-sessions/response/session.json")
            },
            baseURLProvider: { fixtureBaseURL },
            deviceIdentityProvider: { fixtureIdentity }
        )

        let session = try await client.issueRelaySession(relayHostID: "relay-host-1")

        #expect(session.relaySessionID == "relay-session-1")
        #expect(session.expiresAtEpochSeconds == 1_800_000_000)
        #expect(session.authorizationToken == "relay-authorization-token")
        #expect(session.websocketURL == "wss://relay.example.test/v1/ssh-relay-sessions/relay-session-1/ws")
        #expect((try requestObject(requests.all.first)) == (try fixtureObject("ssh-relay-sessions/request/session.json")))
    }

    @MainActor
    @Test
    func sshRelayRejectionsMapByCode() async throws {
        for (status, path) in [
            (403, "ssh-relay-sessions/response/connector-offline-error.json"),
            (403, "ssh-relay-sessions/response/not-allowed-error.json"),
            (403, "ssh-relay-sessions/response/verification-required-error.json"),
            (503, "pairing-claim/response/invalid-code-error.json"),
        ] {
            let client = AgenTTYSSHRelayClient(
                urlSession: makeRequestHandlerURLSession { request in
                    try fixtureResponse(request, statusCode: status, fixture: path)
                },
                baseURLProvider: { fixtureBaseURL },
                deviceIdentityProvider: { fixtureIdentity }
            )
            do {
                _ = try await client.issueRelaySession(relayHostID: "relay-host-1")
                Issue.record("Expected \(path) to be rejected")
            } catch let error as AgenTTYSSHRelayError {
                let detail = try fixtureObject(path)["detail"] as? String
                switch (status, error) {
                case (403, .relayConnectorOffline):
                    #expect(path == "ssh-relay-sessions/response/connector-offline-error.json")
                case (403, .unauthorized(let backendError)):
                    #expect(path == "ssh-relay-sessions/response/not-allowed-error.json")
                    #expect(error.localizedDescription == detail)
                    #expect(backendError.detail == detail)
                case (403, .verificationRequired(let backendError)):
                    #expect(path == "ssh-relay-sessions/response/verification-required-error.json")
                    #expect(error.localizedDescription == detail)
                    #expect(backendError.detail == detail)
                case (503, .unexpectedStatusCode):
                    #expect(error.localizedDescription == AgenTTYBackendError.temporarilyUnavailableMessage)
                default:
                    Issue.record("\(path) mapped to \(error)")
                }
            }
        }
    }

    @MainActor
    @Test
    func pairingCodesNormalizeLikeTheBackend() {
        let cases: [(String, String?)] = [
            ("abcd-efgh", "ABCD-EFGH"),
            (" ABCD EFGH\n", "ABCD-EFGH"),
            ("abcdefgh", "ABCD-EFGH"),
            ("agentty://pair?code=abcd-efgh", "ABCD-EFGH"),
            ("agentty://pair?session=1", nil),
            ("ABCD-EFG", nil),
            ("ABCD-EFGHI", nil),
            ("ÅBCD-EFGH", nil),
            ("", nil),
        ]
        for (input, expected) in cases {
            #expect(AgenTTYPairingRelayClient.pairingCode(from: input) == expected, "\(input)")
        }
    }
}
