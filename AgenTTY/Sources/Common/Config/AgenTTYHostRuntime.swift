import Foundation

nonisolated enum AgenTTYHostRuntime {
    static let rootRemotePath = "$HOME/.agentty"
    static let binRemotePath = "$HOME/.agentty/bin"
    static let libexecRemotePath = "$HOME/.agentty/libexec"
    static let configRemotePath = "$HOME/.agentty/config"
    static let stateRemotePath = "$HOME/.agentty/state"
    static let logsRemotePath = "$HOME/.agentty/logs"
    static let shareRemotePath = "$HOME/.agentty/share"
    static let terminfoRootRemotePath = "$HOME/.agentty/share/terminfo"
    static let shellConfigRemotePath = "$HOME/.agentty/config/shell"
    static var tmuxSessionName: String {
#if AGENTTY_BOOTSTRAP_SEED
        if AgenTTYSSHSeedPolicy.isScreenshotMode {
            return "agentty-screenshot"
        }
#endif
        return "agentty-main"
    }

    static let tmuxWrapperRemotePath = "$HOME/.agentty/bin/tmux"
    static let tmuxWrapperShellLiteral = "\"$HOME/.agentty/bin/tmux\""
    static let bootstrapScriptRemotePath = "$HOME/.agentty/bin/agentty-bootstrap"
    static let shellWrapperRemotePath = "$HOME/.agentty/bin/agentty-shell"
    static let logHelperRemotePath = "$HOME/.agentty/bin/agentty-log"
    static let manifestHelperRemotePath = "$HOME/.agentty/bin/agentty-manifest"
    static let notifyWrapperRemotePath = "$HOME/.agentty/bin/agentty-notify"
    static let claudeWrapperRemotePath = "$HOME/.agentty/bin/claude"
    static let codexWrapperRemotePath = "$HOME/.agentty/bin/codex"
    static let tmuxBinaryRemotePath = "$HOME/.agentty/libexec/tmux"
    static let notifyBinaryRemotePath = "$HOME/.agentty/libexec/agentty-notify"
    static let hostConnectorBinaryRemotePath = "$HOME/.agentty/libexec/agentty-host-connector"
    static let hostConnectorConfigRemotePath = "$HOME/.agentty/config/host-connector.json"

    static let tmuxSessionNameRemotePath = "$HOME/.agentty/config/tmux-session-name"
    static let notifyConfigRemotePath = "$HOME/.agentty/config/notify.json"
    static let claudeSettingsRemotePath = "$HOME/.agentty/config/claude-settings.json"
    static let shellRealpathRemotePath = "$HOME/.agentty/state/shell-realpath"
    static let claudeRealpathRemotePath = "$HOME/.agentty/state/claude-realpath"
    static let codexRealpathRemotePath = "$HOME/.agentty/state/codex-realpath"
    static let codexOriginalNotifyRemotePath = "$HOME/.agentty/state/codex-original-notify.json"
    static let hostPlatformRemotePath = "$HOME/.agentty/state/host-platform"
    static let runtimeAssetsVersionRemotePath = "$HOME/.agentty/state/runtime-assets-version"
    static let notificationAssetsVersionRemotePath = "$HOME/.agentty/state/notification-assets-version"
    static let binaryRuntimeVersionRemotePath = "$HOME/.agentty/state/host-runtime-version"
    static let runtimePayloadIntegrityRemotePath = "$HOME/.agentty/state/host-runtime.sha256"

    static let legacyRemotePaths = [
        "$HOME/.agentty/bin/agentty-install-notifications",
        "$HOME/.agentty/notify.env",
        "$HOME/.agentty/claude-settings.json",
        "$HOME/.agentty/tmux-session-name",
        "$HOME/.agentty/shell-realpath",
        "$HOME/.agentty/claude-realpath",
        "$HOME/.agentty/codex-realpath",
        "$HOME/.agentty/codex-original-notify.json",
    ]

    static let bootstrapLaunchCommand: String = {
        let bootstrapCommand = #"exec "$HOME/.agentty/bin/agentty-bootstrap""#
        return "exec /bin/sh -lc \(shellSingleQuoted(bootstrapCommand))"
    }()

    static func terminfoEntryRemotePath(relativePath: String) -> String {
        "\(terminfoRootRemotePath)/\(relativePath)"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
