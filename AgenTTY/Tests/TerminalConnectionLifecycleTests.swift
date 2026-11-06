import Foundation
import Testing
@testable import AgenTTY_iOS

@Suite
struct TerminalConnectionLifecycleTests {
    @Test
    func willResignActiveBeginsWarmHoldWhenLiveTransportExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .willResignActive, state: state) == .beginBackgroundWarmHold)
    }

    @Test
    func backgroundBeginsWarmHoldWhenLiveTransportExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state) == .beginBackgroundWarmHold)
    }

    @Test
    func backgroundBeginsWarmHoldWhenReconnectWorkIsPending() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: true,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state) == .beginBackgroundWarmHold)
    }

    @Test
    func backgroundDoesNothingWhenNoConnectionWorkExists() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didEnterBackground, state: state) == .none)
    }

    @Test
    func foregroundReconnectsActiveHostWhenNothingIsRunning() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state) == .reconnectActiveHost)
    }

    @Test
    func foregroundVerifiesLivenessWhenTransportLooksAlive() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: true,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state) == .verifyTransportLiveness)
    }

    @Test
    func foregroundDoesNotReconnectWithoutActiveHost() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: false,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: false,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state) == .none)
    }

    @Test
    func foregroundDoesNotReconnectWhenRecoveryIsAlreadyRequired() {
        let state = AgenTTYConnectionLifecycleState(
            hasActiveConnectionTarget: true,
            hasLiveTransport: false,
            hasPendingConnectionWork: false,
            hasRecoveryRequest: true,
            isShuttingDown: false
        )

        #expect(AgenTTYConnectionLifecyclePolicy.action(for: .didBecomeActive, state: state) == .none)
    }
}
