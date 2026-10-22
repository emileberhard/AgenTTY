import AVFoundation
import Foundation
import Observation
import SwiftUI
import SpeechKit
import DictationLibrary
import UIKit

@MainActor
protocol TerminalInputSink: AnyObject {
    func sendTerminalBytes(_ bytes: [UInt8])
    func insertDictationText(_ text: String, fallbackBytes: [UInt8])
    func insertClipboardText(_ text: String, fallbackBytes: [UInt8])
    func insertClipboardImages(_ imagePayloads: [TerminalClipboardImagePayload], fallbackBytes: [UInt8])
    func insertClipboardFiles(_ fileProviders: [any TerminalClipboardItemProvider], fallbackBytes: [UInt8])
    func captureDictationShellContext(maxLines: Int) async -> String?
    func setDirectionalPadCursorStyle(active: Bool)
    func dismissConnectionRecovery()
    func retryActiveConnection()
}

extension TerminalInputSink {
    func applyClipboardPastePayload(_ payload: TerminalClipboardPastePayload?, fallbackBytes: [UInt8]) {
        switch payload {
        case .images(let imagePayloads) where !imagePayloads.isEmpty:
            insertClipboardImages(imagePayloads, fallbackBytes: fallbackBytes)

        case .files(let fileProviders) where !fileProviders.isEmpty:
            insertClipboardFiles(fileProviders, fallbackBytes: fallbackBytes)

        case .text(let text) where !text.isEmpty:
            insertClipboardText(text, fallbackBytes: fallbackBytes)

        default:
            sendTerminalBytes(fallbackBytes)
        }
    }
}

@MainActor
@Observable
final class TerminalInputRouter {
    private(set) var isDictationRecording = false
    private(set) var isDictationProcessing = false
    private(set) var isDictationArming = false
    var dictationError: String?
    var keyboardEncodingMode: KeyboardEncodingMode = .defaultShortcuts
    var hostConnectionPhase: AgenTTYHostConnectionPhase = .disconnected
    var hostConnectionMethod: AgenTTYHostConnectionMethod?
    private(set) var connectionRecoveryRequest: AgenTTYConnectionRecoveryRequest?

    var isDictationCaptureActive: Bool {
        isDictationArming || isDictationRecording
    }

    var isDictationButtonActive: Bool {
        isDictationCaptureActive || isDictationProcessing
    }

    @ObservationIgnored
    private weak var sink: (any TerminalInputSink)?
    @ObservationIgnored
    private var realtimeAudioCapture: AgenTTYRealtimeAudioCapture?
    @ObservationIgnored
    private var realtimeDictation: RealtimeDictation?
    @ObservationIgnored
    private var realtimeRecordingWriter: DictationRecordingWriter<String>?
    @ObservationIgnored
    private var realtimeRecordingStore: DictationRecordingStore<String>?
    @ObservationIgnored
    private var activeDictationCapture: AgenTTYDictationLibrary.Capture?
    @ObservationIgnored
    private var libraryAccountMonitor: Task<Void, Never>?
    @ObservationIgnored
    private var dictationProcessingTask: Task<Void, Never>?
    @ObservationIgnored
    private var dictationGeneration = UUID()
    @ObservationIgnored
    private var dictationInterruptionObserver: NSObjectProtocol?
    @ObservationIgnored
    private var dictationRouteChangeObserver: NSObjectProtocol?
    @ObservationIgnored
    private var shouldMaintainDictationRecording = false
    @ObservationIgnored
    private var pausedForDictationRouteLoss = false
    @ObservationIgnored
    private let audioSessionBoundary: any DictationAudioSessionBoundary
    @ObservationIgnored
    private var isDirectionalPadCursorStyleActive = false
    @ObservationIgnored
    private let clipboardPayloadProvider: @MainActor () async -> TerminalClipboardPastePayload?

