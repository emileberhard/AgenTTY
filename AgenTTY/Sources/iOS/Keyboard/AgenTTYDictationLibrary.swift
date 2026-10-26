import DictationLibrary
import Foundation
import Observation

@MainActor
@Observable
final class AgenTTYDictationLibrary {
    private static let containerIdentifier = AgenTTYBuildConfiguration.cloudKitContainerIdentifier

    static let shared = AgenTTYDictationLibrary()
    static let consentKey = "wisprCloneLibraryEnabled"
    private(set) var profile: DictationProfile?
    private(set) var isSavingSettings = false
    private var profileNotice: String?
    private var publicationNotice: String?
    var status: String? {
        let value = [profileNotice, publicationNotice].compactMap { $0 }.joined(separator: "\n")
        return value.isEmpty ? nil : value
    }
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    @ObservationIgnored private var publicationRequested = false
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var profileAccount: DictationAccountSession?
    @ObservationIgnored private var store: DictationLibraryStore?

    struct Capture {
        let plan: DictationPlan
        let backend: AgenTTYDictation.Backend
        let writer: DictationCaptureWriter?
        let account: DictationAccountSession?
        let archiveWarning: String?
    }

    static func localProfile(backend: AgenTTYDictation.Backend) -> DictationProfile {
        DictationProfile(
            archiveEnabled: false,
            preferredModel: backend.libraryIdentifier,
            languages: ["en", "sv"],
            dictionary: TerminalInputRouter.dictationCustomVocabulary,
            cleanupEnabled: false,
            outputLanguage: nil,
            thinkingLevel: "LOW"
        )
    }

    static func capabilities(backend: AgenTTYDictation.Backend) throws -> DictationCapabilities {
        let models: Set<String>
        switch backend {
        case .relayMAITranscribe2: models = [backend.libraryIdentifier]
        case .direct: models = Set(AgenTTYDictation.Model.allCases.map(\.libraryIdentifier))
        }
        var modelOptions = Dictionary(uniqueKeysWithValues: AgenTTYDictation.Model.allCases.map { ($0.libraryIdentifier, $0.libraryOptions) })
        modelOptions[backend.libraryIdentifier] = backend.model.libraryOptions
        return try DictationCapabilities(
            models: models, fallbackModel: backend.libraryIdentifier, supportsCleanup: false,
            modelOptions: modelOptions
        )
    }

    static func heldPlan(backend: AgenTTYDictation.Backend, capabilities: DictationCapabilities) -> DictationPlan {
        var profile = localProfile(backend: backend)
        profile.archiveEnabled = true
        return DictationPlan(unverifiedProfile: profile, context: .terminal, capabilities: capabilities)
    }

