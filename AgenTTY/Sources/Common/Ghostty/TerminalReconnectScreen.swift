import Foundation
#if os(iOS)
import UIKit
#endif

/// What the in-terminal reconnect screen reports while AgenTTY is automatically
/// working its way back to the host. Manual-recovery and permanently-blocked
/// states are deliberately absent: those keep the existing recovery alert plus
/// ordinary `[agentty]` status lines.
nonisolated enum AgenTTYReconnectScreenPhase: Equatable, Sendable {
    /// A connection attempt is in flight. `attempt` is 0 for the first connect
    /// after a host is selected and >= 1 for every automatic retry.
    case connecting(attempt: Int)
    /// Backoff is running; the next attempt starts at `retryAt`.
    case waitingToRetry(attempt: Int, retryAt: Date)
}

nonisolated struct AgenTTYReconnectScreenInput: Equatable, Sendable {
    /// `nil` means the screen must not be on screen.
    var phase: AgenTTYReconnectScreenPhase?
    var hostLabel: String
    var columns: Int
    var rows: Int
    /// False while the app is not foreground active, which stops the spinner
    /// instead of burning background time on terminal writes nobody can see.
    var isAnimating: Bool
}

/// Pure text/escape-sequence construction for the reconnect screen.
nonisolated enum AgenTTYReconnectScreenRenderer {
    enum Slot: Equatable, Sendable {
        case spinner
        case blank
        case headline
        case detail
        case footer
    }

    struct Layout: Equatable, Sendable {
        let slots: [Slot]
        let topPadding: Int

        /// 1-based terminal row of `slot`, or nil when the layout dropped it.
        func row(of slot: Slot) -> Int? {
            guard let index = slots.firstIndex(of: slot) else { return nil }
            return topPadding + index + 1
        }
    }

    static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let animatedTickInterval: TimeInterval = 0.1
    static let reducedMotionTickInterval: TimeInterval = 1.0
    static let footerText = "Shell switching is paused until AgenTTY reconnects."

    static func tickInterval(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedMotionTickInterval : animatedTickInterval
    }

    static func spinnerFrame(at tick: Int) -> String {
        let count = spinnerFrames.count
        let index = ((tick % count) + count) % count
        return spinnerFrames[index]
    }

    static func headline(phase: AgenTTYReconnectScreenPhase, hostLabel: String) -> String {
        let name = hostLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = name.isEmpty ? "host" : name
        switch phase {
        case .connecting(let attempt):
            return attempt <= 0 ? "Connecting to \(host)" : "Reconnecting to \(host)"
        case .waitingToRetry:
            return "Reconnecting to \(host)"
        }
    }

    static func detail(phase: AgenTTYReconnectScreenPhase, now: Date) -> String {
        switch phase {
        case .connecting(let attempt):
            return attempt <= 0 ? "" : "attempt \(attempt)"
        case .waitingToRetry(let attempt, let retryAt):
            let remaining = max(1, Int(ceil(retryAt.timeIntervalSince(now))))
            return "attempt \(attempt) · retrying in \(remaining)s"
        }
    }

    static func layout(rows: Int) -> Layout {
        let full: [Slot] = [.spinner, .blank, .headline, .blank, .detail, .blank, .footer]
        let compact: [Slot] = [.spinner, .blank, .headline, .detail]
        let minimal: [Slot] = [.spinner, .headline, .detail]

        let slots: [Slot]
        if rows >= full.count + 2 {
            slots = full
        } else if rows >= compact.count + 2 {
            slots = compact
        } else {
            slots = minimal
        }
        return Layout(slots: slots, topPadding: max((rows - slots.count) / 2, 0))
    }

    /// Full-screen takeover: clear, hide the cursor, and paint every slot.
    static func fullScreenData(
        phase: AgenTTYReconnectScreenPhase,
        hostLabel: String,
        columns: Int,
        rows: Int,
        tick: Int,
        now: Date
    ) -> Data {
        let layout = layout(rows: rows)
        var text = "\(hideCursor)\(reset)\(clearScreen)"
        text += String(repeating: "\r\n", count: layout.topPadding)

        let painted = layout.slots.map { slot -> String in
            switch slot {
            case .spinner:
                return centered(spinnerFrame(at: tick), columns: columns)
            case .blank:
                return ""
            case .headline:
                return centered(headline(phase: phase, hostLabel: hostLabel), columns: columns)
            case .detail:
                return centered(detail(phase: phase, now: now), columns: columns)
            case .footer:
                return "\(dim)\(centered(footerText, columns: columns))\(undim)"
            }
        }
        text += painted.joined(separator: "\r\n")
        return Data(text.utf8)
    }

    /// Repaint one already-drawn row without touching the rest of the screen.
    static func rowData(text: String, row: Int, columns: Int) -> Data {
        let sequence = "\(moveToRow(row))\(eraseLine)\(centered(text, columns: columns))"
        return Data(sequence.utf8)
    }

    /// Hand the terminal back: clear the takeover and restore the cursor.
    static func dismissData() -> Data {
        Data("\(reset)\(clearScreen)\(showCursor)".utf8)
    }

    static func centered(_ line: String, columns: Int) -> String {
        guard !line.isEmpty else { return "" }
        let availableColumns = max(columns, 1)
        let fitted = line.count <= availableColumns ? line : String(line.prefix(availableColumns))
        let leadingPadding = max((availableColumns - fitted.count) / 2, 0)
        return String(repeating: " ", count: leadingPadding) + fitted
    }

    private static let reset = "\u{1B}[0m"
    private static let dim = "\u{1B}[2m"
    private static let undim = "\u{1B}[22m"
    private static let clearScreen = "\u{1B}[2J\u{1B}[H"
    private static let hideCursor = "\u{1B}[?25l"
    private static let showCursor = "\u{1B}[?25h"
    private static let eraseLine = "\u{1B}[2K"

    private static func moveToRow(_ row: Int) -> String {
        "\u{1B}[\(max(row, 1));1H"
    }
}