    init(
        audioSessionBoundary: any DictationAudioSessionBoundary = SystemDictationAudioSessionBoundary(),
        clipboardPayloadProvider: @escaping @MainActor () async -> TerminalClipboardPastePayload? = TerminalClipboard.generalPastePayload
    ) {
        self.audioSessionBoundary = audioSessionBoundary
        self.clipboardPayloadProvider = clipboardPayloadProvider
    }

    func attach(sink: any TerminalInputSink) {
        self.sink = sink
        sink.setDirectionalPadCursorStyle(active: isDirectionalPadCursorStyleActive)
    }

    func setDirectionalPadInteractionActive(_ active: Bool) {
        guard active != isDirectionalPadCursorStyleActive else { return }
        isDirectionalPadCursorStyleActive = active
        sink?.setDirectionalPadCursorStyle(active: active)
    }

    func handleKeyAction(_ action: KeyAction, keyboardState: KeyboardState) {
        if keyboardState.shouldHandleModifierAction(action) {
            guard let modifier = action.modifierKey else {
                preconditionFailure("modifier action expected a concrete modifier key")
            }
            keyboardState.handleModifierTap(modifier)
            return
        }

        keyboardState.markHeldModifierUsage()
        let activeModifiers = keyboardState.activeChordModifiers

        switch action {
        case .character(let char):
            let payload = characterBytes(for: char, keyboardState: keyboardState, modifiers: activeModifiers)
            if shouldHandleClipboardPaste(for: char, modifiers: activeModifiers) {
                let fallbackBytes = payload
                resolveAndHandleClipboardPaste(fallbackBytes: fallbackBytes)
                keyboardState.consumeOneShotModifiers(activeModifiers)
                return
            }
            sendBytes(payload)
            keyboardState.consumeOneShotModifiers(activeModifiers)

        case .backspace, .enter, .space, .tab, .escape, .arrowUp, .arrowDown, .arrowRight, .arrowLeft:
            if let payload = nonCharacterBytes(for: action, modifiers: activeModifiers) {
                sendBytes(payload)
            }
            keyboardState.consumeOneShotModifiers(activeModifiers)

        case .shift, .ctrl, .alt:
            // Handled by modifier state logic before the switch; kept for exhaustiveness.
            break

        case .directionPad:
            // Directional pad emits concrete arrow actions and should not route directly.
            break

        case .symbolLayer:
            keyboardState.toggleSymbols()
            keyboardState.consumeOneShotModifiers(activeModifiers)

        case .dictation:
            keyboardState.consumeOneShotModifiers(activeModifiers)
            handleDictationTap()
        }
    }

    /// Routes a single hardware-keyboard event (iPad Magic Keyboard etc.) into the
    /// existing terminal byte encoder. Bypasses `KeyboardState` entirely: the
    /// slide-chord, one-shot and shift-state machinery is virtual-keyboard-specific,
    /// and hardware keystrokes already arrive with explicit modifier flags.
    ///
    /// Cmd+V is handled separately via `UIKeyCommand` → `paste(_:)` on
    /// `TerminalSurfaceViewIOS`, which calls into the same async clipboard
    /// resolver as touch-paste. Cmd+Backspace is normalized by
    /// `HardwareKeyMapping` into the same modifier/action pair as Ctrl+Backspace.
    func handleHardwareKey(action: KeyAction, modifiers: Set<ModifierKey>) {
        switch action {
        case .character(let char):
            let payload = TerminalParityKeyEncoder.encodeCharacter(
                char,
                isUppercase: false,
                modifiers: modifiers
            )
            sendBytes(payload)

        case .backspace, .enter, .space, .tab, .escape,
             .arrowUp, .arrowDown, .arrowRight, .arrowLeft:
            if let payload = nonCharacterBytes(for: action, modifiers: modifiers) {
                sendBytes(payload)
            }

        case .dictation:
            // Caps Lock on iPad Magic Keyboard is bound to dictation toggle —
            // routes through the same record/transcribe path as the on-screen key.
            handleDictationTap()

        case .shift, .ctrl, .alt, .symbolLayer, .directionPad:
            // Modifier-only and virtual-keyboard-only actions never originate
            // from hardware key events on this path.
            break
        }
    }