    func prepare(backend: AgenTTYDictation.Backend) async throws -> Capture {
        let capabilities = try Self.capabilities(backend: backend)
        let localPlan = DictationPlan(unverifiedProfile: Self.localProfile(backend: backend), context: .terminal, capabilities: capabilities)
        guard AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) else {
            profileNotice = nil
            publicationNotice = nil
            return Capture(plan: localPlan, backend: backend, writer: nil, account: nil, archiveWarning: nil)
        }
        let store: DictationLibraryStore
        do { store = try libraryStore() }
        catch {
            let warning = "This recording will not be archived: \(Self.errorMessage(error))"
            publicationNotice = warning
            return Capture(plan: localPlan, backend: backend, writer: nil, account: nil, archiveWarning: warning)
        }
        var plan = localPlan
        var account: DictationAccountSession?
        var shouldArchive = false
        var sharedProfileAvailable = false
        do {
            let snapshot = try await store.refresh()
            profileAccount = await store.accountSession()
            profile = snapshot?.profile
            account = await store.accountSession()
            if let snapshot {
                guard account?.accountIdentifier == snapshot.accountIdentifier else { throw DictationLibraryError.accountChanged }
                shouldArchive = snapshot.profile.archiveEnabled
                plan = try await store.makePlan(context: .terminal, capabilities: capabilities)
                if let account { try await store.validateAccountSession(account) }
                sharedProfileAvailable = true
                profileNotice = shouldArchive ? nil : "Archiving is disabled in WisprClone."
            } else {
                profileNotice = "Enable your dictation library in WisprClone first."
            }
        } catch DictationLibraryError.archiveDisabled {
            plan = localPlan
            account = await store.accountSession()
            shouldArchive = false
            profileNotice = "Archiving is disabled in WisprClone."
        } catch DictationLibraryError.notConfigured {
            plan = localPlan
            account = await store.accountSession()
            shouldArchive = false
            profileNotice = "Enable your dictation library in WisprClone first."
        } catch {
            plan = Self.heldPlan(backend: backend, capabilities: capabilities)
            account = await store.accountSession()
            shouldArchive = true
            profileNotice = "The shared profile is unavailable. New recordings will remain held on this device until you confirm their ownership."
        }
        var resolvedBackend = try backend.resolvingLibraryModel(plan.effectiveModel)
        if plan.usesFallbackModel {
            profileNotice = "WisprClone’s preferred model is unavailable here. Using \(resolvedBackend.libraryDisplayName)."
        } else if sharedProfileAvailable {
            profileNotice = "Using \(resolvedBackend.libraryDisplayName) from WisprClone." + (shouldArchive ? "" : " Archiving is disabled in WisprClone.")
        }
        var writer: DictationCaptureWriter?
        var archiveWarning: String?
        if shouldArchive {
            do { writer = try await store.beginCapture(plan: plan) }
            catch DictationLibraryError.accountChanged {
                plan = Self.heldPlan(backend: backend, capabilities: capabilities)
                account = await store.accountSession()
                resolvedBackend = backend
                do { writer = try await store.beginCapture(plan: plan) }
                catch { archiveWarning = "This recording will not be archived: \(Self.errorMessage(error))" }
                profileNotice = "The iCloud account changed. This recording will remain held on this device."
            } catch {
                archiveWarning = "This recording will not be archived: \(Self.errorMessage(error))"
            }
        }
        if let archiveWarning { publicationNotice = archiveWarning }
        return Capture(plan: plan, backend: resolvedBackend, writer: writer, account: account, archiveWarning: archiveWarning)
    }

    func accountEvents() async -> AsyncStream<DictationAccountSession?>? {
        guard let store else { return nil }
        return await store.accountEvents()
    }

    @discardableResult
    func finishOriginal(_ capture: Capture) async -> String? {
        guard let writer = capture.writer else { return nil }
        do {
            _ = try await writer.finish()
            requestPublication()
            return nil
        } catch {
            let warning = "The original recording needs recovery: \(Self.errorMessage(error))"
            publicationNotice = warning
            return warning
        }
    }

    @discardableResult
    func record(_ capture: Capture, text: String, kind: DictationResultKind, model: String, contextWasUsed: Bool) async -> String? {
        guard let writer = capture.writer else { return nil }
        do {
            let store = try libraryStore()
            try await store.addResult(DictationResultVersion(
                id: UUID(), captureID: writer.id, createdAt: Date(), kind: kind,
                text: text, model: model, contextWasUsed: contextWasUsed, parentResultID: nil,
                plan: try Self.resultPlan(capture.plan, model: model)
            ))
            requestPublication()
            return nil
        } catch {
            let warning = "The original is retained; this result could not be saved: \(Self.errorMessage(error))"
            publicationNotice = warning
            return warning
        }
    }

    func resumePublication() async {
        requestPublication()
        await publicationTask?.value
    }

    private func requestPublication() {
        guard AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) else { return }
        publicationRequested = true
        guard publicationTask == nil else { return }
        publicationTask = Task {
            while publicationRequested, AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) {
                publicationRequested = false
                await performPublication()
            }
            publicationTask = nil
        }
    }

    private func performPublication() async {
        guard AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) else { return }
        do {
            let store = try libraryStore()
            let snapshot = try await store.refresh()
            profileAccount = await store.accountSession()
            profile = snapshot?.profile
            try await store.publishPending()
            let publication = try await store.status()
            publicationNotice = publication.heldCaptureCount > 0 ? "\(publication.heldCaptureCount) recording(s) are held on this device until their ownership is resolved." : nil
        } catch {
            publicationNotice = "Library sync needs attention: \(error.localizedDescription)"
        }
    }

    func setPreferredModel(_ model: AgenTTYDictation.Model) {
        guard !isSavingSettings, let account = profileAccount,
              AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) else { return }
        isSavingSettings = true
        settingsTask = Task {
            defer { isSavingSettings = false; settingsTask = nil }
            do {
                let store = try libraryStore()
                try await store.validateAccountSession(account)
                guard let snapshot = try await store.refresh(), snapshot.accountIdentifier == account.accountIdentifier else {
                    throw DictationLibraryError.profileUnavailable
                }
                try await store.validateAccountSession(account)
                var value = snapshot.profile
                value.preferredModel = model.libraryIdentifier
                try await store.saveProfile(value, session: account)
                try await store.validateAccountSession(account)
                profileAccount = account
                profile = value
            } catch { profileNotice = "Shared settings could not be saved: \(Self.errorMessage(error))" }
        }
    }

    struct RecoverySnapshot {
        let captures: [DictationHeldCapture]
        let otherAccountCount: Int
        let account: DictationAccountSession?
        let canAdopt: Bool
        let publication: DictationPublicationStatus
        let notice: String?
    }

    func recoverySnapshot() async throws -> RecoverySnapshot {
        let store = try libraryStore()
        var notice: String?
        do { _ = try await store.refresh() }
        catch { notice = Self.errorMessage(error) }
        let account = await store.accountSession()
        _ = try await store.recoverInterruptedCaptures()
        let held = try await store.heldCaptures()
        let publication = try await store.status()
        let profile = await store.profileState()
        var archiveEnabled = false
        if case .ready(let snapshot) = profile { archiveEnabled = snapshot.profile.archiveEnabled }
        if let account { try await store.validateAccountSession(account) }
        return RecoverySnapshot(
            captures: held.filter { $0.reason == .unverifiedPlan },
            otherAccountCount: held.filter { $0.reason == .otherAccount }.count,
            account: account,
            canAdopt: account != nil && archiveEnabled && AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey),
            publication: publication, notice: notice
        )
    }

    func adoptHeldCapture(id: UUID, account: DictationAccountSession) async throws {
        guard AgenTTYSharedDefaults.store.bool(forKey: Self.consentKey) else { throw DictationLibraryError.archiveDisabled }
        let store = try libraryStore()
        try await store.validateAccountSession(account)
        guard case .ready(let snapshot) = await store.profileState(), snapshot.profile.archiveEnabled else {
            throw DictationLibraryError.archiveDisabled
        }
        try await store.reconcileHeldCapture(id: id, session: account)
        await resumePublication()
    }

    func freeUploadedLocalAudio(account: DictationAccountSession, cutoff: Date) async throws -> DictationReleaseReport {
        let store = try libraryStore()
        return try await store.releasePublishedOriginals(finishedBefore: cutoff, session: account)
    }

    private static func resultPlan(_ capturePlan: DictationPlan, model: String) throws -> DictationPlan {
        guard model != capturePlan.effectiveModel else { return capturePlan }
        let profile = DictationProfile(
            archiveEnabled: true, preferredModel: capturePlan.preferredModel, languages: capturePlan.languages,
            dictionary: capturePlan.dictionary, cleanupEnabled: false, outputLanguage: nil,
            thinkingLevel: capturePlan.thinkingLevel
        )
        let options: [String: String]
        if model == AgenTTYDictation.Backend.relayMAITranscribe2.batchLibraryIdentifier {
            options = AgenTTYDictation.Model.azureMAITranscribe2.libraryOptions
        } else {
            options = AgenTTYDictation.Model.allCases.first {
                $0.libraryIdentifier == model || $0.batchLibraryIdentifier == model
            }?.libraryOptions ?? [:]
        }
        return DictationPlan(unverifiedProfile: profile, context: .terminal, capabilities: try DictationCapabilities(
            models: [model], fallbackModel: model, supportsCleanup: false, modelOptions: [model: options]
        ))
    }

    deinit { accountTask?.cancel(); settingsTask?.cancel(); publicationTask?.cancel() }

    private static func errorMessage(_ error: any Error) -> String {
        if case DictationLibraryError.capacityExceeded = error {
            return "The 512 MiB library storage limit is full. Pending originals have been retained."
        }
        if case DictationLibraryError.accountChanged = error { return "The iCloud account changed." }
        if case DictationLibraryError.accountUnavailable = error { return "The iCloud account could not be confirmed." }
        if case DictationLibraryError.noAudio = error { return "No microphone audio was saved." }
        return error.localizedDescription
    }

    private func libraryStore() throws -> DictationLibraryStore {
        if let store { return store }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DictationLibrary", directoryHint: .isDirectory)
        guard let source = Bundle.main.bundleIdentifier else { throw DictationLibraryError.invalidConfiguration }
        let store = try DictationLibraryStore(
            directory: directory, source: source,
            capacityBytes: 512 * 1_024 * 1_024,
            containerIdentifier: Self.containerIdentifier
        )
        self.store = store
        accountTask = Task { [weak self] in
            for await session in await store.accountEvents() {
                guard let self else { return }
                if session != profileAccount { profile = nil; profileAccount = nil }
            }
        }
        return store
    }
}

