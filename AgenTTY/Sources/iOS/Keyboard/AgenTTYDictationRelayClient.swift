import Foundation
import SpeechKit
import StoreKit

private nonisolated struct AgenTTYDictationSessionRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let signedAppTransaction: String
    let signedLifetimeTransaction: String?
}

private nonisolated struct AgenTTYLegacyDictationSessionRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
}

private nonisolated struct AgenTTYDictationRelaySession: Decodable, Sendable {
    enum Tier: String, Decodable, Sendable {
        case free
        case lifetime
    }

    let relayToken: String
    let expiresAtEpochSeconds: Int
    let dictationTier: Tier?
}

actor AgenTTYDictationRelayClient {
    static let shared = AgenTTYDictationRelayClient()
    private let urlSession: URLSession
    private var cachedSession: AgenTTYDictationRelaySession?
    private var pendingSession: Task<AgenTTYDictationRelaySession, any Error>?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func relay() async throws -> SpeechRelay {
        let session: AgenTTYDictationRelaySession
        if let cachedSession, Double(cachedSession.expiresAtEpochSeconds) - Date().timeIntervalSince1970 > 5 * 60 {
            session = cachedSession
        } else if let pendingSession {
            session = try await pendingSession.value
        } else {
            let task = Task { try await self.issueSession() }
            pendingSession = task
            defer { pendingSession = nil }
            session = try await task.value
            cachedSession = session
        }
        return try SpeechRelay(
            baseURL: AgenTTYRelayConfiguration.baseURL.appending(path: "v1/dictation/azure-speech"),
            bearerToken: session.relayToken
        )
    }

    func invalidateSession() {
        cachedSession = nil
    }

    func reportTierMismatch(hasLifetimeAccess: Bool) {
        guard hasLifetimeAccess, cachedSession?.dictationTier == .free else { return }
        EsmaLog.terminal.warning("dictation relay granted free tier while lifetime access is unlocked")
        AgenTTYSentryService.addBreadcrumb(
            message: "Dictation tier differs from local lifetime access",
            category: "dictation",
            level: "warning",
            data: ["dictation_tier": "free", "local_lifetime_access": "true"]
        )
    }

    private func issueSession() async throws -> AgenTTYDictationRelaySession {
        let identity = AgenTTYRelayTransport.currentDeviceIdentity()
        let signedAppTransaction = await AgenTTYRelayTransport.signedAppTransaction()
        let request: URLRequest
        if let signedAppTransaction {
            var signedLifetimeTransaction: String?
            for await result in Transaction.currentEntitlements(for: AgenTTYLifetimeAccessProduct.productID) {
                if case .verified = result {
                    signedLifetimeTransaction = result.jwsRepresentation
                    break
                }
            }
            request = try AgenTTYRelayTransport.makeJSONRequest(
                baseURL: AgenTTYRelayConfiguration.baseURL,
                path: "v1/dictation/sessions",
                body: AgenTTYDictationSessionRequest(
                    deviceID: identity.deviceID,
                    deviceSecret: identity.deviceSecret,
                    signedAppTransaction: signedAppTransaction,
                    signedLifetimeTransaction: signedLifetimeTransaction
                )
            )
        } else {
            request = try AgenTTYRelayTransport.makeJSONRequest(
                baseURL: AgenTTYRelayConfiguration.baseURL,
                path: "v1/relay-sessions",
                body: AgenTTYLegacyDictationSessionRequest(deviceID: identity.deviceID, deviceSecret: identity.deviceSecret)
            )
        }
        var (data, response) = try await urlSession.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try await AgenTTYRelayTransport.ensureCurrentDeviceIdentity(
                baseURL: AgenTTYRelayConfiguration.baseURL,
                urlSession: urlSession
            )
            (data, response) = try await urlSession.data(for: request)
        }
        guard let response = response as? HTTPURLResponse else { throw SpeechKitError.invalidResponse }
        switch response.statusCode {
        case 200:
            let session = try AgenTTYRelayTransport.makeDecoder().decode(AgenTTYDictationRelaySession.self, from: data)
            guard signedAppTransaction == nil || session.dictationTier != nil else { throw SpeechKitError.invalidResponse }
            return session
        case 401:
            throw SpeechKitError.relayRejected(kind: "unauthorized")
        case 403:
            throw SpeechKitError.relayRejected(kind: "verification_required")
        default:
            throw SpeechKitError.httpFailure(
                statusCode: response.statusCode,
                body: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }
    }
}
