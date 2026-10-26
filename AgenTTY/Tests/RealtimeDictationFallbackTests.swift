import Foundation
import os
import SpeechKit
import Testing
@testable import AgenTTY_iOS

@Suite
struct RealtimeDictationFallbackTests {
    @Test
    func relayQuotaRejectionDoesNotUploadTheRecordingAgain() async throws {
        let dictation = RealtimeDictation(session: RejectedRealtimeSession())
        dictation.append(Data(repeating: 0, count: 320))

        do {
            _ = try await AgenTTYRealtimeDictation.transcribe(dictation: dictation, modelID: "relay") { _ in
                Issue.record("A relay refusal must not trigger a batch upload")
                return AgenTTYDictationOutput(text: "", model: "batch", kind: .providerOutput, contextWasUsed: false)
            }
            Issue.record("Expected the quota rejection")
        } catch SpeechKitError.relayRejected(let kind) {
            #expect(kind == "quota_exhausted")
        }
    }

    @Test
    func relayRecoversOnlyWhenTheUploadNeverStarted() {
        let underlying = URLError(.networkConnectionLost)
        let relay = AgenTTYDictation.Backend.relayMAITranscribe2
        #expect(AgenTTYRealtimeDictation.recoversWithBatch(after: RealtimeDictationError.connectionFailed(underlying), backend: relay))
        for error in [
            RealtimeDictationError.streamFailed(underlying),
            .commitFailed(underlying),
            .streamEnded,
            .finalizationTimedOut,
        ] {
            #expect(!AgenTTYRealtimeDictation.recoversWithBatch(after: error, backend: relay))
        }
        #expect(AgenTTYRealtimeDictation.recoversWithBatch(
            after: RealtimeDictationError.finalizationTimedOut,
            backend: .direct(.azureMAITranscribe2)
        ))
    }

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

private struct RejectedRealtimeSession: RealtimeTranscriptionSession {
    let sampleRate = 16_000
    let finalizationTimeout: Duration = .seconds(1)

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        throw SpeechKitError.relayRejected(kind: "quota_exhausted")
    }

    func sendAudioChunk(_ audioData: Data) async throws {}
    func requestCommit() async throws {}
    func disconnect() async {}
}
