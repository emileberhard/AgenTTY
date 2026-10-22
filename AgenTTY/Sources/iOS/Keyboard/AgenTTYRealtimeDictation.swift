import AVFoundation
import Foundation
import SpeechKit
import DictationLibrary

nonisolated enum AgenTTYRealtimeDictationError: LocalizedError, Sendable {
    case notStreaming(AgenTTYDictation.Model)

    var errorDescription: String? {
        switch self {
        case .notStreaming(let model):
            "\(model.displayName) transcribes the finished recording, not a live stream."
        }
    }
}

nonisolated enum AgenTTYRealtimeDictation {
    static func transcribe(
        dictation: RealtimeDictation,
        recording: DictationRecording<String>?,
        model: AgenTTYDictation.Model,
        languageHints: [String],
        customVocabulary: [String]
    ) async throws -> AgenTTYDictationOutput {
        try await transcribe(dictation: dictation, modelID: model.libraryIdentifier) { error in
            guard let recording else { throw error }
            let engine = try AgenTTYBatchTranscription.engine(for: model)
            let audio = try await recording.transcriptionAudio(maximumByteCount: engine.maximumAudioByteCount)
            let request = TranscriptionRequest(audio: audio, languageHints: languageHints, customVocabulary: customVocabulary)
            return AgenTTYDictationOutput(text: try await engine.transcribe(request).text, model: model.batchLibraryIdentifier, kind: .providerOutput, contextWasUsed: false)
        }
    }

    static func transcribe(
        dictation: RealtimeDictation,
        modelID: String,
        fallback: @Sendable (any Error) async throws -> AgenTTYDictationOutput
    ) async throws -> AgenTTYDictationOutput {
        do {
            return AgenTTYDictationOutput(text: try await dictation.finish(), model: modelID, kind: .providerOutput, contextWasUsed: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback(error)
        }
    }

    static func make(
        model: AgenTTYDictation.Model,
        languageHints: [String],
        customVocabulary: [String]
    ) throws -> RealtimeDictation {
        switch model {
        case .elevenLabsScribeV2Realtime:
            let configuration = try ElevenLabsRealtimeSessionConfiguration(
                access: .router(AgenTTYDictation.router()),
                keyterms: ElevenLabsRealtimeSessionConfiguration.compatibleKeyterms(from: customVocabulary),
                languageHints: languageHints,
                includeTimestamps: false
            )
            return RealtimeDictation(session: ElevenLabsRealtimeSession(configuration: configuration))
        case .openAIRealtimeWhisper:
            return try openAI(modelID: "gpt-realtime-whisper", languageHints: languageHints, customVocabulary: customVocabulary)
        case .openAIGPT4oTranscribeRealtime:
            return try openAI(modelID: "gpt-4o-transcribe", languageHints: languageHints, customVocabulary: customVocabulary)
        case .openAIGPT4oMiniTranscribeRealtime:
            return try openAI(modelID: "gpt-4o-mini-transcribe", languageHints: languageHints, customVocabulary: customVocabulary)
        case .gemini35TranscribeLiveSmart:
            return try gemini(mode: .smart, languageHints: languageHints, customVocabulary: customVocabulary)
        case .gemini35TranscribeLiveVerbatim:
            return try gemini(mode: .verbatim, languageHints: languageHints, customVocabulary: customVocabulary)
        case .assemblyAIUniversal35ProRealtime:
            let configuration = try AssemblyAIRealtimeSessionConfiguration(
                access: .router(AgenTTYDictation.router()),
                keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(from: customVocabulary),
                languageHints: languageHints
            )
            return RealtimeDictation(session: AssemblyAIRealtimeSession(configuration: configuration))
        case .azureMAITranscribe2:
            let session = ProgressiveRealtimeTranscriptionSession(
                provider: AzureSpeechTranscriptionProvider(configuration: try AgenTTYAzureSpeech.configuration()),
                request: ProgressiveTranscriptionRequest(
                    languageHints: languageHints,
                    customVocabulary: customVocabulary
                )
            )
            return RealtimeDictation(session: session)
        case .elevenLabsScribeV2,
             .openAIGPT4oMiniTranscribe, .openAIGPT4oTranscribe, .openAIWhisper1,
             .gemini31Pro, .gemini35Flash, .gemini35TranscribeSmart, .gemini35TranscribeVerbatim,
             .assemblyAIUniversal35Pro:
            throw AgenTTYRealtimeDictationError.notStreaming(model)
        }
    }

    private static func openAI(
        modelID: String,
        languageHints: [String],
        customVocabulary: [String]
    ) throws -> RealtimeDictation {
        let isRealtimeWhisper = modelID.hasPrefix("gpt-realtime-whisper")
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .router(AgenTTYDictation.router()),
            modelID: modelID,
            customVocabulary: OpenAIRealtimeSessionConfiguration.supportsCustomVocabulary(modelID: modelID)
                ? customVocabulary
                : [],
            languageHints: languageHints,
            turnDetection: isRealtimeWhisper ? .disabled : .semanticVAD(eagerness: .low),
            transcriptionDelay: isRealtimeWhisper ? .high : nil,
            noiseReduction: .nearField
        )
        return RealtimeDictation(session: OpenAIRealtimeSession(configuration: configuration))
    }

    private static func gemini(
        mode: GeminiTranscriptionMode,
        languageHints: [String],
        customVocabulary: [String]
    ) throws -> RealtimeDictation {
        let configuration = try GeminiRealtimeSessionConfiguration(
            access: .router(AgenTTYDictation.router()),
            customVocabulary: customVocabulary,
            languageHints: languageHints,
            mode: mode
        )
        return RealtimeDictation(session: GeminiRealtimeSession(configuration: configuration))
    }
}

