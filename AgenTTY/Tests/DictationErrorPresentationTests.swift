import Foundation
import SpeechKit
import Testing
@testable import AgenTTY_iOS

@Suite
struct DictationErrorPresentationTests {
    @Test
    func monthlyQuotaResetUsesTheNextUTCMonthAcrossTheYearBoundary() {
        let now = Date(timeIntervalSince1970: 1_798_761_540)
        let reset = Date(timeIntervalSince1970: 1_798_761_600)
        let formatter = DateFormatter()
        formatter.timeZone = .gmt
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let error = RealtimeDictationError.commitFailed(SpeechKitError.relayRejected(kind: "quota_exhausted"))

        let trial = AgenTTYDictationErrorPresentation.message(for: error, hasLifetimeAccess: false, now: now)
        let lifetime = AgenTTYDictationErrorPresentation.message(for: error, hasLifetimeAccess: true, now: now)

        #expect(trial.contains(formatter.string(from: reset)))
        #expect(trial.contains("00:00 UTC"))
        #expect(trial.contains("120 minutes a month"))
        #expect(!lifetime.contains("Lifetime access"))
        #expect(!AgenTTYDictationErrorPresentation.shouldCaptureToSentry(error))
    }

    @Test(arguments: ["busy", "service_limit", "upstream_unavailable"])
    func temporaryRefusalsSuggestTryingAgain(kind: String) {
        let error = SpeechKitError.relayRejected(kind: kind)
        let message = AgenTTYDictationErrorPresentation.message(for: error, hasLifetimeAccess: false, now: .distantPast)
        #expect(message == "Dictation is temporarily unavailable. Try again shortly.")
    }

    @Test
    func overlongRecordingsExplainTheLimitWithoutReportingACrash() {
        let error = SpeechKitError.relayRejected(kind: "audio_too_long")
        let message = AgenTTYDictationErrorPresentation.message(for: error, hasLifetimeAccess: true, now: .distantPast)
        #expect(message.contains("15 minutes"))
        #expect(!AgenTTYDictationErrorPresentation.shouldCaptureToSentry(error))
    }
}
