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

private nonisolated struct AgenTTYPairingSessionStatusRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
}

enum AgenTTYPairingRelayError: LocalizedError {
    case deviceIdentityRejected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .deviceIdentityRejected:
            "This iPhone could not be authorized with the pairing relay. Please try automatic setup again in a few seconds."
        case .invalidResponse:
            "Invalid pairing backend response."
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
            body: AgenTTYPairingSessionStatusRequest(
                deviceID: identity.deviceID,
                deviceSecret: identity.deviceSecret
            )
        )

        let data = try await AgenTTYRelayTransport.send(request, using: urlSession, expecting: 200)
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
            EsmaLog.notifications.error(
                "event=pairing_status_decode_failure session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
    }

    static func pairingCode(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let components = URLComponents(string: trimmed), components.scheme == "agentty", components.host == "pair" {
            guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
            candidate = code
        } else {
            candidate = trimmed
        }
        let normalized = String(String.UnicodeScalarView(candidate.unicodeScalars.filter {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        })).uppercased()
        guard normalized.count == 8 else { return nil }
        return "\(normalized.prefix(4))-\(normalized.suffix(4))"
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
        let data: Data
        do {
            data = try await AgenTTYRelayTransport.send(request, using: urlSession, expecting: 200)
        } catch let error as AgenTTYBackendError where error.status == 401 {
            throw AgenTTYPairingRelayError.deviceIdentityRejected
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
            EsmaLog.notifications.error(
                "event=pairing_claim_decode_failure error=\(String(describing: error), privacy: .public)"
            )
            throw AgenTTYPairingRelayError.invalidResponse
        }
    }

    private func ensureDeviceIdentity(identity: AgenTTYNotificationDeviceIdentity) async throws {
        do {
            try await deviceIdentityEnsurer(identity, baseURL, urlSession)
        } catch let error as AgenTTYBackendError where error.status == 401 {
            EsmaLog.notifications.error(
                "event=pairing_claim_failure reason=device_identity_rejected device_id=\(identity.deviceID.uuidString, privacy: .public)"
            )
            throw AgenTTYPairingRelayError.deviceIdentityRejected
        }
    }

    private static func makePairingEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makePairingDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
