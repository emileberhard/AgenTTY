import Foundation

nonisolated enum AgenTTYSSHDisconnectCategory: Equatable, Hashable, Sendable {
    case shellClosed
    case connectTimeout
    case networkError
    case authFailed
    case hostKeyMismatch
    case localClose
    case transportClosed
    case algorithmNegotiationFailed
    case other
}

nonisolated enum AgenTTYSSHFailureStage: Equatable, Hashable, Sendable {
    case tcpConnect
    case sshAuth
    case preShellRuntime
    case shellChannel
    case ptyBootstrap
    case tmuxBootstrap
    case transport
    case postReadySession
}

/// Which negotiation component had no overlap, with both sides' algorithm lists,
/// extracted from the fork's `NIOSSHError.negotiationFailure` diagnostics.
nonisolated struct AgenTTYSSHNegotiationFailureDetail: Equatable, Hashable, Sendable {
    enum Component: Equatable, Hashable, Sendable {
        case keyExchange
        case hostKey
        case encryption
        case mac
    }

    let component: Component
    let localAlgorithms: [String]
    let remoteAlgorithms: [String]
}

nonisolated struct AgenTTYSSHTerminationOutcome: Equatable, Hashable, Sendable {
    let category: AgenTTYSSHDisconnectCategory
    let failureStage: AgenTTYSSHFailureStage?
    let rawReason: String
    let wasReady: Bool
    let shouldReconnect: Bool
    var negotiationDetail: AgenTTYSSHNegotiationFailureDetail? = nil
}

nonisolated struct AgenTTYConnectionRecoveryRequest: Equatable, Hashable, Sendable {
    let hostID: UUID
    let outcome: AgenTTYSSHTerminationOutcome
}

nonisolated enum AgenTTYHostConnectionVerificationResult: Equatable, Sendable {
    case succeeded
    case failed(AgenTTYSSHTerminationOutcome)
}

nonisolated extension AgenTTYSSHDisconnectCategory {
    var analyticsValue: AgenTTYAnalyticsSSHDisconnectCategory {
        switch self {
        case .shellClosed:
            .shellClosed
        case .connectTimeout:
            .connectTimeout
        case .networkError:
            .networkError
        case .authFailed:
            .authFailed
        case .hostKeyMismatch:
            .hostKeyMismatch
        case .localClose:
            .localClose
        case .transportClosed:
            .transportClosed
        case .algorithmNegotiationFailed:
            // The relay's analytics enum is a strict snake_case Rust enum, so an
            // unknown value would be rejected with HTTP 400 and the event dropped
            // permanently. A real `algorithm_negotiation_failed` value has to ship
            // as a paired app release and backend deploy.
            .other
        case .other:
            .other
        }
    }
}

nonisolated extension AgenTTYSSHFailureStage {
    var analyticsValue: AgenTTYAnalyticsSSHFailureStage {
        switch self {
        case .tcpConnect:
            .tcpConnect
        case .sshAuth:
            .sshAuth
        case .preShellRuntime:
            .preShellRuntime
        case .shellChannel:
            .shellChannel
        case .ptyBootstrap:
            .ptyBootstrap
        case .tmuxBootstrap:
            .tmuxBootstrap
        case .transport:
            .transport
        case .postReadySession:
            .postReadySession
        }
    }
}
