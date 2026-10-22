import Foundation

nonisolated enum AgenTTYConnectionLifecycleEvent: Sendable {
    case willResignActive
    case didEnterBackground
    case didBecomeActive
}

nonisolated enum AgenTTYConnectionLifecycleAction: Sendable, Equatable {
    case none
    case beginBackgroundWarmHold
    case reconnectActiveHost
    /// Transport looks alive but may have died silently while the app was
    /// inactive (network switch during background). Probe it instead of
    /// trusting the socket.
    case verifyTransportLiveness
}

nonisolated struct AgenTTYConnectionLifecycleState: Sendable, Equatable {
    let hasActiveConnectionTarget: Bool
    let hasLiveTransport: Bool
    let hasPendingConnectionWork: Bool
    let hasRecoveryRequest: Bool
    let isShuttingDown: Bool
}

nonisolated enum AgenTTYConnectionLifecyclePolicy {
    static func action(
        for event: AgenTTYConnectionLifecycleEvent,
        state: AgenTTYConnectionLifecycleState
    ) -> AgenTTYConnectionLifecycleAction {
        guard !state.isShuttingDown else {
            return .none
        }

        switch event {
        case .willResignActive:
            if state.hasLiveTransport || state.hasPendingConnectionWork {
                return .beginBackgroundWarmHold
            }
            return .none

        case .didEnterBackground:
            if state.hasLiveTransport || state.hasPendingConnectionWork {
                return .beginBackgroundWarmHold
            }
            return .none

        case .didBecomeActive:
            guard state.hasActiveConnectionTarget else {
                return .none
            }
            guard !state.hasLiveTransport else {
                return .verifyTransportLiveness
            }
            guard !state.hasPendingConnectionWork else {
                return .none
            }
            guard !state.hasRecoveryRequest else {
                return .none
            }
            return .reconnectActiveHost
        }
    }
}