    // MARK: - Private

    private func characterBytes(for char: String, keyboardState: KeyboardState, modifiers: Set<ModifierKey>) -> [UInt8] {
        TerminalParityKeyEncoder.encodeCharacter(char, isUppercase: keyboardState.isUppercase, modifiers: modifiers)
    }

    private func nonCharacterBytes(for action: KeyAction, modifiers: Set<ModifierKey>) -> [UInt8]? {
        if keyboardEncodingMode == .defaultShortcuts,
           let shortcutBytes = customShortcutBytes(for: action, modifiers: modifiers) {
            return shortcutBytes
        }
        return TerminalParityKeyEncoder.encodeNonCharacter(action: action, modifiers: modifiers)
    }

    private func customShortcutBytes(for action: KeyAction, modifiers: Set<ModifierKey>) -> [UInt8]? {
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.alt)
        let hasCtrl = modifiers.contains(.ctrl)

        // Option+Left/Right mirrors Mac terminal word navigation.
        if hasAlt, !hasCtrl, !hasShift {
            switch action {
            case .arrowLeft:
                return [0x1B, 0x62] // ESC b
            case .arrowRight:
                return [0x1B, 0x66] // ESC f
            default:
                break
            }
        }

        // Ctrl/Command+Left/Right jumps to line start/end in readline-style shells.
        if hasCtrl, !hasAlt, !hasShift {
            switch action {
            case .backspace:
                return [0x15] // Ctrl+U delete-to-start-of-line
            case .arrowLeft:
                return [0x01] // Ctrl+A
            case .arrowRight:
                return [0x05] // Ctrl+E
            default:
                break
            }
        }

