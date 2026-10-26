import Foundation
import SpeechKit

nonisolated enum AgenTTYAzureSpeech {
    static func configuration() async throws -> AzureSpeechProviderConfiguration {
        let access: SpeechProviderAccess
        switch AgenTTYBuildFlavor.current() {
        case .main:
            access = .relay(try await AgenTTYDictationRelayClient.shared.relay())
        case .dev, .exp:
            access = .router(try AgenTTYDictation.router())
        }
        return try AzureSpeechProviderConfiguration(
            access: access,
            model: .maiTranscribe2,
            modelOptions: .init(transcribeStyle: .clean)
        )
    }
}

nonisolated enum AgenTTYBatchTranscription {
    static func engine(for model: AgenTTYDictation.Model) async throws -> TranscriptionEngine {
        switch model {
        case .elevenLabsScribeV2, .elevenLabsScribeV2Realtime:
            let configuration = ElevenLabsProviderConfiguration(access: .router(try AgenTTYDictation.router()))
            return TranscriptionEngine(provider: ElevenLabsTranscriptionProvider(configuration: configuration))
        case .openAIGPT4oMiniTranscribe, .openAIGPT4oMiniTranscribeRealtime, .openAIRealtimeWhisper:
            return try openAIEngine(model: "gpt-4o-mini-transcribe-2025-12-15")
        case .openAIGPT4oTranscribe, .openAIGPT4oTranscribeRealtime:
            return try openAIEngine(model: "gpt-4o-transcribe")
        case .openAIWhisper1:
            return try openAIEngine(model: "whisper-1")
        case .gemini31Pro:
            return try geminiContextEngine(model: "gemini-3.1-pro-preview")
        case .gemini35Flash:
            return try geminiContextEngine(model: "gemini-3.5-flash")
        case .gemini35TranscribeSmart, .gemini35TranscribeLiveSmart:
            return try geminiTranscribeEngine(mode: .smart)
        case .gemini35TranscribeVerbatim, .gemini35TranscribeLiveVerbatim:
            return try geminiTranscribeEngine(mode: .verbatim)
        case .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIProviderConfiguration(
                access: .router(AgenTTYDictation.router()),
                pollIntervalSeconds: 1
            )
            return TranscriptionEngine(provider: AssemblyAITranscriptionProvider(configuration: configuration))
        case .azureMAITranscribe2:
            return TranscriptionEngine(provider: AzureSpeechTranscriptionProvider(configuration: try await AgenTTYAzureSpeech.configuration()))
        }
    }

    private static func openAIEngine(model: String) throws -> TranscriptionEngine {
        let configuration = try OpenAIProviderConfiguration(
            access: .router(AgenTTYDictation.router()),
            model: model
        )
        return TranscriptionEngine(provider: OpenAITranscriptionProvider(configuration: configuration))
    }

    private static func geminiContextEngine(model: String) throws -> TranscriptionEngine {
        TranscriptionEngine(
            provider: EsmaGeminiDictationProvider(
                router: try AgenTTYDictation.router(),
                model: model,
                thinkingLevel: .low
            )
        )
    }

    private static func geminiTranscribeEngine(mode: GeminiTranscriptionMode) throws -> TranscriptionEngine {
        let configuration = try GeminiTranscribeProviderConfiguration(
            access: .router(AgenTTYDictation.router()),
            mode: mode
        )
        return TranscriptionEngine(provider: GeminiTranscribeProvider(configuration: configuration))
    }
}
