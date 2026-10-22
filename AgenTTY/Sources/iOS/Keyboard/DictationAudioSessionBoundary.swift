import AVFoundation
import Foundation

protocol DictationAudioSessionBoundary {
    var notificationObject: AVAudioSession { get }
    var recordPermission: AVAudioApplication.recordPermission { get }
    var isInputAvailable: Bool { get }
    func requestRecordPermission(_ callback: @Sendable @escaping (Bool) -> Void)
    func activateForRecording() async throws -> Bool
    func activateForResume() throws
    func deactivateAfterRecording() throws
}

struct SystemDictationAudioSessionBoundary: DictationAudioSessionBoundary {
    var notificationObject: AVAudioSession {
        AVAudioSession.sharedInstance()
    }

    var recordPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    var isInputAvailable: Bool {
        notificationObject.isInputAvailable
    }

    func requestRecordPermission(_ callback: @Sendable @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            callback(granted)
        }
    }

    @concurrent
    nonisolated
    func activateForRecording() async throws -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker]
        )
        try audioSession.setActive(true)
        preferBuiltInMicrophoneIfPossible(for: audioSession, context: "recording start")
        do {
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            EsmaLog.terminal.error(
                "dictation could not enable haptics/system sounds during recording: \(error.localizedDescription, privacy: .public)"
            )
        }
        return audioSession.allowHapticsAndSystemSoundsDuringRecording
    }

    func activateForResume() throws {
        try notificationObject.setActive(true, options: [])
        preferBuiltInMicrophoneIfPossible(for: notificationObject, context: "recording resume")
    }

    func deactivateAfterRecording() throws {
        try notificationObject.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated
    private func preferBuiltInMicrophoneIfPossible(for audioSession: AVAudioSession, context: String) {
        guard let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            EsmaLog.terminal.notice("dictation built-in microphone unavailable; using current input route")
            logActiveInputRoute(for: audioSession, context: context)
            return
        }

        do {
            try audioSession.setPreferredInput(nil)
            try audioSession.setPreferredInput(builtInMic)
            logActiveInputRoute(for: audioSession, context: context)
        } catch {
            EsmaLog.terminal.error(
                "dictation failed to prefer built-in microphone (\(builtInMic.portName, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    nonisolated
    private func logActiveInputRoute(for audioSession: AVAudioSession, context: String) {
        guard let activeInput = audioSession.currentRoute.inputs.first else {
            EsmaLog.terminal.error("dictation \(context, privacy: .public): no active input route after microphone selection")
            return
        }

        if activeInput.portType == .builtInMic {
            EsmaLog.terminal.notice(
                "dictation \(context, privacy: .public): active input is built-in microphone (\(activeInput.portName, privacy: .public))"
            )
            return
        }

        EsmaLog.terminal.error(
            "dictation \(context, privacy: .public): active input remains non-built-in (\(activeInput.portName, privacy: .public))"
        )
    }
}
