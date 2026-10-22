import Foundation

struct RepeatTickStep {
    let nextDelay: TimeInterval
    let emitsHaptic: Bool
}

@MainActor
final class KeyboardRepeatEngine {
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var holdStartTime: TimeInterval?
    private var lastHapticTime: TimeInterval?

    func start(
        initialDelay: TimeInterval,
        hapticMinimumInterval: TimeInterval?,
        onRepeat: @escaping @MainActor (_ holdDuration: TimeInterval) -> RepeatTickStep?
    ) {
        stop()
        holdStartTime = ProcessInfo.processInfo.systemUptime
        let generation = self.generation
        schedule(
            after: initialDelay,
            generation: generation,
            hapticMinimumInterval: hapticMinimumInterval,
            onRepeat: onRepeat
        )
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        holdStartTime = nil
        lastHapticTime = nil
    }

    private func schedule(
        after delay: TimeInterval,
        generation: UInt64,
        hapticMinimumInterval: TimeInterval?,
        onRepeat: @escaping @MainActor (_ holdDuration: TimeInterval) -> RepeatTickStep?
    ) {
        let safeDelay = max(delay, 0.001)
        let timer = Timer(timeInterval: safeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.generation else { return }

                let holdDuration = self.currentHoldDuration
                guard let step = onRepeat(holdDuration) else {
                    self.stop()
                    return
                }

                if step.emitsHaptic {
                    self.fireRepeatHapticIfNeeded(minimumInterval: hapticMinimumInterval)
                }

                self.schedule(
                    after: step.nextDelay,
                    generation: generation,
                    hapticMinimumInterval: hapticMinimumInterval,
                    onRepeat: onRepeat
                )
            }
        }

        // Use .common mode so timers fire while the RunLoop is in .tracking mode
        // (i.e. while a touch/drag gesture is active). Timer.scheduledTimer only
        // uses .default mode and therefore never fires during an active gesture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var currentHoldDuration: TimeInterval {
        guard let holdStartTime else { return 0 }
        return ProcessInfo.processInfo.systemUptime - holdStartTime
    }

    private func fireRepeatHapticIfNeeded(minimumInterval: TimeInterval?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let minimumInterval,
           let lastHapticTime,
           now - lastHapticTime < minimumInterval {
            return
        }

        lastHapticTime = now
        KeyboardHaptics.keyRepeat()
    }
}