extension AgenTTYDictation.Backend {
    nonisolated var libraryIdentifier: String {
        switch self {
        case .relayMAITranscribe2: "agentty-relay/MAI-Transcribe-2/progressive"
        case .direct(let model): model.libraryIdentifier
        }
    }

    nonisolated var batchLibraryIdentifier: String {
        switch self {
        case .relayMAITranscribe2: "agentty-relay/MAI-Transcribe-2/batch"
        case .direct(let model): model.batchLibraryIdentifier
        }
    }

    nonisolated var libraryDisplayName: String {
        switch self {
        case .relayMAITranscribe2: "MAI-Transcribe-2"
        case .direct(let model): model.displayName
        }
    }

    nonisolated func resolvingLibraryModel(_ identifier: String) throws -> Self {
        switch self {
        case .relayMAITranscribe2: return .relayMAITranscribe2
        case .direct:
            guard let model = AgenTTYDictation.Model.allCases.first(where: { $0.libraryIdentifier == identifier }) else {
                throw AgenTTYDictation.ConfigurationError.invalidModelSelection(identifier)
            }
            return .direct(model)
        }
    }
}

extension AgenTTYDictation.Model {
    nonisolated var libraryIdentifier: String {
        switch self {
        case .elevenLabsScribeV2Realtime: "elevenlabs/scribe_v2_realtime/realtime"
        case .elevenLabsScribeV2: "elevenlabs/scribe_v2/batch"
        case .openAIGPT4oMiniTranscribe: "openai/gpt-4o-mini-transcribe-2025-12-15/batch"
        case .openAIGPT4oTranscribe: "openai/gpt-4o-transcribe/batch"
        case .openAIWhisper1: "openai/whisper-1/batch"
        case .openAIRealtimeWhisper: "openai/gpt-realtime-whisper/realtime"
        case .openAIGPT4oTranscribeRealtime: "openai/gpt-4o-transcribe/realtime"
        case .openAIGPT4oMiniTranscribeRealtime: "openai/gpt-4o-mini-transcribe/realtime"
        case .gemini31Pro: "google/gemini-3.1-pro-preview/batch"
        case .gemini35Flash: "google/gemini-3.5-flash/batch"
        case .gemini35TranscribeSmart: "google/gemini-3.5-transcribe/batch"
        case .gemini35TranscribeVerbatim: "google/gemini-3.5-transcribe/batch?mode=verbatim"
        case .gemini35TranscribeLiveSmart: "google/gemini-3.5-transcribe-live/realtime"
        case .gemini35TranscribeLiveVerbatim: "google/gemini-3.5-transcribe-live/realtime?mode=verbatim"
        case .assemblyAIUniversal35Pro: "assemblyai/universal-3-5-pro+universal-2/batch"
        case .assemblyAIUniversal35ProRealtime: "assemblyai/universal-3-5-pro/realtime"
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/progressive"
        }
    }

