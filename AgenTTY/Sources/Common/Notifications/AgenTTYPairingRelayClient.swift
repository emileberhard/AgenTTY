import Foundation

enum AgenTTYPairingSessionState: String, Codable, Sendable {
    case pending
    case claimed
    case completed
    case failed
    case expired
}

struct AgenTTYClaimedPairingSession: Decodable, Sendable {
    let sessionID: String
    let expiresAtEpochSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
    }
}

struct AgenTTYPairingSessionCompletionMetadata: Decodable, Sendable {
    let detectedUsername: String?
    let detectedUsernameSource: AgenTTYPairingDetectedUsernameSource?
    let detectedUsernameSuspicious: Bool?
    let hostCandidates: [AgenTTYPairingHostCandidate]
    let hostEnvironmentFlags: [AgenTTYPairingHostEnvironmentFlag]
    let hostnameCandidates: [String]
    let usesTailscale: Bool?
    let sshHostPublicKeys: [String]
    let relayHostID: String?
    let relayCapable: Bool?
    let port: Int?
    let platform: String?
    let errorMessage: String?

    var shouldUseTailscale: Bool {
        usesTailscale ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case detectedUsername = "detected_username"
        case detectedUsernameSource = "detected_username_source"
        case detectedUsernameSuspicious = "detected_username_suspicious"
        case hostCandidates = "host_candidates"
        case hostEnvironmentFlags = "host_environment_flags"
        case hostnameCandidates = "hostname_candidates"
        case usesTailscale = "uses_tailscale"
        case sshHostPublicKeys = "ssh_host_public_keys"
        case relayHostID = "relay_host_id"
        case relayCapable = "relay_capable"
        case port
        case platform
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectedUsername = try container.decodeIfPresent(String.self, forKey: .detectedUsername)
        detectedUsernameSource = try container.decodeIfPresent(
            AgenTTYPairingDetectedUsernameSource.self,
            forKey: .detectedUsernameSource
        )
        detectedUsernameSuspicious = try container.decodeIfPresent(
            Bool.self,
            forKey: .detectedUsernameSuspicious
        )
        hostCandidates = try container.decodeIfPresent(
            [AgenTTYPairingHostCandidate].self,
            forKey: .hostCandidates
        ) ?? []
        hostEnvironmentFlags = try container.decodeIfPresent(
            [AgenTTYPairingHostEnvironmentFlag].self,
            forKey: .hostEnvironmentFlags
        ) ?? []
        hostnameCandidates = try container.decodeIfPresent([String].self, forKey: .hostnameCandidates) ?? []
        usesTailscale = try container.decodeIfPresent(Bool.self, forKey: .usesTailscale)
        sshHostPublicKeys = try container.decodeIfPresent([String].self, forKey: .sshHostPublicKeys) ?? []
        relayHostID = try container.decodeIfPresent(String.self, forKey: .relayHostID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        relayCapable = try container.decodeIfPresent(Bool.self, forKey: .relayCapable)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

struct AgenTTYPairingSessionStatusResponse: Decodable, Sendable {
    let sessionID: String
    let status: AgenTTYPairingSessionState
    let expiresAtEpochSeconds: Int
    let completion: AgenTTYPairingSessionCompletionMetadata?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
        case completion
    }
}

enum AgenTTYPairingRelayError: LocalizedError {
    case deviceIdentityRejected
    case invalidResponse
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .deviceIdentityRejected:
            "This iPhone could not be authorized with the pairing relay. Please try automatic setup again in a few seconds."
        case .invalidResponse:
            "Invalid pairing backend response."
        case .unexpectedStatusCode(let statusCode):
            "Unexpected pairing backend status code: \(statusCode)."
        }
    }
}

private struct AgenTTYPairingSessionCreateRequest: Codable, Sendable {
    let code: String
    let deviceID: UUID
    let deviceSecret: String
    let publicKey: String

    private enum CodingKeys: String, CodingKey {
        case code
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
        case publicKey = "public_key"
    }
}

@MainActor
final class AgenTTYPairingRelayClient {
    typealias BaseURLProvider = @Sendable () -> URL
    typealias DeviceIdentityProvider = @Sendable () -> AgenTTYNotificationDeviceIdentity
    typealias DeviceIdentityEnsurer = @Sendable (
        AgenTTYNotificationDeviceIdentity,
        URL,
        URLSession
    ) async throws -> Void