        return nil
    }

    private func utf8Bytes(for text: String) -> [UInt8] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        return Array(normalized.utf8)
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        sink?.sendTerminalBytes(bytes)
    }

    func retryConnectionRecovery() {
        sink?.retryActiveConnection()
    }

    func dismissConnectionRecovery() {
        sink?.dismissConnectionRecovery()
    }

    func updateConnectionRecoveryRequest(_ request: AgenTTYConnectionRecoveryRequest?) {
        connectionRecoveryRequest = request
    }

    private func shouldHandleClipboardPaste(for char: String, modifiers: Set<ModifierKey>) -> Bool {
        guard keyboardEncodingMode == .defaultShortcuts else { return false }
        guard modifiers.contains(.ctrl), !modifiers.contains(.alt) else { return false }
        return char.caseInsensitiveCompare("v") == .orderedSame
    }

    private func resolveAndHandleClipboardPaste(fallbackBytes: [UInt8]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = await clipboardPayloadProvider()
            handleClipboardPastePayload(payload, fallbackBytes: fallbackBytes)
        }
    }

    private func handleClipboardPastePayload(
        _ payload: TerminalClipboardPastePayload?,
        fallbackBytes: [UInt8]
    ) {
        guard let sink else {
            sendBytes(fallbackBytes)
            return
        }
        sink.applyClipboardPastePayload(payload, fallbackBytes: fallbackBytes)
    }

    private func handleDictationTap() {
        guard Self.isDictationAIEnabled else {
            let message = Self.dictationDisabledMessage
            EsmaLog.terminal.notice("dictation blocked: \(message, privacy: .public)")
            dictationError = message
            return
        }

        if isDictationProcessing || isDictationArming {
            return
        }

        if isDictationRecording {
            beginStoppingDictation(.completed)
        } else {
            beginArmingDictation()
        }
    }

    private func beginArmingDictation() {
        isDictationArming = true
        Task(priority: .userInitiated) { @MainActor [weak self] in
            await self?.startDictation()
        }
    }

    private enum DictationCaptureEnd {
        case completed
        case failed(any Error)
    }

    private func beginStoppingDictation(_ ending: DictationCaptureEnd) {
        guard let audioCapture = realtimeAudioCapture,
              let writer = realtimeRecordingWriter,
              let capture = activeDictationCapture,
              let store = realtimeRecordingStore else { return }
        let dictation = realtimeDictation
        let generation = dictationGeneration
        shouldMaintainDictationRecording = false
        pausedForDictationRouteLoss = false
        isDictationArming = false
        isDictationRecording = false
        isDictationProcessing = true
        realtimeAudioCapture = nil
        realtimeDictation = nil
        realtimeRecordingWriter = nil
        activeDictationCapture = nil
        audioCapture.stop()
        deactivateAudioSession()

        dictationProcessingTask = Task(priority: .userInitiated) { @MainActor [self] in
            async let archiveWarning = AgenTTYDictationLibrary.shared.finishOriginal(capture)
            var recording: DictationRecording<String>?
            defer {
                isDictationProcessing = false
                dictationProcessingTask = nil
                libraryAccountMonitor?.cancel()
                libraryAccountMonitor = nil
            }
            do {
                do { recording = try await writer.finish() }
                catch {
                    if let incomplete = error as? IncompleteDictationRecording<String> { recording = incomplete.recording }
                    else if dictation == nil { throw error }
                }
                if case .failed(let error) = ending { throw error }
                try Task.checkCancellation()
                let output: AgenTTYDictationOutput
                if let dictation, case .direct(let model) = capture.backend {
                    output = try await AgenTTYRealtimeDictation.transcribe(
                        dictation: dictation, recording: recording, model: model,
                        languageHints: capture.plan.languages, customVocabulary: capture.plan.dictionary
                    )
                } else {
                    guard let recording else { throw SpeechKitError.invalidRequest("Dictation recording is unavailable") }
                    let context = capture.backend.promptFormat == .unsupported ? nil : await captureDictationShellContext()
                    let instructions = Self.dictationInstructions(for: capture.backend, shellContext: context)
                    let audio = try await recording.transcriptionAudio(maximumByteCount: Self.maximumAudioByteCount(backend: capture.backend))
                    let text = try await Self.transcribeDictationAudio(
                        preparedAudio: PreparedDictationAudio(audioData: audio.data, transcriptionAudio: audio),
                        instructions: instructions, backend: capture.backend,
                        languageHints: capture.plan.languages, customVocabulary: capture.plan.dictionary
                    )
                    output = AgenTTYDictationOutput(
                        text: text, model: capture.backend.libraryIdentifier,
                        kind: instructions == nil ? .providerOutput : .contextualOutput,
                        contextWasUsed: context != nil
                    )
                }
                let resultWarning = await AgenTTYDictationLibrary.shared.record(
                    capture, text: output.text, kind: output.kind, model: output.model,
                    contextWasUsed: output.contextWasUsed
                )
                guard generation == dictationGeneration else { throw DictationLibraryError.accountChanged }
                let warning = [capture.archiveWarning, resultWarning].compactMap { $0 }.joined(separator: "\n")
                if !warning.isEmpty { dictationError = warning }
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let fallbackBytes = utf8Bytes(for: text)
                    if let sink { sink.insertDictationText(text, fallbackBytes: fallbackBytes) }
                    else { sendBytes(fallbackBytes) }
                }
            } catch {
                await dictation?.cancel()
                await AgenTTYDictationLibrary.shared.record(
                    capture, text: error is CancellationError ? "cancelled" : String(reflecting: type(of: error)),
                    kind: .failure, model: capture.backend.libraryIdentifier, contextWasUsed: false
                )
                if let incomplete = error as? IncompleteDictationRecording<String> { recording = incomplete.recording }
                if Self.shouldReportDictationErrorToSentry(error) {
                    AgenTTYSentryService.capture(error: error, context: "dictation_transcription_failure", data: ["backend_identifier": capture.backend.logIdentifier])
                }
                dictationError = Self.dictationErrorMessage(for: error)
            }
            if let archiveWarning = await archiveWarning { dictationError = archiveWarning }
            if let recording { try? await store.discard(recording) }
        }
    }

    private func startDictation() async {
        guard await ensureMicrophonePermission() else {
            isDictationArming = false
            return
        }
        var capture: AgenTTYDictationLibrary.Capture?
        var writer: DictationRecordingWriter<String>?
        var dictation: RealtimeDictation?
        do {
            let preparedCapture = try await AgenTTYDictationLibrary.shared.prepare(backend: AgenTTYDictation.currentBackend())
            capture = preparedCapture
            let accountEvents = preparedCapture.writer != nil || preparedCapture.account != nil
                ? await AgenTTYDictationLibrary.shared.accountEvents() : nil
            registerDictationAudioSessionObserversIfNeeded()
            let hapticsEnabled = try await audioSessionBoundary.activateForRecording()
            if !hapticsEnabled { EsmaLog.terminal.error("dictation recording-session haptics are not enabled") }
            if case .direct(let model) = preparedCapture.backend, model.capture == .streaming {
                dictation = try AgenTTYRealtimeDictation.make(
                    model: model, languageHints: preparedCapture.plan.languages,
                    customVocabulary: preparedCapture.plan.dictionary
                )
            }
            let store: DictationRecordingStore<String>
            if let realtimeRecordingStore { store = realtimeRecordingStore }
            else {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Dictation")
                store = DictationRecordingStore(directory: directory, retention: try DictationRecordingRetention(maximumCount: 2, maximumAge: .seconds(24 * 60 * 60)))
                realtimeRecordingStore = store
            }
            let providerWriter = try await store.startRecording(owner: preparedCapture.backend.libraryIdentifier, sampleRate: dictation?.sampleRate ?? 16_000)
            writer = providerWriter
            let audioCapture = AgenTTYRealtimeAudioCapture(sampleRate: dictation?.sampleRate ?? 16_000)
            let providerSession = dictation
            let originalWriter = preparedCapture.writer
            try originalWriter?.configure(format: audioCapture.inputFormat)
            try audioCapture.start(originalAudioInput: { buffer in originalWriter?.append(buffer) }) { data in
                providerWriter.append(data)
                providerSession?.append(data)
            }
            realtimeAudioCapture = audioCapture
            realtimeDictation = dictation
            realtimeRecordingWriter = providerWriter
            activeDictationCapture = preparedCapture
            if let accountEvents {
                libraryAccountMonitor = Task { @MainActor [weak self] in
                    for await session in accountEvents {
                        guard !Task.isCancelled else { break }
                        if preparedCapture.account != session {
                            guard let self else { break }
                            dictationGeneration = UUID()
                            if isDictationProcessing { dictationProcessingTask?.cancel() }
                            else { beginStoppingDictation(.failed(DictationLibraryError.accountChanged)) }
                            break
                        }
                    }
                }
            }
            shouldMaintainDictationRecording = true
            pausedForDictationRouteLoss = false
            isDictationRecording = true
        } catch {
            await dictation?.cancel()
            if let capture {
                await AgenTTYDictationLibrary.shared.finishOriginal(capture)
                await AgenTTYDictationLibrary.shared.record(capture, text: String(reflecting: type(of: error)), kind: .failure, model: capture.backend.libraryIdentifier, contextWasUsed: false)
            }
            if let writer { try? await writer.discard() }
            dictationError = Self.dictationErrorMessage(for: error)
            deactivateAudioSession()
        }
        isDictationArming = false
    }

    nonisolated private static func dictationErrorMessage(for error: any Error) -> String {
        if error is AgenTTYDictation.ConfigurationError {
            return error.localizedDescription
        }
        return "Dictation failed: \(error.localizedDescription)"
    }

    private func captureDictationShellContext() async -> String? {
        guard let sink else { return nil }
        let rawContext = await sink.captureDictationShellContext(maxLines: Self.dictationShellContextLineCount)
        let normalizedContext = Self.normalizeDictationShellContext(rawContext)
        guard let normalizedContext else {
            EsmaLog.terminal.debug("dictation context capture unavailable")
            return nil
        }
        let lineCount = normalizedContext.split(whereSeparator: \.isNewline).count
        EsmaLog.terminal.debug(
            "dictation context captured lines=\(lineCount) chars=\(normalizedContext.count)"
        )
        return normalizedContext
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch audioSessionBoundary.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                audioSessionBoundary.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func deactivateAudioSession() {
        do {
            try audioSessionBoundary.deactivateAfterRecording()
        } catch {
            EsmaLog.terminal.error("dictation failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func registerDictationAudioSessionObserversIfNeeded() {
        if dictationInterruptionObserver != nil { return }

        let notificationCenter = NotificationCenter.default
        dictationInterruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSessionBoundary.notificationObject,
            queue: .main
        ) { [weak self] notification in
            let payload = DictationInterruptionPayload(notification: notification)
            MainActor.assumeIsolated { [weak self, payload] in
                self?.handleDictationAudioInterruption(payload)
            }
        }

        dictationRouteChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSessionBoundary.notificationObject,
            queue: .main
        ) { [weak self] notification in
            let payload = DictationRouteChangePayload(notification: notification)
            MainActor.assumeIsolated { [weak self, payload] in
                self?.handleDictationAudioRouteChange(payload)
            }
        }
    }

    private func handleDictationAudioInterruption(_ payload: DictationInterruptionPayload?) {
        guard let payload else {
            EsmaLog.terminal.error("dictation interruption payload missing required fields")
            return
        }

        switch payload.type {
        case .began:
            guard shouldMaintainDictationRecording else { return }
            pauseDictationRecordingIfNeeded(context: "audio-session interruption")
        case .ended:
            guard shouldMaintainDictationRecording else { return }
            guard payload.options.contains(.shouldResume) else {
                shouldMaintainDictationRecording = false
                pausedForDictationRouteLoss = false
                isDictationRecording = false
                EsmaLog.terminal.notice("dictation interruption ended without shouldResume; staying stopped")
                return
            }

            resumeDictationRecordingIfNeeded(context: "interruption")
        @unknown default:
            break
        }
    }

    private func handleDictationAudioRouteChange(_ payload: DictationRouteChangePayload?) {
        guard shouldMaintainDictationRecording else { return }
        guard let payload else {
            EsmaLog.terminal.error("dictation route-change payload missing required fields")
            return
        }

        switch payload.reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            if pauseDictationRecordingIfNeeded(context: "route change") {
                pausedForDictationRouteLoss = true
                EsmaLog.terminal.notice(
                    "dictation route became unavailable: \(payload.reason.rawValue, privacy: .public)"
                )
            }
        default:
            break
        }

        if pausedForDictationRouteLoss, audioSessionBoundary.isInputAvailable {
            resumeDictationRecordingIfNeeded(context: "route change")
        }
    }

    @discardableResult
    private func pauseDictationRecordingIfNeeded(context: String) -> Bool {
        if let realtimeAudioCapture, realtimeAudioCapture.isRecording {
            realtimeAudioCapture.pause()
            EsmaLog.terminal.notice("dictation paused due to \(context, privacy: .public)")
            return true
        }
        return false
    }

    private func resumeDictationRecordingIfNeeded(context: String) {
        guard shouldMaintainDictationRecording else { return }
        if realtimeAudioCapture?.isRecording == true {
            pausedForDictationRouteLoss = false
            return
        }

        do {
            try audioSessionBoundary.activateForResume()
            if let realtimeAudioCapture {
                try realtimeAudioCapture.resume()
            } else {
                return
            }

            guard realtimeAudioCapture?.isRecording == true else {
                throw DictationRecordingError.failedToResume
            }

            pausedForDictationRouteLoss = false
            isDictationRecording = true
            EsmaLog.terminal.notice("dictation resumed after \(context, privacy: .public)")
        } catch {
            shouldMaintainDictationRecording = false
            pausedForDictationRouteLoss = false
            isDictationRecording = false
            EsmaLog.terminal.error("dictation resume failed after \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
            beginStoppingDictation(.failed(error))
        }
    }

    @concurrent
    nonisolated private static func transcribeDictationAudio(
        preparedAudio: PreparedDictationAudio,
        instructions: String?,
        backend: AgenTTYDictation.Backend,
        languageHints: [String],
        customVocabulary: [String]
    ) async throws -> String {
        switch backend {
        case .relayOpenAI:
            let response = try await AgenTTYDictationRelayClient.shared.transcribe(
                audioData: preparedAudio.audioData,
                fileName: Self.dictationFileName,
                mimeType: Self.dictationMimeType,
                instructions: customVocabulary.isEmpty ? instructions : [instructions, "Preserve these dictionary terms when spoken: " + customVocabulary.joined(separator: ", ")].compactMap { $0 }.joined(separator: "\n\n"),
                languageHints: languageHints
            )
            EsmaLog.terminal.notice(
                "dictation transcribe: relay charged_seconds=\(response.secondsCharged, privacy: .public) remaining_seconds=\(response.remainingSecondsThisWeek, privacy: .public)"
            )
            return response.text
        case .direct(let model):
            return try await transcribeDictationAudio(
                preparedAudio: preparedAudio,
                instructions: instructions,
                model: model,
                languageHints: languageHints,
                customVocabulary: customVocabulary
            )
        }
    }

    @concurrent
    nonisolated private static func transcribeDictationAudio(
        preparedAudio: PreparedDictationAudio,
        instructions: String?,
        model: AgenTTYDictation.Model,
        languageHints: [String],
        customVocabulary: [String]
    ) async throws -> String {
        let transcriptionRequest = TranscriptionRequest(
            audio: preparedAudio.transcriptionAudio,
            languageHints: languageHints,
            customVocabulary: customVocabulary,
            instructions: instructions
        )
        let engine = try AgenTTYBatchTranscription.engine(for: model)
        return try await engine.transcribe(transcriptionRequest).text
    }

    nonisolated private static func maximumAudioByteCount(backend: AgenTTYDictation.Backend) throws -> Int {
        switch backend {
        case .relayOpenAI: AgenTTYDictationRelayClient.maximumAudioByteCount
        case .direct(let model): try AgenTTYBatchTranscription.engine(for: model).maximumAudioByteCount
        }
    }

    private enum DictationRecordingError: LocalizedError {
        case failedToResume

        var errorDescription: String? {
            switch self {
            case .failedToResume:
                "failed to resume dictation recorder"
            }
        }
    }

    nonisolated private static let dictationFileName = "dictation.wav"
    nonisolated private static let dictationMimeType = "audio/wav"

    nonisolated private static func shouldReportDictationErrorToSentry(_ error: Error) -> Bool {
        if error is AgenTTYDictation.ConfigurationError {
            return false
        }
        if let relayError = error as? AgenTTYDictationRelayError {
            return relayError.shouldCaptureToSentry
        }
        return true
    }

}

private nonisolated struct PreparedDictationAudio: Sendable {
    let audioData: Data
    let transcriptionAudio: TranscriptionAudio
}

private nonisolated struct DictationInterruptionPayload: Sendable {
    let type: AVAudioSession.InterruptionType
    let options: AVAudioSession.InterruptionOptions

    nonisolated init?(notification: Notification) {
        guard let userInfo = notification.userInfo else { return nil }
        guard let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return nil
        }
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return nil
        }

        self.type = type
        if let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
            options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        } else {
            options = []
        }
    }
}

private nonisolated struct DictationRouteChangePayload: Sendable {
    let reason: AVAudioSession.RouteChangeReason

    nonisolated init?(notification: Notification) {
        guard let userInfo = notification.userInfo else { return nil }
        guard let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return nil
        }
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return nil
        }
        self.reason = reason
    }
}
