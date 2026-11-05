import Foundation
import StoreKit

nonisolated struct AgenTTYRelayEnsureDeviceRequest: Codable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let bundleID: String
    let pushEnvironment: AgenTTYNotifyRelayPushEnvironment
    let signedAppTransaction: String?
}

nonisolated struct AgenTTYRelaySessionRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let scope = "notify"
}

private nonisolated struct AgenTTYBackendErrorBody: Decodable {
    let detail: String?
    let code: String?
}

nonisolated struct AgenTTYBackendError: LocalizedError, Sendable, Equatable {
    static let temporarilyUnavailableMessage = "The AgenTTY service is temporarily unavailable. Try again in a moment."
    private static let maximumDetailLength = 300

    let status: Int
    let code: String?
    let detail: String?

    init(status: Int, body: Data) {
        let decoded = try? JSONDecoder().decode(AgenTTYBackendErrorBody.self, from: body)
        self.status = status
        code = decoded?.code
        detail = decoded?.detail
            .map { AgenTTYDisplayText.sanitized($0, maximumLength: Self.maximumDetailLength) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var errorDescription: String? {
        if (400..<500).contains(status), let detail {
            return detail
        }
        return Self.temporarilyUnavailableMessage
    }
}

nonisolated enum AgenTTYRelayTransport {
    static func currentDeviceIdentity() -> AgenTTYNotificationDeviceIdentity {
        AgenTTYNotificationDeviceIdentityStore.loadOrCreate()
    }

    static func ensureCurrentDeviceIdentity(
        baseURL: URL,
        urlSession: URLSession = .shared
    ) async throws {
        let requestBody = try await currentEnsureDeviceRequest()
        let request = try makeJSONRequest(
            baseURL: baseURL,
            path: "v1/devices/ensure",
            body: requestBody
        )
        _ = try await send(request, using: urlSession, expecting: 204)
    }

    static func currentEnsureDeviceRequest() async throws -> AgenTTYRelayEnsureDeviceRequest {
        let identity = currentDeviceIdentity()
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AgenTTYRelayTransportError.missingBundleIdentifier
        }

        return AgenTTYRelayEnsureDeviceRequest(
            deviceID: identity.deviceID,
            deviceSecret: identity.deviceSecret,
            bundleID: bundleIdentifier,
            pushEnvironment: AgenTTYBuildFlavor.current().notificationPushEnvironment,
            signedAppTransaction: await signedAppTransaction()
        )
    }

    static func signedAppTransaction() async -> String? {
#if AGENTTY_LOCAL_MAIN_UNLOCK
        return nil
#else
        guard AgenTTYBuildFlavor.current() == .main, let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.bundleID == Bundle.main.bundleIdentifier,
              transaction.environment == .production || transaction.environment == .sandbox else {
            return nil
        }
        return result.jwsRepresentation
#endif
    }

    static func currentSessionRequest() -> AgenTTYRelaySessionRequest {
        let identity = currentDeviceIdentity()
        return AgenTTYRelaySessionRequest(
            deviceID: identity.deviceID,
            deviceSecret: identity.deviceSecret
        )
    }

    static func makeJSONRequest(
        baseURL: URL,
        path: String,
        body: some Encodable,
        encoder: JSONEncoder = makeEncoder()
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func send(
        _ request: URLRequest,
        using urlSession: URLSession,
        expecting successStatus: Int
    ) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYRelayTransportError.invalidResponse
        }
        guard httpResponse.statusCode == successStatus else {
            let error = AgenTTYBackendError(status: httpResponse.statusCode, body: data)
            let path = request.url?.path() ?? "unknown"
            EsmaLog.notifications.notice(
                "event=backend_request_rejected path=\(path, privacy: .public) status=\(error.status) code=\(error.code ?? "none", privacy: .public) detail=\(error.detail ?? "none", privacy: .public)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Backend request rejected",
                category: "backend",
                level: error.status >= 500 ? "error" : "warning",
                data: [
                    "path": path,
                    "status": String(error.status),
                    "code": error.code ?? "none",
                    "detail": error.detail ?? "none",
                ]
            )
            throw error
        }
        return data
    }
}
