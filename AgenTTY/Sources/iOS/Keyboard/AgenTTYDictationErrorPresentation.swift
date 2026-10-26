import Foundation
import SpeechKit

nonisolated enum AgenTTYDictationErrorPresentation {
    static func message(for error: any Error, hasLifetimeAccess: Bool, now: Date) -> String {
        if let kind = relayRejectionKind(for: error) {
            switch kind {
            case "quota_exhausted":
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let reset = calendar.dateInterval(of: .month, for: now)!.end
                let formatter = DateFormatter()
                formatter.timeZone = .gmt
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                let upgrade = hasLifetimeAccess ? "" : " Lifetime access raises the limit to 120 minutes a month."
                return "Monthly dictation limit reached. Resets on \(formatter.string(from: reset)) at 00:00 UTC.\(upgrade)"
            case "busy", "service_limit", "upstream_unavailable":
                return "Dictation is temporarily unavailable. Try again shortly."
            case "unauthorized":
                return "Dictation authorization expired. Please try again."
            case "verification_required":
                return "Dictation requires a verified App Store installation."
            case "audio_too_long":
                return "Recordings are limited to 15 minutes. Please dictate in shorter parts."
            case "invalid_request":
                return "This recording could not be transcribed. Please try a new recording."
            default:
                return "Dictation is temporarily unavailable. Please try again."
            }
        }
        if error is AgenTTYDictation.ConfigurationError { return error.localizedDescription }
        return "Dictation failed: \(error.localizedDescription)"
    }

    static func relayRejectionKind(for error: any Error) -> String? {
        if case SpeechKitError.relayRejected(let kind) = error { return kind }
        if let error = error as? RealtimeDictationError {
            switch error {
            case .connectionFailed(let underlying), .streamFailed(let underlying), .commitFailed(let underlying):
                return relayRejectionKind(for: underlying)
            case .streamEnded, .finalizationTimedOut, .audioBufferOverflow:
                return nil
            }
        }
        return nil
    }

    static func shouldCaptureToSentry(_ error: any Error) -> Bool {
        if error is AgenTTYDictation.ConfigurationError || error is CancellationError { return false }
        if let kind = relayRejectionKind(for: error) {
            return !["quota_exhausted", "busy", "service_limit", "audio_too_long"].contains(kind)
        }
        return true
    }
}
