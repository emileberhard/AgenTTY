import Foundation

nonisolated enum AgenTTYSSHDisconnectCategory: Equatable, Hashable, Sendable {
    case shellClosed
    case connectTimeout
    case networkError
    case dnsFailure
    case keyUnavailable
    case passwordUnavailable
    case relayRejected
    case relayLimit(detail: String)
    case relayConnectorOffline
    case relayUnavailable
    case keyInstallFailed(hostMessage: String?)
    case hostSetupTimeout
    case unsupportedHostPlatform(operatingSystem: String, architecture: String)
    case authFailed
    case hostKeyMismatch
    case localClose
    case transportClosed
    case algorithmNegotiationFailed
    case other

    var isNetworkClass: Bool {
        switch self {
        case .connectTimeout, .networkError, .dnsFailure, .relayConnectorOffline, .relayUnavailable, .transportClosed:
            true
        case .shellClosed, .authFailed, .hostKeyMismatch, .localClose, .algorithmNegotiationFailed,
             .keyUnavailable, .passwordUnavailable, .relayRejected, .relayLimit, .keyInstallFailed,
             .hostSetupTimeout, .unsupportedHostPlatform, .other:
            false
        }
    }
}

nonisolated enum AgenTTYSSHFailureStage: Equatable, Hashable, Sendable {
    case preflight
    case tcpConnect
    case sshAuth
    case hostToolsDownload
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
        case .dnsFailure, .relayConnectorOffline, .relayUnavailable:
            .networkError
        case .keyUnavailable, .passwordUnavailable, .relayRejected, .relayLimit,
             .keyInstallFailed, .hostSetupTimeout, .unsupportedHostPlatform, .other:
            .other
        }
    }
}

nonisolated extension AgenTTYSSHFailureStage {
    var analyticsValue: AgenTTYAnalyticsSSHFailureStage {
        switch self {
        case .preflight, .tcpConnect:
            .tcpConnect
        case .sshAuth:
            .sshAuth
        case .hostToolsDownload, .preShellRuntime:
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
