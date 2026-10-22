import XCTest
@testable import AgenTTY_iOS

private typealias Renderer = AgenTTYReconnectScreenRenderer

final class ReconnectScreenTests: XCTestCase {
    // MARK: - Host interaction gating

    func testOnlyConnectedPhaseAllowsHostInteraction() {
        XCTAssertTrue(AgenTTYHostConnectionPhase.connected.allowsHostInteraction)
        XCTAssertFalse(AgenTTYHostConnectionPhase.connecting.allowsHostInteraction)
        XCTAssertFalse(AgenTTYHostConnectionPhase.disconnected.allowsHostInteraction)
    }

    // MARK: - Spinner

    func testSpinnerWrapsAcrossFrames() {
        let frameCount = Renderer.spinnerFrames.count
        XCTAssertEqual(Renderer.spinnerFrame(at: 0), Renderer.spinnerFrames[0])
        XCTAssertEqual(Renderer.spinnerFrame(at: frameCount), Renderer.spinnerFrames[0])
        XCTAssertEqual(Renderer.spinnerFrame(at: frameCount + 3), Renderer.spinnerFrames[3])
    }

    func testSpinnerHandlesNegativeTicks() {
        XCTAssertEqual(
            Renderer.spinnerFrame(at: -1),
            Renderer.spinnerFrames[Renderer.spinnerFrames.count - 1]
        )
    }

    func testEverySpinnerFrameIsOneCharacterWide() {
        for frame in Renderer.spinnerFrames {
            XCTAssertEqual(frame.count, 1, "spinner frame \(frame) must occupy one cell")
        }
    }

    func testReduceMotionSlowsTheTickCadence() {
        XCTAssertEqual(Renderer.tickInterval(reduceMotion: false), Renderer.animatedTickInterval)
        XCTAssertEqual(Renderer.tickInterval(reduceMotion: true), Renderer.reducedMotionTickInterval)
        XCTAssertGreaterThan(
            Renderer.tickInterval(reduceMotion: true),
            Renderer.tickInterval(reduceMotion: false)
        )
    }

    // MARK: - Headline

    func testFirstAttemptSaysConnectingAndRetriesSayReconnecting() {
        XCTAssertEqual(
            Renderer.headline(phase: .connecting(attempt: 0), hostLabel: "mac-mini"),
            "Connecting to mac-mini"
        )
        XCTAssertEqual(
            Renderer.headline(phase: .connecting(attempt: 2), hostLabel: "mac-mini"),
            "Reconnecting to mac-mini"
        )
        XCTAssertEqual(
            Renderer.headline(
                phase: .waitingToRetry(attempt: 2, retryAt: Date()),
                hostLabel: "mac-mini"
            ),
            "Reconnecting to mac-mini"
        )
    }

    func testHeadlineFallsBackWhenHostLabelIsBlank() {
        XCTAssertEqual(
            Renderer.headline(phase: .connecting(attempt: 0), hostLabel: "   "),
            "Connecting to host"
        )
    }

    // MARK: - Detail

    func testDetailIsEmptyForTheFirstConnectAndCountsRetries() {
        let now = Date()
        XCTAssertEqual(Renderer.detail(phase: .connecting(attempt: 0), now: now), "")
        XCTAssertEqual(Renderer.detail(phase: .connecting(attempt: 3), now: now), "attempt 3")
    }

    func testDetailRoundsTheRetryCountdownUp() {
        let now = Date()
        let phase = AgenTTYReconnectScreenPhase.waitingToRetry(
            attempt: 4,
            retryAt: now.addingTimeInterval(3.2)
        )

        XCTAssertEqual(Renderer.detail(phase: phase, now: now), "attempt 4 · retrying in 4s")
    }

    func testDetailNeverCountsBelowOneSecond() {
        let now = Date()
        let phase = AgenTTYReconnectScreenPhase.waitingToRetry(
            attempt: 1,
            retryAt: now.addingTimeInterval(-5)
        )

        XCTAssertEqual(Renderer.detail(phase: phase, now: now), "attempt 1 · retrying in 1s")
    }

    // MARK: - Layout

    func testTallTerminalUsesTheFullLayout() {
        let layout = Renderer.layout(rows: 40)

        XCTAssertEqual(
            layout.slots,
            [.spinner, .blank, .headline, .blank, .detail, .blank, .footer]
        )
        XCTAssertEqual(layout.topPadding, (40 - 7) / 2)
        XCTAssertEqual(layout.row(of: .spinner), layout.topPadding + 1)
        XCTAssertEqual(layout.row(of: .headline), layout.topPadding + 3)
        XCTAssertEqual(layout.row(of: .detail), layout.topPadding + 5)
        XCTAssertEqual(layout.row(of: .footer), layout.topPadding + 7)
    }

    func testShortTerminalDropsTheFooterAndThenTheSeparators() {
        let compact = Renderer.layout(rows: 7)
        XCTAssertEqual(compact.slots, [.spinner, .blank, .headline, .detail])
        XCTAssertNil(compact.row(of: .footer))

        let minimal = Renderer.layout(rows: 4)
        XCTAssertEqual(minimal.slots, [.spinner, .headline, .detail])
        XCTAssertEqual(minimal.row(of: .spinner), 1)
    }

    func testEveryUsableLayoutFitsInsideTheTerminal() {
        for rows in 3...60 {
            let layout = Renderer.layout(rows: rows)
            let lastRow = layout.topPadding + layout.slots.count
            XCTAssertLessThanOrEqual(lastRow, rows, "layout for \(rows) rows overflowed")
        }
    }

    // MARK: - Centering

