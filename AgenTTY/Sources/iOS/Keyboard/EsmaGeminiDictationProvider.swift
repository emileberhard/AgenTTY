import Foundation
import SpeechKit

nonisolated struct EsmaGeminiDictationProvider: TranscriptionProvider {
    enum ThinkingLevel: String, Sendable {
        case low = "LOW"
        case medium = "MEDIUM"
        case high = "HIGH"
    }

    let id = "gemini-dictation"
    let maximumAudioByteCount = 14_250_000

    private let router: LLMRouter
    private let model: String
    private let thinkingLevel: ThinkingLevel

    private var endpoint: URL {
        router.origin.appending(path: "vendors/google/v1beta/models/\(model):generateContent")
    }

    init(router: LLMRouter, model: String, thinkingLevel: ThinkingLevel) {
        self.router = router
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    @concurrent
    nonisolated
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let promptPayload = decodePromptPayload(from: request.instructions)
        let systemInstruction = systemInstructionText(for: request, promptPayload: promptPayload)

        let requestBody = GenerateContentRequest(
            contents: [
                .init(parts: contentParts(for: request, promptPayload: promptPayload))
            ],
            systemInstruction: systemInstruction.map { .init(parts: [.text($0)]) },
            generationConfig: .init(
                thinkingConfig: .init(thinkingLevel: thinkingLevel.rawValue)
            )
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue(router.key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SpeechKitError.httpFailure(statusCode: httpResponse.statusCode, body: responseBody)
        }

        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)

        let outputText = decoded.candidates?
            .first?
            .content?
            .parts?
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionResult(text: outputText ?? "", providerID: id)
    }

    nonisolated
    private func decodePromptPayload(from rawInstructions: String?) -> PromptPayload? {
        guard let rawInstructions, !rawInstructions.isEmpty else { return nil }
        guard let data = rawInstructions.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PromptPayload.self, from: data)
    }

    nonisolated
    private func systemInstructionText(
        for request: TranscriptionRequest,
        promptPayload: PromptPayload?
    ) -> String? {
        var sections: [String] = []

        if let systemInstruction = promptPayload?.systemInstruction {
            sections.append(systemInstruction)
        } else if let rawInstructions = request.instructions, !rawInstructions.isEmpty {
            sections.append(rawInstructions)
        }

        if !request.languageHints.isEmpty {
            let joinedHints = request.languageHints.joined(separator: ", ")
            sections.append("Expected languages: \(joinedHints).")
        }

        if !request.customVocabulary.isEmpty {
            let joinedVocabulary = request.customVocabulary.joined(separator: ", ")
            sections.append("Preserve these terms exactly when they appear: \(joinedVocabulary).")
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    nonisolated
    private func contentParts(
        for request: TranscriptionRequest,
        promptPayload: PromptPayload?
    ) -> [Part] {
        var parts: [Part] = []

        if let terminalContextMessage = promptPayload?.terminalContextMessage,
           !terminalContextMessage.isEmpty {
            parts.append(.text(terminalContextMessage))
        }

        parts.append(.inlineData(mimeType: request.audio.mimeType, data: request.audio.data.base64EncodedString()))
        return parts
    }
}

private nonisolated struct GenerateContentRequest: Encodable {
    let contents: [Content]
    let systemInstruction: Content?
    let generationConfig: GenerationConfig

    struct Content: Encodable {
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let thinkingConfig: ThinkingConfig

        struct ThinkingConfig: Encodable {
            let thinkingLevel: String
        }
    }
}

private nonisolated enum Part: Encodable {
    case text(String)
    case inlineData(mimeType: String, data: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .inlineData(let mimeType, let data):
            try container.encode(InlineData(mimeType: mimeType, data: data), forKey: .inlineData)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData
    }

    private struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }
}

private nonisolated struct PromptPayload: Decodable {
    let systemInstruction: String
    let terminalContextMessage: String?
}

private nonisolated struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content?

        struct Content: Decodable {
            let parts: [Part]?

            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }
        }
    }
}
