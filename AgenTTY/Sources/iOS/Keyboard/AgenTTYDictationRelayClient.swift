import Foundation

private nonisolated struct AgenTTYDictationSessionRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
    let signedAppTransaction: String
}

private nonisolated struct AgenTTYLegacyDictationSessionRequest: Encodable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
}

private nonisolated struct AgenTTYDictationRelayTranscriptionRequest: Codable, Sendable {
    let audioBase64: String
    let mimeType: String
    let fileName: String
    let instructions: String?
    let languageHints: [String]
}

nonisolated struct AgenTTYDictationRelayTranscriptionResponse: Codable, Sendable {
    let text: String
    let secondsCharged: Int
    let remainingSecondsThisWeek: Int
    let quotaResetsAtEpochSeconds: Int
}

private nonisolated struct AgenTTYDictationRelaySessionResponse: Codable, Sendable {
    let relayToken: String
    let expiresAtEpochSeconds: Int
}

private nonisolated struct AgenTTYDictationRelayErrorResponse: Codable, Sendable {
    let detail: String
    let remainingSecondsThisWeek: Int?
    let quotaResetsAtEpochSeconds: Int?
    let code: String?
}

private nonisolated struct AgenTTYDictationRelayRequestMetadata: Sendable {
    let host: String
    let requestBodyBytes: Int
    let audioBytes: Int
}

nonisolated enum AgenTTYDictationRelayError: LocalizedError, Sendable {
    case invalidResponse
    case unauthorized
    case quotaExceeded(resetAtEpochSeconds: Int?)
    case payloadTooLarge
    case backend(detail: String)
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid dictation backend response."
        case .unauthorized:
            return "Dictation is temporarily unavailable. Please try again."
        case .quotaExceeded(let resetAtEpochSeconds):
            guard let resetAtEpochSeconds else {
                return "Weekly dictation limit reached."
            }
            let resetDate = Date(timeIntervalSince1970: TimeInterval(resetAtEpochSeconds))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Weekly dictation limit reached. Try again after \(formatter.string(from: resetDate))."
        case .payloadTooLarge:
            return "Dictation recording was too large for the backend. Try again with a shorter recording."
        case .backend(let detail):
            return detail
        case .unexpectedStatusCode(let statusCode):
            return "Unexpected backend status code: \(statusCode)."
        }
    }

    var shouldCaptureToSentry: Bool {
        switch self {
        case .quotaExceeded:
            false
        case .invalidResponse, .unauthorized, .payloadTooLarge, .backend, .unexpectedStatusCode:
            true
        }
    }
}