    nonisolated var libraryOptions: [String: String] {
        switch self {
        case .gemini31Pro, .gemini35Flash: ["thinking_level": "LOW", "output_mode": "terminal-context-conditioned"]
        case .gemini35TranscribeSmart, .gemini35TranscribeLiveSmart: ["mode": "smart"]
        case .gemini35TranscribeVerbatim, .gemini35TranscribeLiveVerbatim: ["mode": "verbatim"]
        case .azureMAITranscribe2: ["transcribeStyle": "clean"]
        case .openAIRealtimeWhisper: ["transcription_delay": "high", "turn_detection": "disabled", "noise_reduction": "near_field"]
        case .openAIGPT4oTranscribeRealtime, .openAIGPT4oMiniTranscribeRealtime: ["turn_detection": "semantic_vad_low", "noise_reduction": "near_field"]
        default: [:]
        }
    }

    nonisolated var batchLibraryIdentifier: String {
        switch self {
        case .elevenLabsScribeV2Realtime: AgenTTYDictation.Model.elevenLabsScribeV2.libraryIdentifier
        case .openAIRealtimeWhisper, .openAIGPT4oMiniTranscribeRealtime: AgenTTYDictation.Model.openAIGPT4oMiniTranscribe.libraryIdentifier
        case .openAIGPT4oTranscribeRealtime: AgenTTYDictation.Model.openAIGPT4oTranscribe.libraryIdentifier
        case .gemini35TranscribeLiveSmart: AgenTTYDictation.Model.gemini35TranscribeSmart.libraryIdentifier
        case .gemini35TranscribeLiveVerbatim: AgenTTYDictation.Model.gemini35TranscribeVerbatim.libraryIdentifier
        case .assemblyAIUniversal35ProRealtime: AgenTTYDictation.Model.assemblyAIUniversal35Pro.libraryIdentifier
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/batch"
        default: libraryIdentifier
        }
    }
}
