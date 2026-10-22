import Foundation

nonisolated struct AgenTTYSSHRecoverySuggestion: Equatable, Hashable, Sendable {
    let icon: String
    let title: String
    let subtitle: String
}

nonisolated struct AgenTTYSSHRecoveryDescription: Equatable, Sendable {
    let title: String
    let message: String
    let suggestions: [AgenTTYSSHRecoverySuggestion]
}

nonisolated enum AgenTTYSSHRecoveryGuidance {
    static func guidance(for outcome: AgenTTYSSHTerminationOutcome) -> AgenTTYSSHRecoveryDescription {
        // The outer switch is on `failureStage`, so this category has to be handled
        // before it or the generic transport copy would swallow it.
        if outcome.category == .algorithmNegotiationFailed {
            return negotiationFailureGuidance(detail: outcome.negotiationDetail)
        }

        switch outcome.failureStage {
        case .tcpConnect:
            return AgenTTYSSHRecoveryDescription(
                title: "Couldn’t Reach the Host",
                message: "AgenTTY could not open a network connection to the host. Check the hostname, port, and that the iPhone can reach the host over the current network path.",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "wifi",
                        title: "Check the network path",
                        subtitle: "Use the same LAN, a public address, or Tailscale on both devices."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Verify SSH is listening",
                        subtitle: "Confirm that SSH is running on the selected port for this host."
                    ),
                ]
            )
        case .sshAuth:
            return AgenTTYSSHRecoveryDescription(
                title: "SSH Authentication Failed",
                message: "The host rejected the selected authentication method before the session could start.",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "key",
                        title: "Check the trusted key",
                        subtitle: "Make sure the selected public key is installed in ~/.ssh/authorized_keys."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "person.badge.key",
                        title: "Verify the username",
                        subtitle: "Public-key authentication must be allowed for the selected user account."
                    ),
                ]
            )
        case .preShellRuntime:
            return AgenTTYSSHRecoveryDescription(
                title: "Connected, But Host Preparation Failed",
                message: "AgenTTY reached the host, but could not prepare its managed runtime before the terminal session started.",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "externaldrive",
                        title: "Check write access",
                        subtitle: "The remote account needs to create files under ~/.agentty."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "terminal",
                        title: "Check the login shell",
                        subtitle: "The shell environment must allow standard command execution during setup."
                    ),
                ]
            )
        case .shellChannel, .ptyBootstrap, .tmuxBootstrap:
            return AgenTTYSSHRecoveryDescription(
                title: "Connected, But the Terminal Session Didn’t Start",
                message: "AgenTTY reached the host and authenticated, but the interactive terminal session did not become ready.",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "rectangle.and.text.magnifyingglass",
                        title: "Review the host shell",
                        subtitle: "The login shell must accept a PTY request and start the tmux bootstrap command."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "rectangle.3.offgrid",
                        title: "Check tmux startup",
                        subtitle: "AgenTTY’s tmux bootstrap must be able to launch without interactive prompts."
                    ),
                ]
            )
        case .transport:
            return AgenTTYSSHRecoveryDescription(
                title: "SSH Closed Before the Session Was Ready",
                message: "The SSH transport closed before AgenTTY reached a ready terminal session.",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Try again once",
                        subtitle: "This can be transient, but repeated failures usually mean the host configuration needs attention."
                    ),
                ]
            )
        case .postReadySession, nil:
            switch outcome.category {
            case .hostKeyMismatch:
                return AgenTTYSSHRecoveryDescription(
                    title: "The Host Identity Changed",
                    message: "AgenTTY found a different SSH host key than it trusted before.",
                    suggestions: [
                        AgenTTYSSHRecoverySuggestion(
                            icon: "key.2.on.ring",
                            title: "Reset the trusted host key",
                            subtitle: "Only do this if you trust the host and intentionally changed or rebuilt it."
                        ),
                    ]
                )
            case .authFailed:
                return guidance(
                    for: AgenTTYSSHTerminationOutcome(
                        category: outcome.category,
                        failureStage: .sshAuth,
                        rawReason: outcome.rawReason,
                        wasReady: outcome.wasReady,
                        shouldReconnect: outcome.shouldReconnect
                    )
                )
            default:
                return AgenTTYSSHRecoveryDescription(
                    title: "The Connection Needs Attention",
                    message: "AgenTTY could not finish opening a usable terminal session for this host.",
                    suggestions: [
                        AgenTTYSSHRecoverySuggestion(
                            icon: "slider.horizontal.3",
                            title: "Review the host details",
                            subtitle: "Check the hostname, username, authentication method, and any recent host changes."
                        ),
                    ]
                )
            }
        }
    }

    /// Component-specific cards for algorithm-negotiation failures. The fork's
    /// diagnostics say which component had no overlap and what each side offered;
    /// without them (a relay-wrapped or legacy error), the generic cipher card is
    /// still the most likely explanation.
    static func negotiationFailureGuidance(
        detail: AgenTTYSSHNegotiationFailureDetail?
    ) -> AgenTTYSSHRecoveryDescription {
        let offeredSuffix: String
        if let detail, !detail.remoteAlgorithms.isEmpty {
            offeredSuffix = " This host offers: \(detail.remoteAlgorithms.joined(separator: ", "))."
        } else {
            offeredSuffix = ""
        }

        let updateServerSuggestion = AgenTTYSSHRecoverySuggestion(
            icon: "arrow.up.circle",
            title: "Update the SSH server",
            subtitle: "Very old servers may only offer algorithms that are no longer considered safe."
        )

        switch detail?.component {
        case .hostKey:
            return AgenTTYSSHRecoveryDescription(
                title: "No Shared Host Key Type",
                message: "AgenTTY and this host could not agree on a host key type. AgenTTY accepts ssh-ed25519, ecdsa-sha2-nistp256/384/521, rsa-sha2-512, rsa-sha2-256, and ssh-rsa.\(offeredSuffix)",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "key",
                        title: "Enable a supported host key",
                        subtitle: "Generate an ed25519, ECDSA, or RSA host key on the server and reference it from its SSH configuration."
                    ),
                    updateServerSuggestion,
                ]
            )
        case .keyExchange:
            return AgenTTYSSHRecoveryDescription(
                title: "No Shared Key Exchange Method",
                message: "AgenTTY and this host could not agree on a key exchange method. AgenTTY supports curve25519-sha256 and ecdh-sha2-nistp256/384/521.\(offeredSuffix)",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Allow a supported key exchange",
                        subtitle: "Enable curve25519-sha256 or an ecdh-sha2 method in the host’s SSH configuration."
                    ),
                    updateServerSuggestion,
                ]
            )
        case .mac:
            return AgenTTYSSHRecoveryDescription(
                title: "No Shared Message Authentication",
                message: "AgenTTY and this host could not agree on a message authentication code. AgenTTY supports hmac-sha2-256 alongside AEAD ciphers that need no separate MAC.\(offeredSuffix)",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "checkmark.seal",
                        title: "Allow a supported MAC",
                        subtitle: "Enable hmac-sha2-256, or an AEAD cipher such as aes256-gcm@openssh.com or chacha20-poly1305@openssh.com."
                    ),
                    updateServerSuggestion,
                ]
            )
        case .encryption, nil:
            return AgenTTYSSHRecoveryDescription(
                title: "No Shared Encryption Method",
                message: "AgenTTY and this host could not agree on an SSH cipher. AgenTTY supports aes256-gcm@openssh.com, aes128-gcm@openssh.com, chacha20-poly1305@openssh.com, aes256-ctr, and aes128-ctr.\(offeredSuffix)",
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "lock.trianglebadge.exclamationmark",
                        title: "Allow a supported cipher",
                        subtitle: "Enable one of AgenTTY’s ciphers in the host’s SSH configuration; chacha20-poly1305 and the aes-ctr pair cover most older servers."
                    ),
                    updateServerSuggestion,
                ]
            )
        }
    }
}
