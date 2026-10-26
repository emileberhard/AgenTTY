import AVFoundation
import Foundation
import SpeechKit
import Testing
@testable import AgenTTY_iOS_Dev

@Suite("Live configured terminal dictation", .serialized)
nonisolated struct AgenTTYDictationIntegrationTests {
    private let languages = ["en", "sv"]
    private let dictionary = ["AgenTTY", "NuGet", "git", "status"]

    @Test
    func batchFactoryTranscribesWithTerminalContextAndDictionary() async throws {
        let model = AgenTTYDictation.Model.openAIGPT4oMiniTranscribe
        let engine = try await AgenTTYBatchTranscription.engine(for: model)
        let audio = try TranscriptionAudio(
            data: Data(contentsOf: Self.fixture()), fileName: "terminal-dictation.wav",
            mimeType: "audio/wav", fileExtension: "wav"
        )
        let request = TranscriptionRequest(
            audio: audio, languageHints: languages, customVocabulary: dictionary,
            instructions: TerminalInputRouter.dictationOpenAIInstructionsText(shellContext: "$ git status\nOn branch main")
        )
        let result = try await engine.transcribe(request)
        Self.expectComplete(result.text)
    }

    @Test
    func realtimeFactoryFinalizesAndPreservesFallbackAudio() async throws {
        let model = AgenTTYDictation.Model.elevenLabsScribeV2Realtime
        let dictation = try await AgenTTYRealtimeDictation.make(model: model, languageHints: languages, customVocabulary: dictionary)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecordingStore<String>(directory: directory, retention: try DictationRecordingRetention(maximumCount: 1, maximumAge: .seconds(600)))
        let writer = try await store.startRecording(owner: model.libraryIdentifier, sampleRate: dictation.sampleRate)
        let pcm = try Self.pcm16()
        for start in stride(from: 0, to: pcm.count, by: 3_200) {
            let chunk = pcm.subdata(in: start..<min(start + 3_200, pcm.count))
            writer.append(chunk)
            dictation.append(chunk)
        }
        let recording = try await writer.finish()
        let output = try await AgenTTYRealtimeDictation.transcribe(
            dictation: dictation, recording: recording, backend: .direct(model),
            languageHints: languages, customVocabulary: dictionary
        )
        Self.expectComplete(output.text)
        #expect(output.model == model.libraryIdentifier)
        #expect(output.kind == .providerOutput)
        try await store.discard(recording)
    }

    private static func fixture() throws -> URL {
        try #require(Bundle(for: DictationFixtureBundle.self).url(forResource: "terminal-dictation", withExtension: "wav"))
    }

    private static func pcm16() throws -> Data {
        let file = try AVAudioFile(forReading: fixture(), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        guard let samples = unsafe buffer.int16ChannelData else { throw SpeechKitError.invalidRequest("Fixture PCM is unavailable") }
        return unsafe Data(bytes: samples[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func expectComplete(_ text: String) {
        let lower = text.lowercased()
        #expect(lower.contains("git"))
        #expect(lower.contains("status"))
        #expect(lower.contains("recording"))
        #expect(lower.contains("stop"))
    }
}

private final class DictationFixtureBundle: NSObject {}