    static let shared = AgenTTYPairingRelayClient()

    private let urlSession: URLSession
    private let baseURLProvider: BaseURLProvider
    private let deviceIdentityProvider: DeviceIdentityProvider
    private let deviceIdentityEnsurer: DeviceIdentityEnsurer

    init(
        urlSession: URLSession = .shared,
        baseURLProvider: @escaping BaseURLProvider = { AgenTTYRelayConfiguration.baseURL },
        deviceIdentityProvider: @escaping DeviceIdentityProvider = AgenTTYRelayTransport.currentDeviceIdentity,
        deviceIdentityEnsurer: @escaping DeviceIdentityEnsurer = { _, baseURL, urlSession in
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

    var baseURL: URL {
        baseURLProvider()
    }

    func claimPairingSession(code: String, publicKey: String) async throws -> AgenTTYClaimedPairingSession {
        let identity = deviceIdentityProvider()
        EsmaLog.notifications.notice(
            "event=pairing_claim_start device_id=\(identity.deviceID.uuidString, privacy: .public) code_tail=\(Self.codeTail(for: code), privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Pairing claim started",
            category: "pairing",
            level: "info",
            data: [
                "device_id": identity.deviceID.uuidString,
                "code_tail": Self.codeTail(for: code),
            ]
        )
        let requestBody = AgenTTYPairingSessionCreateRequest(
            code: code,
            deviceID: identity.deviceID,
            deviceSecret: identity.deviceSecret,
            publicKey: publicKey
        )
        do {
            return try await claimPairingSession(requestBody)
        } catch AgenTTYPairingRelayError.deviceIdentityRejected {
            EsmaLog.notifications.notice(
                "event=pairing_claim_retry reason=device_identity_rejected device_id=\(identity.deviceID.uuidString, privacy: .public)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing claim rejected: ensuring device identity before retry",
                category: "pairing",
                level: "info",
                data: ["device_id": identity.deviceID.uuidString]
            )
            try await ensureDeviceIdentity(identity: identity)
            return try await claimPairingSession(requestBody)
        }
    }

    func fetchPairingSessionStatus(sessionID: String) async throws -> AgenTTYPairingSessionStatusResponse {
        let identity = deviceIdentityProvider()
        EsmaLog.notifications.notice(
            "event=pairing_status_fetch_start device_id=\(identity.deviceID.uuidString, privacy: .public) session_id=\(sessionID, privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Pairing status fetch started",
            category: "pairing",
            level: "info",
            data: [
                "device_id": identity.deviceID.uuidString,
                "session_id": sessionID,
            ]
        )
        let request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/pairing-sessions/\(sessionID)/status",
            body: AgenTTYRelaySessionRequest(
                deviceID: identity.deviceID,
                deviceSecret: identity.deviceSecret
            )
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            EsmaLog.notifications.error(
                "event=pairing_status_fetch_failure reason=invalid_response_type session_id=\(sessionID, privacy: .public)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing status fetch failed: invalid response type",
                category: "pairing",
                level: "error",
                data: ["session_id": sessionID]
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyPreview = AgenTTYRelayTransport.responsePreview(from: data)
            EsmaLog.notifications.error(
                "event=pairing_status_fetch_failure session_id=\(sessionID, privacy: .public) status=\(httpResponse.statusCode) body=\(bodyPreview, privacy: .public)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing status fetch failed",
                category: "pairing",
                level: "error",
                data: [
                    "session_id": sessionID,
                    "status": String(httpResponse.statusCode),
                    "body_preview": bodyPreview,
                ]
            )
            throw AgenTTYPairingRelayError.unexpectedStatusCode(httpResponse.statusCode)
        }
        do {
            let status = try Self.makePairingDecoder().decode(AgenTTYPairingSessionStatusResponse.self, from: data)
            EsmaLog.notifications.notice(
                "event=pairing_status_fetch_success session_id=\(status.sessionID, privacy: .public) status=\(status.status.rawValue, privacy: .public) has_completion=\(status.completion != nil)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing status fetched",
                category: "pairing",
                level: "info",
                data: [
                    "session_id": status.sessionID,
                    "status": status.status.rawValue,
                    "has_completion": status.completion != nil ? "true" : "false",
                ]
            )
            return status
        } catch {
            let bodyPreview = AgenTTYRelayTransport.responsePreview(from: data)
            EsmaLog.notifications.error(
                "event=pairing_status_decode_failure session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) body=\(bodyPreview, privacy: .public)"
            )
            AgenTTYSentryService.capture(
                error: error,
                context: "pairing_status_decode_failure",
                data: [
                    "session_id": sessionID,
                    "body_preview": bodyPreview,
                ]
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing status decode failed",
                category: "pairing",
                level: "error",
                data: [
                    "session_id": sessionID,
                    "error": String(describing: error),
                    "body_preview": bodyPreview,
                ]
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
    }

    static func pairingCode(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           components.scheme == "agentty",
           components.host == "pair",
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }

        return trimmed
    }

    private static func codeTail(for code: String) -> String {
        String(code.suffix(4))
    }

    private func claimPairingSession(
        _ requestBody: AgenTTYPairingSessionCreateRequest
    ) async throws -> AgenTTYClaimedPairingSession {
        let request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/pairing-sessions/claim",
            body: requestBody,
            encoder: Self.makePairingEncoder()
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            EsmaLog.notifications.error("event=pairing_claim_failure reason=invalid_response_type")
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing claim failed: invalid response type",
                category: "pairing",
                level: "error"
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyPreview = AgenTTYRelayTransport.responsePreview(from: data)
            if httpResponse.statusCode == 401 {
                EsmaLog.notifications.notice(
                    "event=pairing_claim_failure status=\(httpResponse.statusCode) body=\(bodyPreview, privacy: .public)"
                )
            } else {
                EsmaLog.notifications.error(
                    "event=pairing_claim_failure status=\(httpResponse.statusCode) body=\(bodyPreview, privacy: .public)"
                )
            }
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing claim failed",
                category: "pairing",
                level: httpResponse.statusCode == 401 ? "warning" : "error",
                data: [
                    "status": String(httpResponse.statusCode),
                    "body_preview": bodyPreview,
                ]
            )
            if httpResponse.statusCode == 401 {
                throw AgenTTYPairingRelayError.deviceIdentityRejected
            }
            throw AgenTTYPairingRelayError.unexpectedStatusCode(httpResponse.statusCode)
        }
        do {
            let claim = try Self.makePairingDecoder().decode(AgenTTYClaimedPairingSession.self, from: data)
            EsmaLog.notifications.notice(
                "event=pairing_claim_success session_id=\(claim.sessionID, privacy: .public) expires_at=\(claim.expiresAtEpochSeconds)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing claim succeeded",
                category: "pairing",
                level: "info",
                data: [
                    "session_id": claim.sessionID,
                    "expires_at": String(claim.expiresAtEpochSeconds),
                ]
            )
            return claim
        } catch {
            let bodyPreview = AgenTTYRelayTransport.responsePreview(from: data)
            EsmaLog.notifications.error(
                "event=pairing_claim_decode_failure error=\(String(describing: error), privacy: .public) body=\(bodyPreview, privacy: .public)"
            )
            AgenTTYSentryService.capture(
                error: error,
                context: "pairing_claim_decode_failure",
                data: ["body_preview": bodyPreview]
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Pairing claim decode failed",
                category: "pairing",
                level: "error",
                data: [
                    "error": String(describing: error),
                    "body_preview": bodyPreview,
                ]
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
    }

    private func ensureDeviceIdentity(identity: AgenTTYNotificationDeviceIdentity) async throws {
        do {
            try await deviceIdentityEnsurer(identity, baseURL, urlSession)
        } catch let error as AgenTTYRelayTransportError {
            switch error {
            case .unauthorized:
                EsmaLog.notifications.error(
                    "event=pairing_claim_failure reason=device_identity_rejected device_id=\(identity.deviceID.uuidString, privacy: .public)"
                )
                AgenTTYSentryService.addBreadcrumb(
                    message: "Pairing claim failed: device identity rejected",
                    category: "pairing",
                    level: "error",
                    data: ["device_id": identity.deviceID.uuidString]
                )
                throw AgenTTYPairingRelayError.deviceIdentityRejected
            case .missingBundleIdentifier, .invalidResponse:
                throw AgenTTYPairingRelayError.invalidResponse
            case .unexpectedStatusCode(let statusCode):
                throw AgenTTYPairingRelayError.unexpectedStatusCode(statusCode)
            }
        }
    }

    private static func makePairingEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makePairingDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
