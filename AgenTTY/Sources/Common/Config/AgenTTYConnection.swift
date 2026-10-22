import Foundation

nonisolated enum AgenTTYConnection {
    static let defaultPort = 22
    static let tmuxSessionName = AgenTTYHostRuntime.tmuxSessionName
    static let tmuxBootstrapCommand = AgenTTYHostRuntime.bootstrapLaunchCommand
}
