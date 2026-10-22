import Foundation

enum AgenTTYSSHRelayError: LocalizedError {
    case invalidRelayHostID
    case invalidResponse
    case relayConnectorOffline
    case unauthorized
    case unexpectedStatusCode(Int)
    case websocketOpenTimedOut
    case resourceLimit(String)

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
        case .unauthorized:
            "Relay backend rejected this device identity."
        case .unexpectedStatusCode(let statusCode):
            "Unexpected relay backend status code: \(statusCode)."
        case .websocketOpenTimedOut:
            "Relay websocket did not open in time."
        }
    }
}

private struct AgenTTYRelayResourceLimit: Decodable {
    let code: String
    let detail: String
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
        do {
            return try await sendIssueRelaySessionRequest(requestBody, baseURL: baseURL)
        } catch AgenTTYSSHRelayError.unauthorized {
            try await deviceIdentityEnsurer(baseURL, urlSession)
            return try await sendIssueRelaySessionRequest(requestBody, baseURL: baseURL)
        }
    }

    private func sendIssueRelaySessionRequest(
        _ requestBody: AgenTTYSSHRelaySessionRequest,
        baseURL: URL
    ) async throws -> AgenTTYSSHRelaySession {
        var request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/ssh-relay-sessions",
            body: requestBody
        )
        request.setValue("1", forHTTPHeaderField: "x-agentty-resource-errors")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYSSHRelayError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                // The shared relay decoder uses convertFromSnakeCase, which turns
                // relay_session_id into relaySessionId and breaks acronym-backed
                // properties like relaySessionID/websocketURL.
                let session = try Self.makeRelaySessionDecoder().decode(
                    AgenTTYSSHRelaySession.self,
                    from: data
                )
                return session
            } catch {
                throw AgenTTYSSHRelayError.invalidResponse
            }
        case 401:
            throw AgenTTYSSHRelayError.unauthorized
        case 403:
            throw AgenTTYSSHRelayError.relayConnectorOffline
        case 429:
            let limit = try? JSONDecoder().decode(AgenTTYRelayResourceLimit.self, from: data)
            throw AgenTTYSSHRelayError.resourceLimit(limit?.detail ?? "Relay request limit reached. Please try again later.")
        default:
            throw AgenTTYSSHRelayError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    private static func makeRelaySessionDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
