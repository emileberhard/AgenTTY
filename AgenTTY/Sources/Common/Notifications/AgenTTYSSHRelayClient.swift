import Foundation

enum AgenTTYSSHRelayError: LocalizedError {
    case invalidRelayHostID
    case invalidResponse
    case relayConnectorOffline
    case unauthorized(AgenTTYBackendError)
    case unexpectedStatusCode(AgenTTYBackendError)
    case websocketOpenTimedOut
    case resourceLimit(String)

    init(_ error: AgenTTYBackendError) {
        switch (error.status, error.code) {
        case (401, _):
            self = .unauthorized(error)
        case (403, nil), (403, "relay_connector_offline"):
            self = .relayConnectorOffline
        case (403, _):
            self = .unauthorized(error)
        case (429, _):
            self = .resourceLimit(error.localizedDescription)
        default:
            self = .unexpectedStatusCode(error)
        }
    }

    var errorDescription: String? {
        switch self {
        case .resourceLimit(let detail):
            detail
        case .invalidRelayHostID:
            "Relay access is not configured for this host."
        case .invalidResponse:
            "Invalid relay backend response."
        case .relayConnectorOffline:
            "Relay connector is offline for this host."
        case .unauthorized(let error), .unexpectedStatusCode(let error):
            error.localizedDescription
        case .websocketOpenTimedOut:
            "Relay websocket did not open in time."
        }
    }
}

private struct AgenTTYSSHRelaySessionRequest: Codable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let relayHostID: String
}

nonisolated struct AgenTTYSSHRelaySession: Codable, Sendable {
    let relaySessionID: String
    let expiresAtEpochSeconds: Int
    let authorizationToken: String
    let websocketURL: String

    private enum CodingKeys: String, CodingKey {
        case relaySessionID = "relay_session_id"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
        case authorizationToken = "authorization_token"
        case websocketURL = "websocket_url"
    }
}

@MainActor
final class AgenTTYSSHRelayClient {
    typealias BaseURLProvider = @Sendable () -> URL
    typealias DeviceIdentityProvider = @Sendable () -> AgenTTYNotificationDeviceIdentity
    typealias DeviceIdentityEnsurer = @Sendable (URL, URLSession) async throws -> Void

    static let shared = AgenTTYSSHRelayClient()

    /// Relay session issuance sits on the critical reconnect path; the
    /// URLSession default 60s request timeout would stall reconnect cycles on
    /// flaky networks far longer than a failed attempt is worth.
    private static let issuanceSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let urlSession: URLSession
    private let baseURLProvider: BaseURLProvider
    private let deviceIdentityProvider: DeviceIdentityProvider
    private let deviceIdentityEnsurer: DeviceIdentityEnsurer

    init(
        urlSession: URLSession = AgenTTYSSHRelayClient.issuanceSession,
        baseURLProvider: @escaping BaseURLProvider = { AgenTTYRelayConfiguration.baseURL },
        deviceIdentityProvider: @escaping DeviceIdentityProvider = {
            AgenTTYRelayTransport.currentDeviceIdentity()
        },
        deviceIdentityEnsurer: @escaping DeviceIdentityEnsurer = { baseURL, urlSession in
            try await AgenTTYRelayTransport.ensureCurrentDeviceIdentity(
                baseURL: baseURL,
                urlSession: urlSession
            )
        }
    ) {
        self.urlSession = urlSession
        self.baseURLProvider = baseURLProvider
        self.deviceIdentityProvider = deviceIdentityProvider
        self.deviceIdentityEnsurer = deviceIdentityEnsurer
    }

    func issueRelaySession(relayHostID: String) async throws -> AgenTTYSSHRelaySession {
        let normalizedRelayHostID = relayHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRelayHostID.isEmpty else {
            throw AgenTTYSSHRelayError.invalidRelayHostID
        }

        let identity = deviceIdentityProvider()
        let requestBody = AgenTTYSSHRelaySessionRequest(
            deviceID: identity.deviceID,
            deviceSecret: identity.deviceSecret,
            relayHostID: normalizedRelayHostID
        )
        let baseURL = baseURLProvider()
        var request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/ssh-relay-sessions",
            body: requestBody
        )
        request.setValue("1", forHTTPHeaderField: "x-agentty-resource-errors")
        let data: Data
        do {
            data = try await sendRepairingDeviceIdentity(request, baseURL: baseURL)
        } catch let error as AgenTTYBackendError {
            throw AgenTTYSSHRelayError(error)
        } catch AgenTTYRelayTransportError.invalidResponse {
            throw AgenTTYSSHRelayError.invalidResponse
        }
        do {
            // The shared relay decoder uses convertFromSnakeCase, which turns
            // relay_session_id into relaySessionId and breaks acronym-backed
            // properties like relaySessionID/websocketURL.
            return try Self.makeRelaySessionDecoder().decode(AgenTTYSSHRelaySession.self, from: data)
        } catch {
            throw AgenTTYSSHRelayError.invalidResponse
        }
    }

    private func sendRepairingDeviceIdentity(_ request: URLRequest, baseURL: URL) async throws -> Data {
        do {
            return try await AgenTTYRelayTransport.send(request, using: urlSession, expecting: 200)
        } catch let error as AgenTTYBackendError where error.status == 401 {
            try await deviceIdentityEnsurer(baseURL, urlSession)
            return try await AgenTTYRelayTransport.send(request, using: urlSession, expecting: 200)
        }
    }

    private static func makeRelaySessionDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
