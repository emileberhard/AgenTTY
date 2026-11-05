import Foundation
import Testing
@testable import AgenTTY_iOS

private typealias Renderer = AgenTTYReconnectScreenRenderer

struct ReconnectScreenTests {
    private let notice = AgenTTYSSHRetryNotice(
        headline: "Can’t reach mini.local",
        hint: "Make sure this device is on the host’s network."
    )

    @Test
    func onlyConnectedPhaseAllowsHostInteraction() {
        #expect(AgenTTYHostConnectionPhase.connected.allowsHostInteraction)
        #expect(!AgenTTYHostConnectionPhase.connecting.allowsHostInteraction)
        #expect(!AgenTTYHostConnectionPhase.disconnected.allowsHostInteraction)
    }

    @Test
    func spinnerWrapsAcrossFramesInBothDirections() {
        let frameCount = Renderer.spinnerFrames.count
        #expect(Renderer.spinnerFrame(at: 0) == Renderer.spinnerFrames[0])
        #expect(Renderer.spinnerFrame(at: frameCount + 3) == Renderer.spinnerFrames[3])
        #expect(Renderer.spinnerFrame(at: -1) == Renderer.spinnerFrames[frameCount - 1])
        #expect(Renderer.spinnerFrames.allSatisfy { $0.count == 1 })
    }

    @Test
    func reduceMotionSlowsTheTickCadence() {
        #expect(Renderer.tickInterval(reduceMotion: false) == Renderer.animatedTickInterval)
        #expect(Renderer.tickInterval(reduceMotion: true) == Renderer.reducedMotionTickInterval)
        #expect(Renderer.reducedMotionTickInterval > Renderer.animatedTickInterval)
    }

    @Test
    func firstAttemptSaysConnectingAndRetriesSayReconnecting() {
        #expect(Renderer.headline(phase: .connecting(attempt: 0), hostLabel: "mac-mini") == "Connecting to mac-mini")
        #expect(Renderer.headline(phase: .connecting(attempt: 2), hostLabel: "mac-mini") == "Reconnecting to mac-mini")
        #expect(
            Renderer.headline(phase: .waitingToRetry(attempt: 2, retryAt: Date()), hostLabel: "mac-mini")
                == "Reconnecting to mac-mini"
        )
        #expect(Renderer.headline(phase: .connecting(attempt: 0), hostLabel: "   ") == "Connecting to host")
    }

    @Test
    func detailCombinesTheAttemptWithTheConnectionStage() {
        let now = Date()
        #expect(Renderer.detail(phase: .connecting(attempt: 0), now: now, progress: nil) == "")
        #expect(Renderer.detail(phase: .connecting(attempt: 3), now: now, progress: nil) == "attempt 3")
        #expect(Renderer.detail(phase: .connecting(attempt: 0), now: now, progress: .signingIn) == "signing in…")
        #expect(
            Renderer.detail(phase: .connecting(attempt: 2), now: now, progress: .preparingHost)
                == "attempt 2 · preparing host…"
        )
        #expect(
            Renderer.detail(phase: .connecting(attempt: 0), now: now, progress: .startingTerminal)
                == "starting terminal…"
        )
    }

    @Test
    func retryCountdownRoundsUpAndNeverDropsBelowOneSecond() {
        let now = Date()
        let soon = AgenTTYReconnectScreenPhase.waitingToRetry(attempt: 4, retryAt: now.addingTimeInterval(3.2))
        let overdue = AgenTTYReconnectScreenPhase.waitingToRetry(attempt: 1, retryAt: now.addingTimeInterval(-5))

        #expect(Renderer.detail(phase: soon, now: now, progress: nil) == "attempt 4 · retrying in 4s")
        #expect(Renderer.detail(phase: overdue, now: now, progress: nil) == "attempt 1 · retrying in 1s")
    }

    @Test
    func tallTerminalShowsTheWholeNoticeBelowTheDetail() {
        let layout = Renderer.layout(rows: 40, columns: 80, notice: notice)

        #expect(layout.slots == [
            .spinner, .blank, .headline, .blank, .detail, .blank,
            .noticeHeadline("Can’t reach mini.local"),
            .noticeHint("Make sure this device is on the host’s network."),
        ])
        #expect(layout.topPadding == (40 - 8) / 2)
        #expect(layout.row(of: .detail) == layout.topPadding + 5)
    }

    @Test
    func narrowTerminalWrapsTheNoticeAtWordBoundaries() {
        let layout = Renderer.layout(rows: 40, columns: 26, notice: notice)

        #expect(layout.slots == [
            .spinner, .blank, .headline, .blank, .detail, .blank,
            .noticeHeadline("Can’t reach mini.local"),
            .noticeHint("Make sure this device is"),
            .noticeHint("on the host’s network."),
        ])
    }

    @Test
    func wordsLongerThanTheLineAreSplit() {
        #expect(Renderer.wrapped("unreachable-host.example.com", columns: 12) == ["unreachabl", "e-host.exa", "mple.com"])
        #expect(
            Renderer.wrapped("Can’t reach averyveryverylonghostname", columns: 12)
                == ["Can’t", "reach", "averyveryv", "erylonghos", "tname"]
        )
    }

    @Test
    func shortTerminalsKeepTheNoticeHeadlineBeforeDroppingIt() {
        #expect(Renderer.layout(rows: 8, columns: 80, notice: notice).slots == [
            .spinner, .blank, .headline, .detail, .blank, .noticeHeadline("Can’t reach mini.local"),
        ])
        #expect(Renderer.layout(rows: 6, columns: 80, notice: notice).slots == [
            .spinner, .headline, .detail, .noticeHeadline("Can’t reach mini.local"),
        ])
        #expect(Renderer.layout(rows: 4, columns: 80, notice: notice).slots == [.spinner, .headline, .detail])
        #expect(Renderer.layout(rows: 40, columns: 80, notice: nil).slots == [
            .spinner, .blank, .headline, .blank, .detail,
        ])
    }

    @Test
    func everyLayoutFitsInsideTheTerminal() {
        for rows in 3...60 {
            for columns in [12, 40, 120] {
                let layout = Renderer.layout(rows: rows, columns: columns, notice: notice)
                #expect(layout.topPadding + layout.slots.count <= rows, "rows=\(rows) columns=\(columns)")
            }
        }
    }

    @Test
    func centeringPadsAndTruncates() {
        #expect(Renderer.centered("abc", columns: 9) == "   abc")
        #expect(Renderer.centered("abcdef", columns: 4) == "abcd")
        #expect(Renderer.centered("", columns: 10) == "")
    }

    @Test
    func fullScreenDrawPaintsTheNoticeWithADimHint() {
        let text = renderedText(
            Renderer.fullScreenData(
                phase: .connecting(attempt: 2),
                hostLabel: "mac-mini",
                columns: 60,
                rows: 24,
                tick: 0,
                now: Date(),
                notice: notice,
                progress: .signingIn
            )
        )

        #expect(text.hasPrefix("\u{1B}[?25l\u{1B}[0m\u{1B}[2J\u{1B}[H"))
        #expect(text.contains("Reconnecting to mac-mini"))
        #expect(text.contains("attempt 2 · signing in…"))
        #expect(text.contains("Can’t reach mini.local"))
        #expect(text.contains("\u{1B}[2m"))
        #expect(text.contains("Make sure this device is on the host’s network.\u{1B}[22m"))
        #expect(!text.hasSuffix("\r\n"))
    }

    @Test
    func rowRepaintAddressesAndClearsExactlyOneRow() {
        #expect(renderedText(Renderer.rowData(text: "attempt 3", row: 12, columns: 21)) == "\u{1B}[12;1H\u{1B}[2K      attempt 3")
    }

    @Test
    func dismissRestoresTheCursor() {
        #expect(renderedText(Renderer.dismissData()) == "\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[?25h")
    }
}

