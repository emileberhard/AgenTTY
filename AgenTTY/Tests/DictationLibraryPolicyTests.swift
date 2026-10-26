import DictationLibrary
import Testing
@testable import AgenTTY_iOS

@Suite("Terminal dictation library policy")
@MainActor
struct DictationLibraryPolicyTests {
    @Test
    func publicRelayCannotBeBypassedBySharedPreferences() throws {
        let capabilities = try AgenTTYDictationLibrary.capabilities(backend: .relayMAITranscribe2)
        let profile = DictationProfile(
            archiveEnabled: true, preferredModel: "elevenlabs/scribe_v2_realtime/realtime",
            languages: ["sv", "en"], dictionary: ["AgenTTY", "NuGet"],
            cleanupEnabled: true, outputLanguage: "fr", thinkingLevel: "high"
        )
        let plan = DictationPlan(unverifiedProfile: profile, context: .terminal, capabilities: capabilities)
        let backend = try AgenTTYDictation.Backend.relayMAITranscribe2.resolvingLibraryModel(plan.effectiveModel)
        #expect(plan.usesFallbackModel)
        #expect(backend.libraryIdentifier == "agentty-relay/MAI-Transcribe-2/progressive")
        #expect(plan.languages == ["sv", "en"])
        #expect(plan.dictionary == ["AgenTTY", "NuGet"])
        #expect(plan.providerOptions == ["transcribeStyle": "clean"])
        #expect(!plan.cleanupEnabled)
        #expect(plan.outputLanguage == nil)
        #expect(profile.preferredModel == "elevenlabs/scribe_v2_realtime/realtime")
    }

    @Test
    func developerCatalogPreservesBatchVersusRealtimeIdentity() throws {
        let backend = AgenTTYDictation.Backend.direct(.elevenLabsScribeV2Realtime)
        let capabilities = try AgenTTYDictationLibrary.capabilities(backend: backend)
        var profile = AgenTTYDictationLibrary.localProfile(backend: backend)
        profile.preferredModel = "openai/gpt-4o-mini-transcribe-2025-12-15/batch"
        let plan = DictationPlan(unverifiedProfile: profile, context: .terminal, capabilities: capabilities)
        let selected = try backend.resolvingLibraryModel(plan.effectiveModel)
        #expect(!plan.usesFallbackModel)
        #expect(selected.libraryIdentifier == AgenTTYDictation.Model.openAIGPT4oMiniTranscribe.libraryIdentifier)
        #expect(AgenTTYDictation.Model.openAIGPT4oMiniTranscribe.libraryIdentifier != AgenTTYDictation.Model.openAIGPT4oMiniTranscribeRealtime.libraryIdentifier)
        #expect(Set(AgenTTYDictation.Model.allCases.map(\.libraryIdentifier)).count == AgenTTYDictation.Model.allCases.count)
    }

    @Test
    func unavailableProfileCanPreserveAnUnownedCaptureAfterConsent() throws {
        let backend = AgenTTYDictation.Backend.relayMAITranscribe2
        let plan = AgenTTYDictationLibrary.heldPlan(backend: backend, capabilities: try AgenTTYDictationLibrary.capabilities(backend: backend))
        #expect(plan.archiveEnabled)
        #expect(plan.effectiveModel == backend.libraryIdentifier)
        #expect(!plan.cleanupEnabled)
    }

    @Test
    func realtimeWhisperRecoveryRecordsActualBatchModel() {
        #expect(AgenTTYDictation.Model.openAIRealtimeWhisper.batchLibraryIdentifier == "openai/gpt-4o-mini-transcribe-2025-12-15/batch")
        #expect(AgenTTYDictation.Model.elevenLabsScribeV2Realtime.batchLibraryIdentifier == "elevenlabs/scribe_v2/batch")
    }
}