@MainActor
final class AgenTTYRealtimeAudioCapture {
    private let engine = AVAudioEngine()
    private let sampleRate: Int
    private var processor: AgenTTYPCM16TapProcessor?
    private var audioInput: (@Sendable (Data) -> Void)?
    private var originalAudioInput: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var isRecording = false

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    func start(
        originalAudioInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        audioInput: @escaping @Sendable (Data) -> Void
    ) throws {
        guard !isRecording else { return }
        self.audioInput = audioInput
        self.originalAudioInput = originalAudioInput
        try installTap(originalAudioInput: originalAudioInput, audioInput: audioInput)
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            removeTap()
            self.audioInput = nil
            throw error
        }
    }

    func pause() {
        guard isRecording else { return }
        removeTap()
        engine.stop()
        isRecording = false
    }

    func resume() throws {
        guard !isRecording, let audioInput, let originalAudioInput else { return }
        try installTap(originalAudioInput: originalAudioInput, audioInput: audioInput)
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            removeTap()
            throw error
        }
    }

    func stop() {
        removeTap()
        engine.stop()
        audioInput = nil
        originalAudioInput = nil
        isRecording = false
    }

    private func installTap(
        originalAudioInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        audioInput: @escaping @Sendable (Data) -> Void
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(sampleRate),
                  channels: 1,
                  interleaved: true
              ),
              let processor = AgenTTYPCM16TapProcessor(
                  inputFormat: inputFormat,
                  targetFormat: targetFormat,
                  audioInput: audioInput
              )
        else {
            throw AgenTTYRealtimeAudioCaptureError.formatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { @Sendable buffer, _ in
            originalAudioInput(buffer)
            processor.ingest(buffer)
        }
        self.processor = processor
    }

    private func removeTap() {
        guard processor != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        processor = nil
    }
}

nonisolated enum AgenTTYRealtimeAudioCaptureError: LocalizedError, Sendable {
    case formatUnavailable

    var errorDescription: String? {
        "Could not configure realtime microphone audio."
    }
}

private final class AgenTTYPCM16TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let audioInput: @Sendable (Data) -> Void

    init?(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        audioInput: @escaping @Sendable (Data) -> Void
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }
        self.converter = converter
        self.targetFormat = targetFormat
        self.audioInput = audioInput
    }

    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        let convertedData: Data? = {
            nonisolated(unsafe) var suppliedInput = false
            nonisolated(unsafe) let inputBuffer = buffer
            var conversionError: NSError?
            let status = unsafe converter.convert(to: converted, error: &conversionError) { _, outputStatus in
                if unsafe suppliedInput {
                    unsafe outputStatus.pointee = .noDataNow
                    return nil
                }
                unsafe suppliedInput = true
                unsafe outputStatus.pointee = .haveData
                return unsafe inputBuffer
            }
            guard status != .error, converted.frameLength > 0 else { return nil }
            guard let channelData = unsafe converted.int16ChannelData else { return nil }

            return unsafe Data(
                bytes: channelData[0],
                count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            )
        }()
        guard let convertedData else { return }
        audioInput(convertedData)
    }
}

nonisolated struct AgenTTYDictationOutput: Sendable {
    let text: String
    let model: String
    let kind: DictationResultKind
    let contextWasUsed: Bool
}