actor AgenTTYDictationRelayClient {
    static let shared = AgenTTYDictationRelayClient()
    static let maximumAudioByteCount = 25_000_000
    private let sessionRefreshLeadTime: TimeInterval = 5 * 60

    private let urlSession: URLSession
    private var cachedRelaySession: AgenTTYNotifyRelaySession?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    private var baseURL: URL {
        AgenTTYRelayConfiguration.baseURL
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        mimeType: String,
        instructions: String?,
        languageHints: [String]
    ) async throws -> AgenTTYDictationRelayTranscriptionResponse {
        guard audioData.count <= Self.maximumAudioByteCount else {
            throw AgenTTYDictationRelayError.payloadTooLarge
        }
        let relayToken = try await issueRelaySession()
        let requestBody = AgenTTYDictationRelayTranscriptionRequest(
            audioBase64: audioData.base64EncodedString(),
            mimeType: mimeType,
            fileName: fileName,
            instructions: instructions,
            languageHints: languageHints
        )

        var request = try AgenTTYRelayTransport.makeJSONRequest(
            baseURL: baseURL,
            path: "v1/dictation/transcriptions",
            body: requestBody
        )
        request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization")
        let requestMetadata = AgenTTYDictationRelayRequestMetadata(
            host: baseURL.host ?? "unknown",
            requestBodyBytes: request.httpBody?.count ?? 0,
            audioBytes: audioData.count
        )

        EsmaLog.terminal.notice(
            "dictation relay request start host=\(requestMetadata.host, privacy: .public) audio_bytes=\(requestMetadata.audioBytes) request_body_bytes=\(requestMetadata.requestBodyBytes)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Dictation relay request started",
            category: "dictation",
            level: "info",
            data: [
                "host": requestMetadata.host,
                "audio_bytes": "\(requestMetadata.audioBytes)",
                "request_body_bytes": "\(requestMetadata.requestBodyBytes)",
            ]
        )

        do {
            return try await sendTranscriptionRequest(request, metadata: requestMetadata)
        } catch AgenTTYDictationRelayError.unauthorized {
            cachedRelaySession = nil
            let refreshedRelayToken = try await issueRelaySession()
            request.setValue("Bearer \(refreshedRelayToken)", forHTTPHeaderField: "Authorization")
            EsmaLog.terminal.notice(
                "dictation relay request retry host=\(requestMetadata.host, privacy: .public) reason=unauthorized request_body_bytes=\(requestMetadata.requestBodyBytes)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Dictation relay request retrying after unauthorized response",
                category: "dictation",
                level: "warning",
                data: [
                    "host": requestMetadata.host,
                    "request_body_bytes": "\(requestMetadata.requestBodyBytes)",
                ]
            )
            return try await sendTranscriptionRequest(request, metadata: requestMetadata)
        }
    }

    private func issueRelaySession() async throws -> String {
        if let cachedRelaySession, !cachedRelaySession.isExpiringSoon(refreshLeadTime: sessionRefreshLeadTime) {
            return cachedRelaySession.relayToken
        }

        let identity = AgenTTYRelayTransport.currentDeviceIdentity()
        let signedTransaction = await AgenTTYRelayTransport.signedAppTransaction()
        let request: URLRequest
        if let signedTransaction {
            request = try AgenTTYRelayTransport.makeJSONRequest(
                baseURL: baseURL,
                path: "v1/dictation/sessions",
                body: AgenTTYDictationSessionRequest(deviceID: identity.deviceID, deviceSecret: identity.deviceSecret, signedAppTransaction: signedTransaction)
            )
        } else {
            request = try AgenTTYRelayTransport.makeJSONRequest(
                baseURL: baseURL,
                path: "v1/relay-sessions",
                body: AgenTTYLegacyDictationSessionRequest(deviceID: identity.deviceID, deviceSecret: identity.deviceSecret)
            )
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYDictationRelayError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let session = try AgenTTYRelayTransport.makeDecoder().decode(AgenTTYNotifyRelaySession.self, from: data)
            cachedRelaySession = session
            return session.relayToken
        }

        if httpResponse.statusCode == 401 {
            try await ensureDeviceIdentity()
            let retryRequest = request
            let (retryData, retryResponse) = try await urlSession.data(for: retryRequest)
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw AgenTTYDictationRelayError.invalidResponse
            }
            guard retryHTTPResponse.statusCode == 200 else {
                throw AgenTTYDictationRelayError.unexpectedStatusCode(retryHTTPResponse.statusCode)
            }
            let session = try AgenTTYRelayTransport.makeDecoder().decode(AgenTTYNotifyRelaySession.self, from: retryData)
            cachedRelaySession = session
            return session.relayToken
        }

        throw AgenTTYDictationRelayError.unexpectedStatusCode(httpResponse.statusCode)
    }

    private func ensureDeviceIdentity() async throws {
        do {
            try await AgenTTYRelayTransport.ensureCurrentDeviceIdentity(
                baseURL: baseURL,
                urlSession: urlSession
            )
        } catch let error as AgenTTYRelayTransportError {
            switch error {
            case .missingBundleIdentifier, .invalidResponse:
                throw AgenTTYDictationRelayError.invalidResponse
            case .unauthorized:
                throw AgenTTYDictationRelayError.unauthorized
            case .unexpectedStatusCode(let statusCode):
                throw AgenTTYDictationRelayError.unexpectedStatusCode(statusCode)
            }
        }
    }

    private func sendTranscriptionRequest(
        _ request: URLRequest,
        metadata: AgenTTYDictationRelayRequestMetadata
    ) async throws -> AgenTTYDictationRelayTranscriptionResponse {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYDictationRelayError.invalidResponse
        }

        let statusCode = httpResponse.statusCode
        if statusCode != 200 {
            let responsePreview = AgenTTYRelayTransport.responsePreview(from: data, maximumLength: 240)
            EsmaLog.terminal.error(
                "dictation relay request failed host=\(metadata.host, privacy: .public) status=\(statusCode) audio_bytes=\(metadata.audioBytes) request_body_bytes=\(metadata.requestBodyBytes) response_preview=\(responsePreview, privacy: .public)"
            )
            AgenTTYSentryService.addBreadcrumb(
                message: "Dictation relay request failed",
                category: "dictation",
                level: "error",
                data: [
                    "host": metadata.host,
                    "status_code": "\(statusCode)",
                    "audio_bytes": "\(metadata.audioBytes)",
                    "request_body_bytes": "\(metadata.requestBodyBytes)",
                    "response_preview": responsePreview,
                ]
            )
        }

        switch statusCode {
        case 200:
            return try AgenTTYRelayTransport.makeDecoder()
                .decode(AgenTTYDictationRelayTranscriptionResponse.self, from: data)
        case 401:
            throw AgenTTYDictationRelayError.unauthorized
        case 413:
            throw AgenTTYDictationRelayError.payloadTooLarge
        case 429:
            let errorBody = try? AgenTTYRelayTransport.makeDecoder()
                .decode(AgenTTYDictationRelayErrorResponse.self, from: data)
            if let errorBody, errorBody.code != nil {
                throw AgenTTYDictationRelayError.backend(detail: errorBody.detail)
            }
            throw AgenTTYDictationRelayError.quotaExceeded(
                resetAtEpochSeconds: errorBody?.quotaResetsAtEpochSeconds
            )
        default:
            if let errorBody = try? AgenTTYRelayTransport.makeDecoder()
                .decode(AgenTTYDictationRelayErrorResponse.self, from: data) {
                throw AgenTTYDictationRelayError.backend(detail: errorBody.detail)
            }
            throw AgenTTYDictationRelayError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }
}

private nonisolated extension AgenTTYNotifyRelaySession {
    func isExpiringSoon(refreshLeadTime: TimeInterval) -> Bool {
        let now = Date().timeIntervalSince1970
        return Double(expiresAtEpochSeconds) - now <= refreshLeadTime
    }
}
