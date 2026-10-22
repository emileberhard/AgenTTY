import Foundation
import os
import SpeechKit
import Testing
@testable import AgenTTY_iOS

@Suite
struct RealtimeDictationFallbackTests {
    @Test
    func usesBatchResultWhenFinalCommitNeverCompletes() async throws {
        let dictation = RealtimeDictation(session: UnfinalizedRealtimeSession())
        dictation.append(Data(repeating: 0, count: 320))

        let output = try await AgenTTYRealtimeDictation.transcribe(dictation: dictation, modelID: "realtime") { _ in
            AgenTTYDictationOutput(text: "complete batch transcript", model: "batch", kind: .providerOutput, contextWasUsed: false)
        }

        #expect(output.text == "complete batch transcript")
        #expect(output.model == "batch")
        #expect(output.kind == .providerOutput)
    }
}

private final class UnfinalizedRealtimeSession: RealtimeTranscriptionSession, @unchecked Sendable {
    let sampleRate = 16_000
    let finalizationTimeout: Duration = .milliseconds(100)
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.Continuation?>(initialState: nil)

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        AsyncThrowingStream { stream in
            continuation.withLock { $0 = stream }
        }
    }

    func sendAudioChunk(_ audioData: Data) async throws {}

    func requestCommit() async throws {
        continuation.withLock { stream in
            stream?.yield(.committedTranscript("partial realtime transcript"))
            stream?.finish()
        }
    }

    func disconnect() async {
        continuation.withLock { $0?.finish() }
    }
}
