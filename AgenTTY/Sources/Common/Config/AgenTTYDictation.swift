import Foundation
import SpeechKit

nonisolated enum AgenTTYDictation {
    nonisolated enum Provider: String, CaseIterable, Sendable {
        case elevenLabs
        case openAI
        case gemini
        case assemblyAI
        case azureSpeech

        var displayName: String {
            switch self {
            case .elevenLabs: "ElevenLabs"
            case .openAI: "OpenAI"
            case .gemini: "Google Gemini"
            case .assemblyAI: "AssemblyAI"
            case .azureSpeech: "Azure Speech"
            }
        }

        var models: [Model] {
            Model.allCases.filter { $0.provider == self }
        }
    }

    nonisolated enum Capture: Sendable {
        case batch
        case streaming
    }

    nonisolated enum PromptFormat: Sendable {
        case geminiContextPayload
        case openAIText
        case unsupported
    }

    nonisolated enum Model: String, CaseIterable, Sendable {
        case elevenLabsScribeV2Realtime = "elevenLabs"
        case elevenLabsScribeV2
        case openAIGPT4oMiniTranscribe = "openai"
        case openAIGPT4oTranscribe
        case openAIWhisper1
        case openAIRealtimeWhisper
        case openAIGPT4oTranscribeRealtime
        case openAIGPT4oMiniTranscribeRealtime
        case gemini31Pro = "gemini"
        case gemini35Flash
        case gemini35TranscribeSmart
        case gemini35TranscribeVerbatim
        case gemini35TranscribeLiveSmart
        case gemini35TranscribeLiveVerbatim
        case assemblyAIUniversal35Pro
        case assemblyAIUniversal35ProRealtime
        case azureMAITranscribe2

        var provider: Provider {
            switch self {
            case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2:
                .elevenLabs
            case .openAIGPT4oMiniTranscribe, .openAIGPT4oTranscribe, .openAIWhisper1,
                 .openAIRealtimeWhisper, .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime:
                .openAI
            case .gemini31Pro, .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
                 .gemini35TranscribeLiveSmart, .gemini35TranscribeLiveVerbatim:
                .gemini
            case .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime:
                .assemblyAI
            case .azureMAITranscribe2:
                .azureSpeech
            }
        }

        var displayName: String {
            switch self {
            case .elevenLabsScribeV2Realtime: "Scribe v2 Realtime"
            case .elevenLabsScribeV2: "Scribe v2"
            case .openAIGPT4oMiniTranscribe: "GPT-4o Mini Transcribe"
            case .openAIGPT4oTranscribe: "GPT-4o Transcribe"
            case .openAIWhisper1: "Whisper"
            case .openAIRealtimeWhisper: "GPT Realtime Whisper"
            case .openAIGPT4oTranscribeRealtime: "GPT-4o Transcribe Realtime"
            case .openAIGPT4oMiniTranscribeRealtime: "GPT-4o Mini Transcribe Realtime"
            case .gemini31Pro: "Gemini 3.1 Pro"
            case .gemini35Flash: "Gemini 3.5 Flash"
            case .gemini35TranscribeSmart: "Gemini 3.5 Transcribe (Smart)"
            case .gemini35TranscribeVerbatim: "Gemini 3.5 Transcribe (Verbatim)"
            case .gemini35TranscribeLiveSmart: "Gemini 3.5 Transcribe Live (Smart)"
            case .gemini35TranscribeLiveVerbatim: "Gemini 3.5 Transcribe Live (Verbatim)"
            case .assemblyAIUniversal35Pro: "Universal-3.5 Pro"
            case .assemblyAIUniversal35ProRealtime: "Universal-3.5 Pro Realtime"
            case .azureMAITranscribe2: "MAI-Transcribe-2"
            }
        }

        var capture: Capture {
            switch self {
            case .elevenLabsScribeV2Realtime,
                 .openAIRealtimeWhisper, .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime,
                 .gemini35TranscribeLiveSmart, .gemini35TranscribeLiveVerbatim,
                 .assemblyAIUniversal35ProRealtime,
                 .azureMAITranscribe2:
                .streaming
            case .elevenLabsScribeV2,
                 .openAIGPT4oMiniTranscribe, .openAIGPT4oTranscribe, .openAIWhisper1,
                 .gemini31Pro, .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
                 .assemblyAIUniversal35Pro:
                .batch
            }
        }

        var promptFormat: PromptFormat {
            switch self {
            case .gemini31Pro, .gemini35Flash:
                .geminiContextPayload
            case .openAIGPT4oMiniTranscribe, .openAIGPT4oTranscribe:
                .openAIText
            case .elevenLabsScribeV2Realtime, .elevenLabsScribeV2,
                 .openAIWhisper1, .openAIRealtimeWhisper,
                 .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime,
                 .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
                 .gemini35TranscribeLiveSmart, .gemini35TranscribeLiveVerbatim,
                 .assemblyAIUniversal35Pro, .assemblyAIUniversal35ProRealtime,
                 .azureMAITranscribe2:
                .unsupported
            }
        }
    }

    static let modelStorageKey = "dictationProvider"
    static let defaultModel: Model = .elevenLabsScribeV2Realtime

    private static var modelStore: UserDefaults {
        AgenTTYSharedDefaults.store
    }

    nonisolated enum TranscriptionMode: Sendable {
        case relayOpenAI
        case selectableModels

        var modelSelectionAvailable: Bool {
            switch self {
            case .relayOpenAI:
                false
            case .selectableModels:
                true
            }
        }

        var enabledSubtitle: String {
            switch self {
            case .relayOpenAI:
                "Server-backed OpenAI transcription"
            case .selectableModels:
                "Transcription via AI provider"
            }
        }

        var disabledSubtitle: String {
            switch self {
            case .relayOpenAI:
                "Server-backed transcription disabled"
            case .selectableModels:
                "AI transcription disabled"
            }
        }
    }

    nonisolated enum Backend: Sendable {
        case relayOpenAI
        case direct(Model)

        var logIdentifier: String {
            switch self {
            case .relayOpenAI:
                "agentty-relay-openai"
            case .direct(let model):
                model.rawValue
            }
        }

        var promptFormat: PromptFormat {
            switch self {
            case .relayOpenAI:
                .openAIText
            case .direct(let model):
                model.promptFormat
            }
        }
    }

    static var currentTranscriptionMode: TranscriptionMode {
        switch AgenTTYBuildFlavor.current() {
        case .main:
            .relayOpenAI
        case .dev, .exp:
            .selectableModels
        }
    }

    static func currentBackend() throws -> Backend {
        switch currentTranscriptionMode {
        case .relayOpenAI:
            .relayOpenAI
        case .selectableModels:
            .direct(try selectedModel())
        }
    }

    static var modelSelectionAvailableInCurrentFlavor: Bool {
        currentTranscriptionMode.modelSelectionAvailable
    }

    static func enhancedDictationSubtitle(enabled: Bool) -> String {
        enabled ? currentTranscriptionMode.enabledSubtitle : currentTranscriptionMode.disabledSubtitle
    }

    enum ConfigurationError: LocalizedError, Sendable {
        case invalidModelSelection(String)
        case missingRouterKey
        case invalidRouterKey

        var errorDescription: String? {
            switch self {
            case .invalidModelSelection(let rawValue):
                "Dictation model value '\(rawValue)' is invalid. Open Settings and choose a dictation model."
            case .missingRouterKey:
                "No llm-router key is baked into this build. Install the agentty router key at ~/.config/llm-router/agentty-ios.key and reinstall."
            case .invalidRouterKey:
                "The baked llm-router key is not valid base64 text."
            }
        }
    }

    static func selectedModel() throws -> Model {
        migrateModelSelectionIfNeeded()

        let rawValue = modelStore.string(forKey: modelStorageKey) ?? defaultModel.rawValue
        guard let model = Model(rawValue: rawValue) else {
            throw ConfigurationError.invalidModelSelection(rawValue)
        }
        return model
    }

    static func migrateModelSelectionIfNeeded() {
        guard modelStore.string(forKey: modelStorageKey)?.isEmpty != false else {
            return
        }

        for legacyStore in legacyModelStores {
            guard let rawValue = legacyStore.string(forKey: modelStorageKey), !rawValue.isEmpty else {
                continue
            }
            guard Model(rawValue: rawValue) != nil else { continue }

            modelStore.set(rawValue, forKey: modelStorageKey)
            return
        }

        modelStore.set(defaultModel.rawValue, forKey: modelStorageKey)
    }

    static func router() throws -> LLMRouter {
        guard let secrets = embeddedRouterSecrets else {
            throw ConfigurationError.missingRouterKey
        }
        guard
            let keyData = Data(base64Encoded: secrets.keyBase64),
            let key = String(data: keyData, encoding: .utf8)
        else {
            throw ConfigurationError.invalidRouterKey
        }
        guard let origin = URL(string: secrets.origin) else {
            throw SpeechKitError.invalidConfiguration("The baked llm-router origin is not a URL")
        }
        return try LLMRouter(origin: origin, key: key)
    }

    static var routerConfigured: Bool {
        (try? router()) != nil
    }

    private static var embeddedRouterSecrets: AgenTTYLocalLLMRouterSecrets? {
#if AGENTTY_EMBED_AI_KEYS
        AgenTTYLocalSecrets.llmRouter
#else
        nil
#endif
    }

    private static var legacyModelStores: [UserDefaults] {
        [UserDefaults.standard] + [
            legacyBundleIdentifier(for: AgenTTYBuildFlavor.current()),
            AgenTTYSharedDefaults.legacyAppGroupIdentifier,
        ]
        .compactMap(UserDefaults.init(suiteName:))
    }

    private static func legacyBundleIdentifier(for flavor: AgenTTYBuildFlavor) -> String {
        switch flavor {
        case .main:
            "dev.tuist.EsmaTerm.iOS"
        case .dev:
            "dev.tuist.EsmaTerm.iOS.dev"
        case .exp:
            "dev.tuist.EsmaTerm.iOS.exp"
        }
    }
}
