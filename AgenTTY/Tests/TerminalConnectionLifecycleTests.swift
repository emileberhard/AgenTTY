import XCTest
@testable import AgenTTY_iOS

final class TerminalConnectionLifecycleTests: XCTestCase {
    func testWillResignActiveBeginsWarmHoldWhenLiveTransportExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .willResignActive, state: state),
            .beginBackgroundWarmHold
        )
    }

    func testBackgroundBeginsWarmHoldWhenLiveTransportExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state),
            .beginBackgroundWarmHold
        )
    }

    func testBackgroundBeginsWarmHoldWhenReconnectWorkIsPending() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: true,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state),
            .beginBackgroundWarmHold
        )
    }

    func testBackgroundDoesNothingWhenNoConnectionWorkExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state),
            .none
        )
    }

    func testForegroundReconnectsActiveHostWhenNothingIsRunning() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state),
            .reconnectActiveHost
        )
    }

    func testForegroundVerifiesLivenessWhenTransportLooksAlive() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state),
            .verifyTransportLiveness
        )
    }

    func testForegroundDoesNotReconnectWithoutActiveHost() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: false,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state),
            .none
        )
    }

    func testForegroundDoesNotReconnectWhenRecoveryIsAlreadyRequired() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: true,
            isShuttingDown: false
        )

        XCTAssertEqual(
            AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state),
            .none
        )
    }
}
