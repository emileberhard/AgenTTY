import Foundation

enum AgenTTYNotifyRelayPushEnvironment: String, Codable, Sendable {
    case development
    case production
}

nonisolated struct AgenTTYNotifyRelaySession: Codable, Sendable {
    let relayToken: String
    let expiresAtEpochSeconds: Int
}

enum AgenTTYRelayTransportError: LocalizedError, Sendable {
    case missingBundleIdentifier
    case invalidResponse
    case unauthorized
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            "Missing bundle identifier."
        case .invalidResponse:
            "Invalid backend response."
        case .unauthorized:
            "Unauthorized backend request."
        case .unexpectedStatusCode(let statusCode):
            "Unexpected backend status code: \(statusCode)."
        }
    }
}

private struct AgenTTYDeviceRegistrationRequest: Codable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let apnsToken: String
    let bundleID: String
    let pushEnvironment: AgenTTYNotifyRelayPushEnvironment
    let signedAppTransaction: String?
}

nonisolated enum AgenTTYRelayConfiguration {
    private static let defaultBaseURL = AgenTTYBuildConfiguration.relayURL
    // Remove the legacy override key after the renamed backend build is distributed.
    private static let baseURLOverrideEnvironmentKeys = [
        "AGENTTY_BACKEND_URL",
        "AGENTTY_NOTIFY_RELAY_URL",
    ]

    static let baseURL: URL = {
        guard let rawValue = baseURLOverrideEnvironmentKeys.lazy
            .compactMap({ ProcessInfo.processInfo.environment[$0] })
            .first,
              let overrideURL = URL(string: rawValue),
              isAllowedOverrideURL(overrideURL) else {
            return defaultBaseURL
        }
        return overrideURL
    }()

    private static func isAllowedOverrideURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if scheme == "https" {
            return true
        }

        guard scheme == "http" else {
            return false
        }

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

@MainActor
final class AgenTTYNotifyRelayClient {
    static let shared = AgenTTYNotifyRelayClient()
    private static let registrationFingerprintStorageKey = "agentty.notifications.registration-fingerprint.v1"

    private let urlSession: URLSession
    private let userDefaults: UserDefaults

    init(urlSession: URLSession = .shared, userDefaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.userDefaults = userDefaults
    }

    var baseURL: URL {
        AgenTTYRelayConfiguration.baseURL
    }

    func registerPendingDeviceIfPossible(force: Bool = false) async throws -> Bool {
        guard let requestBody = try await currentRegistrationRequest() else {
            EsmaLog.notifications.notice("event=relay_register_skip reason=no_apns_token")
            return false
        }
        let fingerprint = registrationFingerprint(for: requestBody)
        if !force,
           userDefaults.string(forKey: Self.registrationFingerprintStorageKey) == fingerprint {
            EsmaLog.notifications.notice(
                "event=relay_register_skip reason=fingerprint_match bundle=\(requestBody.bundleID, privacy: .public) env=\(requestBody.pushEnvironment.rawValue, privacy: .public)"
            )
            return true
        }

        EsmaLog.notifications.notice(
            "event=relay_register_start bundle=\(requestBody.bundleID, privacy: .public) env=\(requestBody.pushEnvironment.rawValue, privacy: .public) force=\(force)"
        )

        let request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/devices/register",
            body: requestBody
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYRelayTransportError.invalidResponse
        }
        guard httpResponse.statusCode == 204 else {
            throw AgenTTYRelayTransportError.unexpectedStatusCode(httpResponse.statusCode)
        }
        userDefaults.set(fingerprint, forKey: Self.registrationFingerprintStorageKey)
        EsmaLog.notifications.notice("event=relay_register_success status=\(httpResponse.statusCode)")
        return true
    }

    func issueRelaySession() async throws -> AgenTTYNotifyRelaySession? {
        guard try await registerPendingDeviceIfPossible() else {
            EsmaLog.notifications.notice("event=relay_session_skip reason=device_not_registered")
            return nil
        }

        let requestBody = AgenTTYRelayTransport.currentSessionRequest()
        EsmaLog.notifications.notice(
            "event=relay_session_start base_url=\(self.baseURL.absoluteString, privacy: .public)"
        )
        let request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/relay-sessions",
            body: requestBody
        )
        let (data, response) = try await urlSession.data(for: request)
        return try await decodeRelaySessionResponse(
            data: data,
            response: response,
            requestBody: requestBody
        )
    }

    private func decodeRelaySessionResponse(
        data: Data,
        response: URLResponse,
        requestBody: AgenTTYRelaySessionRequest
    ) async throws -> AgenTTYNotifyRelaySession {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYRelayTransportError.invalidResponse
        }
        if httpResponse.statusCode == 200 {
            let session = try AgenTTYRelayTransport.makeDecoder().decode(AgenTTYNotifyRelaySession.self, from: data)
            EsmaLog.notifications.notice(
                "event=relay_session_success expires_at=\(session.expiresAtEpochSeconds) retry=no"
            )
            return session
        }
        if httpResponse.statusCode == 401 {
            EsmaLog.notifications.error("event=relay_session_retry reason=unauthorized")
            _ = try await registerPendingDeviceIfPossible(force: true)
            let retryRequest = try AgenTTYRelayTransport.makeJSONRequest(
                baseURL: baseURL,
                path: "v1/relay-sessions",
                body: requestBody
            )
            let (retryData, retryResponse) = try await urlSession.data(for: retryRequest)
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw AgenTTYRelayTransportError.invalidResponse
            }
            guard retryHTTPResponse.statusCode == 200 else {
                throw AgenTTYRelayTransportError.unexpectedStatusCode(retryHTTPResponse.statusCode)
            }
            let session = try AgenTTYRelayTransport.makeDecoder().decode(AgenTTYNotifyRelaySession.self, from: retryData)
            EsmaLog.notifications.notice(
                "event=relay_session_success expires_at=\(session.expiresAtEpochSeconds) retry=yes"
            )
            return session
        }
        throw AgenTTYRelayTransportError.unexpectedStatusCode(httpResponse.statusCode)
    }

    private func registrationFingerprint(for requestBody: AgenTTYDeviceRegistrationRequest) -> String {
        [
            "app-store-admission-v1",
            requestBody.deviceID.uuidString,
            requestBody.deviceSecret,
            requestBody.apnsToken,
            requestBody.bundleID,
            requestBody.pushEnvironment.rawValue,
        ].joined(separator: "|")
    }

    private func currentRegistrationRequest() async throws -> AgenTTYDeviceRegistrationRequest? {
        guard let apnsToken = APNsTokenStore.pendingToken,
              !apnsToken.isEmpty else {
            return nil
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AgenTTYRelayTransportError.missingBundleIdentifier
        }
        let identity = AgenTTYRelayTransport.currentDeviceIdentity()

        return AgenTTYDeviceRegistrationRequest(
            deviceID: identity.deviceID,
            deviceSecret: identity.deviceSecret,
            apnsToken: apnsToken,
            bundleID: bundleIdentifier,
            pushEnvironment: AgenTTYBuildFlavor.current().notificationPushEnvironment,
            signedAppTransaction: await AgenTTYRelayTransport.signedAppTransaction()
        )
    }

}