@MainActor
struct ReconnectScreenPresenterTests {
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
        notice: AgenTTYSSHRetryNotice? = nil,
        progress: SSHClientSession.Progress? = nil
    ) -> AgenTTYReconnectScreenInput {
        AgenTTYReconnectScreenInput(
            phase: phase,
            hostLabel: "mac-mini",
            columns: 60,
            rows: 24,
            isAnimating: true,
            notice: notice,
            progress: progress
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test
    func nothingIsDrawnWhileNoReconnectIsInFlight() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: nil))
        await drainMainQueue()

        #expect(!presenter.isPresenting)
        #expect(recorder.text.isEmpty)
    }

    @Test
    func connectingDrawsTheScreenAfterTheGracePeriod() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 2)))
        #expect(!presenter.isPresenting)
        await drainMainQueue()

        #expect(presenter.isPresenting)
        #expect(recorder.text.contains("Reconnecting to mac-mini"))
        #expect(recorder.sources == ["reconnect-screen"])
    }

    @Test
    func aFastReconnectNeverFlashesTheScreen() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        presenter.update(makeInput(phase: nil))
        await drainMainQueue()

        #expect(!presenter.isPresenting)
        #expect(recorder.text.isEmpty)
    }

    @Test
    func reconnectingRestoresTheTerminalOnSuccess() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        await drainMainQueue()
        presenter.update(makeInput(phase: nil))

        #expect(!presenter.isPresenting)
        #expect(recorder.sources.last == "reconnect-screen-dismiss")
        #expect(recorder.text.hasSuffix("\u{1B}[?25h"))
    }

    @Test
    func resizeAndNoticeChangesRedrawTheWholeBlock() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        await drainMainQueue()
        var resized = makeInput(phase: .connecting(attempt: 1))
        resized.columns = 100
        presenter.update(resized)
        let notice = AgenTTYSSHRetryNotice(headline: "No network connection", hint: "Waiting for Wi-Fi or cellular.")
        var withNotice = makeInput(phase: .connecting(attempt: 1), notice: notice)
        withNotice.columns = 100
        presenter.update(withNotice)

        #expect(recorder.sources == ["reconnect-screen", "reconnect-screen", "reconnect-screen"])
        #expect(recorder.text.contains("No network connection"))
    }

    @Test
    func countdownAndProgressRepaintOnlyTheDetailRow() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        await drainMainQueue()
        presenter.update(makeInput(phase: .connecting(attempt: 1), progress: .preparingHost))
        presenter.update(makeInput(phase: .waitingToRetry(attempt: 2, retryAt: Date().addingTimeInterval(4))))

        #expect(recorder.sources == ["reconnect-screen", "reconnect-screen-detail", "reconnect-screen-detail"])
        #expect(recorder.text.contains("attempt 1 · preparing host…"))
        #expect(recorder.text.contains("attempt 2 · retrying in 4s"))
    }

    @Test
    func invalidateDropsTheScreenWithoutWriting() async {
        let (presenter, recorder) = makePresenter()

        presenter.update(makeInput(phase: .connecting(attempt: 1)))
        await drainMainQueue()
        let writesBeforeInvalidate = recorder.sources.count
        presenter.invalidate()

        #expect(!presenter.isPresenting)
        #expect(recorder.sources.count == writesBeforeInvalidate)
    }
}

private func renderedText(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}
