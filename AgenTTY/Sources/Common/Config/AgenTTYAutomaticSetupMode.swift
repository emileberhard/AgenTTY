import Foundation

nonisolated enum AgenTTYAutomaticSetupMode: String, CaseIterable, Equatable, Sendable {
    case recommended
    case directOnly

    var title: String {
        switch self {
        case .recommended:
            return "Full AgenTTY Setup"
        case .directOnly:
            return "Direct Connection Only"
        }
    }

    var badge: String? {
        switch self {
        case .recommended:
            return "Recommended"
        case .directOnly:
            return nil
        }
    }

    var command: String {
        switch self {
        case .recommended:
            return "npx -y @agentty-app/pair"
        case .directOnly:
            return "npx -y @agentty-app/pair --direct-only"
        }
    }

    var summary: String {
        switch self {
        case .recommended:
            return "Best AgenTTY experience. Keeps sessions reliable from iPhone networks with fallback access when direct SSH is unavailable."
        case .directOnly:
            return "Uses direct SSH only. Skips the persistent relay connector and relay fallback."
        }
    }
}
