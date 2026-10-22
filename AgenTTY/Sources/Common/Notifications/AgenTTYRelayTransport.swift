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
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYRelayTransportError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 204:
            return
        case 401:
            throw AgenTTYRelayTransportError.unauthorized
        default:
            throw AgenTTYRelayTransportError.unexpectedStatusCode(httpResponse.statusCode)
        }
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

    static func responsePreview(from data: Data, maximumLength: Int = 300) -> String {
        guard !data.isEmpty else { return "none" }
        let raw = String(decoding: data, as: UTF8.self)
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return String(singleLine.prefix(maximumLength))
    }
}