/// Owns the reconnect screen's draw/tick/teardown lifecycle so `TerminalBridge`
/// only has to publish the current connection facts.
@MainActor
final class TerminalReconnectScreenPresenter {
    /// Writes terminal bytes locally (never over SSH).
    var writeOutput: ((Data, String) -> Void)?

    /// True once the screen owns the terminal, which is also the signal that
    /// `[agentty]` status lines must not paint over it.
    private(set) var isPresenting = false

    private struct DrawnShape: Equatable {
        let columns: Int
        let rows: Int
        let headline: String
    }

    private let activationDelay: TimeInterval
    private let reduceMotionProvider: @MainActor () -> Bool
    private var input: AgenTTYReconnectScreenInput?
    private var drawnShape: DrawnShape?
    private var activationWorkItem: DispatchWorkItem?
    private var timer: Timer?
    private var tick = 0

    init(
        activationDelay: TimeInterval = 0.5,
        reduceMotionProvider: @escaping @MainActor () -> Bool = {
            TerminalReconnectScreenPresenter.systemReduceMotionEnabled
        }
    ) {
        self.activationDelay = activationDelay
        self.reduceMotionProvider = reduceMotionProvider
    }

    isolated deinit {
        cancelPendingActivation()
        stopTimer()
    }

    func update(_ next: AgenTTYReconnectScreenInput) {
        let previous = input
        input = next

        guard next.phase != nil, next.columns > 0, next.rows > 0 else {
            teardown()
            return
        }

        if isPresenting {
            redrawOrTick(previousPhase: previous?.phase)
            return
        }

        // A short grace period keeps fast reconnects from flashing the screen.
        guard activationWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activationWorkItem = nil
            guard self.input?.phase != nil else { return }
            self.present()
        }
        activationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: work)
    }

    /// Drops the screen without repainting, for teardown paths where the
    /// terminal is going away anyway.
    func invalidate() {
        cancelPendingActivation()
        stopTimer()
        isPresenting = false
        drawnShape = nil
        input = nil
    }

    private func present() {
        guard let input, let phase = input.phase else { return }
        isPresenting = true
        tick = 0
        drawFullScreen(phase: phase, input: input)
        startTimerIfNeeded()
    }

    private func teardown() {
        cancelPendingActivation()
        stopTimer()
        guard isPresenting else {
            drawnShape = nil
            return
        }
        isPresenting = false
        drawnShape = nil
        writeOutput?(AgenTTYReconnectScreenRenderer.dismissData(), "reconnect-screen-dismiss")
    }

    private func redrawOrTick(previousPhase: AgenTTYReconnectScreenPhase?) {
        guard let input, let phase = input.phase else { return }
        let headline = AgenTTYReconnectScreenRenderer.headline(
            phase: phase,
            hostLabel: input.hostLabel
        )
        let shape = DrawnShape(columns: input.columns, rows: input.rows, headline: headline)
        if drawnShape != shape {
            drawFullScreen(phase: phase, input: input)
        } else if previousPhase != phase {
            paintDetailRow(phase: phase, input: input)
        }
        startTimerIfNeeded()
    }

    private func drawFullScreen(phase: AgenTTYReconnectScreenPhase, input: AgenTTYReconnectScreenInput) {
        drawnShape = DrawnShape(
            columns: input.columns,
            rows: input.rows,
            headline: AgenTTYReconnectScreenRenderer.headline(phase: phase, hostLabel: input.hostLabel)
        )
        writeOutput?(
            AgenTTYReconnectScreenRenderer.fullScreenData(
                phase: phase,
                hostLabel: input.hostLabel,
                columns: input.columns,
                rows: input.rows,
                tick: tick,
                now: Date()
            ),
            "reconnect-screen"
        )
    }

    private func handleTick() {
        guard isPresenting, let input, let phase = input.phase else { return }
        tick &+= 1
        let layout = AgenTTYReconnectScreenRenderer.layout(rows: input.rows)
        var data = Data()
        if let spinnerRow = layout.row(of: .spinner) {
            data.append(
                AgenTTYReconnectScreenRenderer.rowData(
                    text: AgenTTYReconnectScreenRenderer.spinnerFrame(at: tick),
                    row: spinnerRow,
                    columns: input.columns
                )
            )
        }
        data.append(detailRowData(phase: phase, input: input, layout: layout))
        guard !data.isEmpty else { return }
        writeOutput?(data, "reconnect-screen-tick")
    }

    private func paintDetailRow(phase: AgenTTYReconnectScreenPhase, input: AgenTTYReconnectScreenInput) {
        let layout = AgenTTYReconnectScreenRenderer.layout(rows: input.rows)
        let data = detailRowData(phase: phase, input: input, layout: layout)
        guard !data.isEmpty else { return }
        writeOutput?(data, "reconnect-screen-detail")
    }

    private func detailRowData(
        phase: AgenTTYReconnectScreenPhase,
        input: AgenTTYReconnectScreenInput,
        layout: AgenTTYReconnectScreenRenderer.Layout
    ) -> Data {
        guard let detailRow = layout.row(of: .detail) else { return Data() }
        return AgenTTYReconnectScreenRenderer.rowData(
            text: AgenTTYReconnectScreenRenderer.detail(phase: phase, now: Date()),
            row: detailRow,
            columns: input.columns
        )
    }

    private func startTimerIfNeeded() {
        guard isPresenting, input?.isAnimating == true else {
            stopTimer()
            return
        }
        guard timer == nil else { return }
        let interval = AgenTTYReconnectScreenRenderer.tickInterval(
            reduceMotion: reduceMotionProvider()
        )
        // .common mode so the spinner keeps stepping while a touch gesture is
        // tracking the run loop.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cancelPendingActivation() {
        activationWorkItem?.cancel()
        activationWorkItem = nil
    }

    static var systemReduceMotionEnabled: Bool {
#if os(iOS)
        unsafe UIAccessibility.isReduceMotionEnabled
#else
        false
#endif
    }
}