    func testCenteringPadsAndTruncates() {
        XCTAssertEqual(Renderer.centered("abc", columns: 9), "   abc")
        XCTAssertEqual(Renderer.centered("abcdef", columns: 4), "abcd")
        XCTAssertEqual(Renderer.centered("", columns: 10), "")
    }

    // MARK: - Escape sequences

    func testFullScreenDrawClearsHidesTheCursorAndPaintsTheHeadline() {
        let text = renderedText(
            Renderer.fullScreenData(
                phase: .connecting(attempt: 2),
                hostLabel: "mac-mini",
                columns: 60,
                rows: 24,
                tick: 0,
                now: Date()
            )
        )

        XCTAssertTrue(text.hasPrefix("\u{1B}[?25l\u{1B}[0m\u{1B}[2J\u{1B}[H"))
        XCTAssertTrue(text.contains("Reconnecting to mac-mini"))
        XCTAssertTrue(text.contains("attempt 2"))
        XCTAssertTrue(text.contains(Renderer.footerText))
        XCTAssertTrue(text.contains(Renderer.spinnerFrames[0]))
        XCTAssertFalse(text.hasSuffix("\r\n"), "a trailing newline would scroll the block")
    }

    func testFullScreenDrawOmitsTheFooterOnShortTerminals() {
        let text = renderedText(
            Renderer.fullScreenData(
                phase: .connecting(attempt: 0),
                hostLabel: "mac-mini",
                columns: 60,
                rows: 6,
                tick: 0,
                now: Date()
            )
        )

        XCTAssertFalse(text.contains(Renderer.footerText))
        XCTAssertTrue(text.contains("Connecting to mac-mini"))
    }

    func testRowRepaintAddressesAndClearsExactlyOneRow() {
        let text = renderedText(Renderer.rowData(text: "attempt 3", row: 12, columns: 21))

        XCTAssertEqual(text, "\u{1B}[12;1H\u{1B}[2K      attempt 3")
    }

    func testDismissRestoresTheCursor() {
        let text = renderedText(Renderer.dismissData())

        XCTAssertEqual(text, "\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[?25h")
    }

    // MARK: - Helpers

    private func renderedText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class ReconnectScreenPresenterTests: XCTestCase {
    /// Collects everything the presenter would have written to the terminal.
    private final class WriteRecorder {
        private(set) var sources: [String] = []
        private(set) var text = ""

        func record(_ data: Data, source: String) {
            sources.append(source)
            text += String(decoding: data, as: UTF8.self)
        }
    }

    private func makePresenter() -> (TerminalReconnectScreenPresenter, WriteRecorder) {
        let recorder = WriteRecorder()
        let presenter = TerminalReconnectScreenPresenter(
            activationDelay: 0,
            reduceMotionProvider: { true }
        )
        presenter.writeOutput = { data, source in recorder.record(data, source: source) }
        return (presenter, recorder)
    }

    private func makeInput(
        phase: AgenTTYReconnectScreenPhase?,
        isAnimating: Bool = true
    ) -> AgenTTYReconnectScreenInput {
        AgenTTYReconnectScreenInput(
            phase: phase,
            hostLabel: "mac-mini",
            columns: 60,
            rows: 24,
            isAnimating: isAnimating
        )
    }

    /// The presenter activates on a later main-queue turn, so tests have to let
    /// the run loop drain before asserting.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testNothingIsDrawnWhileNoReconnectIsInFlight() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: nil))
        drainMainQueue()

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertTrue(recorder.text.isEmpty)
    }

    func testConnectingDrawsTheScreenAndTakesOverStatusLines() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 2)))
        XCTAssertFalse(presenter.isPresenting, "the screen waits out its activation grace period")
        drainMainQueue()

        XCTAssertTrue(presenter.isPresenting)
        XCTAssertTrue(recorder.text.contains("Reconnecting to mac-mini"))
        XCTAssertEqual(recorder.sources, ["reconnect-screen"])
    }

    func testAFastReconnectNeverFlashesTheScreen() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        presenter.update(makeInput(phase: nil))
        drainMainQueue()

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertTrue(recorder.text.isEmpty, "no draw means no clear is needed either")
    }

    func testReconnectingRestoresTheTerminalOnSuccess() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        drainMainQueue()
        presenter.update(makeInput(phase: nil))

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertEqual(recorder.sources.last, "reconnect-screen-dismiss")
        XCTAssertTrue(recorder.text.hasSuffix("\u{1B}[?25h"), "the cursor must come back")
    }

    func testTerminalResizeRedrawsTheCenteredBlock() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        drainMainQueue()
        var resized = makeInput(phase: .connecting(attempt: 1))
        resized.columns = 100
        presenter.update(resized)

        XCTAssertEqual(recorder.sources, ["reconnect-screen", "reconnect-screen"])
    }

    func testCountdownUpdatesRepaintOnlyTheDetailRow() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        drainMainQueue()
        presenter.update(
            makeInput(phase: .waitingToRetry(attempt: 2, retryAt: Date().addingTimeInterval(4)))
        )

        // Headline is identical for both phases, so no full redraw is needed.
        XCTAssertEqual(recorder.sources, ["reconnect-screen", "reconnect-screen-detail"])
        XCTAssertTrue(recorder.text.contains("attempt 2 · retrying in 4s"))
    }

    func testInvalidateDropsTheScreenWithoutWriting() {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        drainMainQueue()
        let writesBeforeInvalidate = recorder.sources.count
        presenter.invalidate()

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertEqual(recorder.sources.count, writesBeforeInvalidate)
    }
}
