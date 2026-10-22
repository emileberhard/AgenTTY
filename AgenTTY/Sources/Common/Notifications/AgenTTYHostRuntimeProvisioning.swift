import CryptoKit
import Foundation

struct AgenTTYNotificationProvisionResult: Sendable {
    let claudeInstalled: Bool
    let codexInstalled: Bool
}

enum AgenTTYHostRuntimeProvisionError: LocalizedError {
    case missingAsset(String)
    case remoteWriteFailed(String)
    case remoteCommandFailed(String)
    case hostPlatformDetectionFailed(String)
    case unsupportedHostPlatform(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            "Missing bundled host runtime asset: \(name)."
        case .remoteWriteFailed(let path):
            "Failed to upload remote host runtime asset: \(path)."
        case .remoteCommandFailed(let output):
            "Remote host runtime command failed: \(output)"
        case .hostPlatformDetectionFailed(let output):
            "Failed to detect remote host platform: \(output)"
        case .unsupportedHostPlatform(let description):
            "Unsupported remote host platform: \(description)"
        }
    }
}

enum AgenTTYRemoteHostPlatform: String, Sendable {
    case darwinArm64 = "darwin-arm64"
    case darwinX86_64 = "darwin-x86_64"
    case linuxArm64 = "linux-arm64"
    case linuxX86_64 = "linux-x86_64"

    static func detect(ssh: SSHClientSession) async throws -> Self {
        let (success, output) = await ssh.runCommandCapturingOutput("uname -s && uname -m")
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard success else {
            throw AgenTTYHostRuntimeProvisionError.hostPlatformDetectionFailed(trimmedOutput)
        }

        let lines = trimmedOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw AgenTTYHostRuntimeProvisionError.hostPlatformDetectionFailed(trimmedOutput)
        }

        guard let platform = parse(operatingSystem: lines[0], architecture: lines[1]) else {
            throw AgenTTYHostRuntimeProvisionError.unsupportedHostPlatform(
                "\(lines[0]) \(lines[1])"
            )
        }

        return platform
    }

    private static func parse(operatingSystem: String, architecture: String) -> Self? {
        switch (operatingSystem, architecture) {
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            .darwinArm64
        case ("darwin", "x86_64"), ("darwin", "amd64"):
            .darwinX86_64
        case ("linux", "arm64"), ("linux", "aarch64"):
            .linuxArm64
        case ("linux", "x86_64"), ("linux", "amd64"):
            .linuxX86_64
        default:
            nil
        }
    }
}

private enum AgenTTYHostRuntimeAssetGroup: String, Sendable {
    case runtime
    case notifications

    var versionRemotePath: String {
        switch self {
        case .runtime:
            AgenTTYHostRuntime.runtimeAssetsVersionRemotePath
        case .notifications:
            AgenTTYHostRuntime.notificationAssetsVersionRemotePath
        }
    }
}

private struct AgenTTYHostRuntimeBundleAssetSpec: Sendable, Hashable {
    let bundleRelativePath: String
    let remotePath: String
    let executable: Bool

    var displayName: String {
        URL(fileURLWithPath: bundleRelativePath).lastPathComponent
    }

    var isCommandManagedWrapper: Bool {
        switch remotePath {
        case AgenTTYHostRuntime.claudeWrapperRemotePath, AgenTTYHostRuntime.codexWrapperRemotePath:
            true
        default:
            false
        }
    }

    var shouldVerifyPresence: Bool {
        !isCommandManagedWrapper
    }

    var shouldUploadWithStaticAssets: Bool {
        !isCommandManagedWrapper
    }

    var remoteRequirement: AgenTTYRemoteFileRequirement? {
        guard shouldVerifyPresence else {
            return nil
        }
        return AgenTTYRemoteFileRequirement(
            remotePath: remotePath,
            executable: executable
        )
    }
}

private struct AgenTTYLoadedHostRuntimeAsset: Sendable {
    let spec: AgenTTYHostRuntimeBundleAssetSpec
    let data: Data
}

private struct AgenTTYLoadedHostRuntimeAssets: Sendable {
    let hostPlatform: AgenTTYRemoteHostPlatform
    let group: AgenTTYHostRuntimeAssetGroup
    let assets: [AgenTTYLoadedHostRuntimeAsset]
    let version: String

    func asset(remotePath: String) -> AgenTTYLoadedHostRuntimeAsset? {
        assets.first(where: { $0.spec.remotePath == remotePath })
    }
}

private struct AgenTTYInstalledHostRuntimeAssetsMetadata: Sendable {
    let version: String?
    let hostPlatform: AgenTTYRemoteHostPlatform?
}

private struct AgenTTYInstalledHostRuntimeBinaryMetadata: Sendable {
    let runtimeVersion: String?
    let hostPlatform: AgenTTYRemoteHostPlatform?
}

private struct AgenTTYRemoteFileRequirement: Sendable {
    let remotePath: String
    let executable: Bool
}

private struct AgenTTYResolvedHostRuntimeCommands: Sendable {
    let shellPath: String?
    let claudePath: String?
    let codexPath: String?
    let installedShellPath: String?
    let installedClaudePath: String?
    let installedCodexPath: String?
}

private struct AgenTTYRemoteNotifyConfig: Encodable, Sendable {
    let url: String
    let relayToken: String
    let expiresAtEpochSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case url
        case relayToken = "relay_token"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
    }
}

private actor AgenTTYHostRuntimeBundleCache {
    private static let runtimeStaticAssetSpecs = [
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "ThirdPartyNotices.txt",
            remotePath: "\(AgenTTYHostRuntime.rootRemotePath)/share/THIRD-PARTY-NOTICES.txt",
            executable: false
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/agentty-log.sh",
            remotePath: AgenTTYHostRuntime.logHelperRemotePath,
            executable: false
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/agentty-bootstrap.sh",
            remotePath: AgenTTYHostRuntime.bootstrapScriptRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/agentty-shell.sh",
            remotePath: AgenTTYHostRuntime.shellWrapperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/agentty-manifest.sh",
            remotePath: AgenTTYHostRuntime.manifestHelperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/tmux-wrapper.sh",
            remotePath: AgenTTYHostRuntime.tmuxWrapperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/shell/zsh/.zshenv",
            remotePath: "$HOME/.agentty/config/shell/zsh/.zshenv",
            executable: false
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/shell/zsh/.zshrc",
            remotePath: "$HOME/.agentty/config/shell/zsh/.zshrc",
            executable: false
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/shell/bashrc",
            remotePath: "$HOME/.agentty/config/shell/bashrc",
            executable: false
        ),
    ]

    private static let notificationStaticAssetSpecs = [
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/agentty-notify.sh",
            remotePath: AgenTTYHostRuntime.notifyWrapperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/claude-wrapper.sh",
            remotePath: AgenTTYHostRuntime.claudeWrapperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/codex-wrapper.sh",
            remotePath: AgenTTYHostRuntime.codexWrapperRemotePath,
            executable: true
        ),
        AgenTTYHostRuntimeBundleAssetSpec(
            bundleRelativePath: "notifications/claude-settings.json",
            remotePath: AgenTTYHostRuntime.claudeSettingsRemotePath,
            executable: false
        ),
    ]

    private var cachedAssets: [AgenTTYRemoteHostPlatform: [AgenTTYHostRuntimeAssetGroup: AgenTTYLoadedHostRuntimeAssets]] = [:]

    func loadedAssets(
        for hostPlatform: AgenTTYRemoteHostPlatform,
        group: AgenTTYHostRuntimeAssetGroup
    ) throws -> AgenTTYLoadedHostRuntimeAssets {
        if let cachedGroupAssets = cachedAssets[hostPlatform]?[group] {
            return cachedGroupAssets
        }

        let loadedAssets = try Self.loadAssets(for: hostPlatform, group: group)
        var cachedGroupAssets = cachedAssets[hostPlatform] ?? [:]
        cachedGroupAssets[group] = loadedAssets
        cachedAssets[hostPlatform] = cachedGroupAssets
        return loadedAssets
    }

    private static func loadAssets(
        for hostPlatform: AgenTTYRemoteHostPlatform,
        group: AgenTTYHostRuntimeAssetGroup
    ) throws -> AgenTTYLoadedHostRuntimeAssets {
        let specs = assetSpecs(for: hostPlatform, group: group)
        var hasher = SHA256()
        var loadedAssets: [AgenTTYLoadedHostRuntimeAsset] = []
        loadedAssets.reserveCapacity(specs.count)

        for spec in specs {
            let data = try assetData(for: spec)
            loadedAssets.append(AgenTTYLoadedHostRuntimeAsset(spec: spec, data: data))
            hasher.update(data: Data(spec.bundleRelativePath.utf8))
            hasher.update(data: Data(spec.remotePath.utf8))
            hasher.update(data: Data(spec.executable ? [1] : [0]))
            hasher.update(data: data)
        }

        let version = hasher.finalize().map {
            let value = String($0, radix: 16)
            return value.count < 2 ? "0" + value : value
        }.joined()

        return AgenTTYLoadedHostRuntimeAssets(
            hostPlatform: hostPlatform,
            group: group,
            assets: loadedAssets,
            version: version
        )
    }

    @MainActor
    static var runtimeStaticRemoteRequirements: [AgenTTYRemoteFileRequirement] {
        runtimeStaticAssetSpecs.compactMap { $0.remoteRequirement }
    }

    @MainActor
    static var notificationStaticRemoteRequirements: [AgenTTYRemoteFileRequirement] {
        notificationStaticAssetSpecs.compactMap { $0.remoteRequirement }
    }

    private static func assetSpecs(
        for hostPlatform: AgenTTYRemoteHostPlatform,
        group: AgenTTYHostRuntimeAssetGroup
    ) -> [AgenTTYHostRuntimeBundleAssetSpec] {
        _ = hostPlatform
        switch group {
        case .runtime:
            return runtimeStaticAssetSpecs
        case .notifications:
            return notificationStaticAssetSpecs
        }
    }

    private static func assetData(
        for spec: AgenTTYHostRuntimeBundleAssetSpec
    ) throws -> Data {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw AgenTTYHostRuntimeProvisionError.missingAsset(spec.bundleRelativePath)
        }

        let assetURL = resourceURL.appendingPathComponent(spec.bundleRelativePath)
        EsmaLog.terminal.info(
            "host runtime asset resolved path=\(spec.bundleRelativePath, privacy: .public)"
        )

        do {
            return try Data(contentsOf: assetURL)
        } catch {
            EsmaLog.terminal.error(
                "host runtime asset missing path=\(spec.bundleRelativePath, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw AgenTTYHostRuntimeProvisionError.missingAsset(spec.bundleRelativePath)
        }
    }
}

enum AgenTTYHostRuntimeProvisioner {
    private static let bundleCache = AgenTTYHostRuntimeBundleCache()
    private static let artifactStore = AgenTTYHostRuntimeArtifactStore.shared
    private static let requiredManagedTerminfoEntryNames = [
        "xterm-256color",
        "tmux-256color",
    ]

    private enum RelayConnectorStatus {
        case notInstalled
        case current
        case stale
    }

    /// Prepares the base host runtime before the shell channel opens.
    ///
    /// The common already-provisioned reconnect collapses to a single SSH round
    /// trip: one gather script returns all installed metadata, presence checks,
    /// and command realpaths, and performs the idempotent housekeeping writes
    /// inline. Any gap in the gathered facts falls back to the original
    /// step-by-step provisioning path, which uploads whatever is missing.
    static func prepareBaseRuntime(ssh: SSHClientSession) async throws {
        let preparationStartedAt = DispatchTime.now().uptimeNanoseconds
        let gatheredFacts = await gatherHostRuntimeFacts(ssh: ssh)
        EsmaLog.terminal.info(
            "host runtime facts resolved fast_path=\(gatheredFacts != nil) elapsed_ms=\(EsmaDiagnostics.elapsedMilliseconds(since: preparationStartedAt))"
        )

        let installedStaticMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata
        if let gatheredFacts {
            installedStaticMetadata = gatheredFacts.staticMetadata
        } else {
            installedStaticMetadata = await installedStaticAssetsMetadata(
                ssh: ssh,
                group: .runtime
            )
        }
        let hostPlatform = try await resolveHostPlatform(
            ssh: ssh,
            installedMetadata: installedStaticMetadata
        )
        let loadedRuntimeAssets = try await bundleCache.loadedAssets(
            for: hostPlatform,
            group: .runtime
        )

        let staticAssetsKnownCurrent = gatheredFacts?.staticAssetsPresent == true
            && installedStaticMetadata.version == loadedRuntimeAssets.version
            && installedStaticMetadata.hostPlatform == hostPlatform
        if staticAssetsKnownCurrent {
            EsmaLog.terminal.info("host runtime static assets verified current via fast path")
        } else {
            _ = try await syncStaticAssetsIfNeeded(
                logLabel: "host runtime",
                loadedAssets: loadedRuntimeAssets,
                installedMetadata: installedStaticMetadata,
                ssh: ssh
            ) { loadedAssets in
                try await uploadStaticAssets(loadedAssets, ssh: ssh)
            }
        }

        let installedAgentAssetsMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata
        if let gatheredFacts {
            installedAgentAssetsMetadata = gatheredFacts.agentAssetsMetadata
        } else {
            installedAgentAssetsMetadata = await installedStaticAssetsMetadata(
                ssh: ssh,
                group: .notifications
            )
        }
        let loadedAgentAssets = try await bundleCache.loadedAssets(
            for: hostPlatform,
            group: .notifications
        )
        let agentAssetsKnownCurrent = gatheredFacts?.agentAssetsPresent == true
            && installedAgentAssetsMetadata.version == loadedAgentAssets.version
            && installedAgentAssetsMetadata.hostPlatform == hostPlatform
        let agentStaticAssetsCurrent: Bool
        if agentAssetsKnownCurrent {
            agentStaticAssetsCurrent = true
            EsmaLog.terminal.info("host agent integration assets verified current via fast path")
        } else {
            agentStaticAssetsCurrent = try await syncStaticAssetsIfNeeded(
                logLabel: "host agent integration",
                loadedAssets: loadedAgentAssets,
                installedMetadata: installedAgentAssetsMetadata,
                ssh: ssh
            ) { loadedAssets in
                try await uploadStaticAgentAssets(loadedAssets, ssh: ssh)
            }
        }

        let installedBinaryMetadata: AgenTTYInstalledHostRuntimeBinaryMetadata
        if let gatheredFacts {
            installedBinaryMetadata = gatheredFacts.binaryMetadata
        } else {
            installedBinaryMetadata = await installedBinaryRuntimeMetadata(ssh: ssh)
        }
        let expectedRuntimeVersionHint = AgenTTYBuildFlavor.current().expectedHostRuntimeVersionHint
        let binaryPayloadKnownCurrent = gatheredFacts?.binaryPayloadPresent == true
            && gatheredFacts?.managedTerminfoPresent == true
            && gatheredFacts?.runtimePayloadIntegrityValid == true
            && expectedRuntimeVersionHint != nil
            && installedBinaryMetadata.runtimeVersion == expectedRuntimeVersionHint
            && installedBinaryMetadata.hostPlatform == hostPlatform
        if binaryPayloadKnownCurrent {
            EsmaLog.terminal.info("host runtime payload verified current via fast path")
        } else {
            try await syncRuntimePayloadIfNeeded(
                hostPlatform: hostPlatform,
                installedMetadata: installedBinaryMetadata,
                ssh: ssh
            )
        }

        if gatheredFacts == nil {
            try await writeRemoteFile(
                Data(AgenTTYHostRuntime.tmuxSessionName.utf8),
                remotePath: AgenTTYHostRuntime.tmuxSessionNameRemotePath,
                ssh: ssh
            )
        }

        let resolvedCommands: AgenTTYResolvedHostRuntimeCommands?
        do {
            let commands: AgenTTYResolvedHostRuntimeCommands
            if let gatheredFacts {
                commands = gatheredFacts.commands
            } else {
                commands = try await resolveHostRuntimeCommands(ssh: ssh)
            }
            let shellPath = commands.shellPath ?? "/bin/sh"
            if commands.installedShellPath != shellPath {
                try await writeRemoteFile(
                    Data(shellPath.utf8),
                    remotePath: AgenTTYHostRuntime.shellRealpathRemotePath,
                    ssh: ssh
                )
                EsmaLog.terminal.info(
                    "host runtime wrote shell realpath=\(shellPath, privacy: .public)"
                )
            }
            resolvedCommands = commands
        } catch {
            let fallbackShellPath = "/bin/sh"
            try await writeRemoteFile(
                Data(fallbackShellPath.utf8),
                remotePath: AgenTTYHostRuntime.shellRealpathRemotePath,
                ssh: ssh
            )
            EsmaLog.terminal.error(
                "host runtime command resolution failed; using fallback shell error=\(String(describing: error), privacy: .public)"
            )
            resolvedCommands = nil
        }

        if let commands = resolvedCommands {
            do {
                _ = try await syncCommandWrapper(
                commandName: "claude",
                resolvedPath: commands.claudePath,
                installedPath: commands.installedClaudePath,
                wrapperRemotePath: AgenTTYHostRuntime.claudeWrapperRemotePath,
                realpathRemotePath: AgenTTYHostRuntime.claudeRealpathRemotePath,
                asset: loadedAgentAssets.asset(remotePath: AgenTTYHostRuntime.claudeWrapperRemotePath),
                staticAssetsCurrent: agentStaticAssetsCurrent,
                ssh: ssh
            )

                let codexInstalled = try await syncCommandWrapper(
                commandName: "codex",
                resolvedPath: commands.codexPath,
                installedPath: commands.installedCodexPath,
                wrapperRemotePath: AgenTTYHostRuntime.codexWrapperRemotePath,
                realpathRemotePath: AgenTTYHostRuntime.codexRealpathRemotePath,
                asset: loadedAgentAssets.asset(remotePath: AgenTTYHostRuntime.codexWrapperRemotePath),
                staticAssetsCurrent: agentStaticAssetsCurrent,
                ssh: ssh
            )
                if codexInstalled {
                    let (success, output) = await ssh.runCommandCapturingOutput(
                        "\(AgenTTYHostRuntime.notifyBinaryRemotePath) preserve-codex-notify"
                    )
                    guard success else {
                        throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(output)
                    }
                } else {
                    try await removeRemoteFiles(
                        [AgenTTYHostRuntime.codexOriginalNotifyRemotePath],
                        ssh: ssh
                    )
                }
            } catch {
                EsmaLog.terminal.error(
                    "host agent integration setup failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        if gatheredFacts == nil {
            try await removeLegacyRemoteFiles(ssh: ssh)
        }
        EsmaLog.terminal.info(
            "host runtime preparation complete elapsed_ms=\(EsmaDiagnostics.elapsedMilliseconds(since: preparationStartedAt))"
        )
    }

    static func resolveHostPlatform(ssh: SSHClientSession) async throws -> AgenTTYRemoteHostPlatform {
        let installedMetadata = await installedStaticAssetsMetadata(
            ssh: ssh,
            group: .runtime
        )
        return try await resolveHostPlatform(
            ssh: ssh,
            installedMetadata: installedMetadata
        )
    }

    /// Refreshes an existing persistent relay connector after interactive SSH
    /// is already ready. Callers must only run this over a direct connection:
    /// replacing the connector while using its relay would sever that session.
    static func refreshRelayConnectorIfNeeded(ssh: SSHClientSession) async throws -> Bool {
        try Task.checkCancellation()
        let hostPlatform = try await resolveHostPlatform(ssh: ssh)
        guard let artifact = try await artifactStore.hostConnectorReference(
            for: hostPlatform,
            buildFlavor: .current()
        ) else {
            EsmaLog.terminal.notice(
                "relay connector maintenance skipped: manifest has no connector target=\(hostPlatform.rawValue, privacy: .public)"
            )
            return false
        }

        try Task.checkCancellation()
        switch try await relayConnectorStatus(expectedSHA256: artifact.sha256, ssh: ssh) {
        case .notInstalled:
            EsmaLog.terminal.info("relay connector maintenance skipped: connector is not installed")
            return false
        case .current:
            EsmaLog.terminal.info(
                "relay connector already current runtime_version=\(artifact.runtimeVersion, privacy: .public) target=\(hostPlatform.rawValue, privacy: .public)"
            )
            return false
        case .stale:
            break
        }

        try Task.checkCancellation()
        let connectorData = try await artifactStore.hostConnectorData(for: artifact)
        let candidatePath = "\(AgenTTYHostRuntime.hostConnectorBinaryRemotePath).update.\(UUID().uuidString.lowercased())"
        do {
            try Task.checkCancellation()
            try await writeRemoteFile(
                connectorData,
                remotePath: candidatePath,
                executable: true,
                ssh: ssh
            )
            try Task.checkCancellation()
            let command = relayConnectorActivationCommand(candidateRemotePath: candidatePath)
            let (success, output) = await ssh.runCommandCapturingOutput(command)
            guard success else {
                throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(
                    output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            EsmaLog.terminal.notice(
                "relay connector refreshed runtime_version=\(artifact.runtimeVersion, privacy: .public) target=\(hostPlatform.rawValue, privacy: .public) result=\(output.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
            )
            return true
        } catch {
            try? await removeRemoteFiles([candidatePath], ssh: ssh)
            throw error
        }
    }

    private static func relayConnectorStatus(
        expectedSHA256: String,
        ssh: SSHClientSession
    ) async throws -> RelayConnectorStatus {
        let expectedSHA256Literal = SSHClientSession.shellSingleQuoted(
            expectedSHA256.lowercased()
        )
        let command = """
        set -e
        connector_path="\(AgenTTYHostRuntime.hostConnectorBinaryRemotePath)"
        config_path="\(AgenTTYHostRuntime.hostConnectorConfigRemotePath)"
        if [ ! -f "$config_path" ]; then
          printf 'not_installed'
          exit 0
        fi
        if [ ! -x "$connector_path" ]; then
          printf 'stale'
          exit 0
        fi
        if command -v sha256sum >/dev/null 2>&1; then
          actual_sha256="$(sha256sum "$connector_path")"
        elif command -v shasum >/dev/null 2>&1; then
          actual_sha256="$(shasum -a 256 "$connector_path")"
        else
          printf 'checksum_unavailable'
          exit 0
        fi
        actual_sha256="${actual_sha256%% *}"
        expected_sha256=\(expectedSHA256Literal)
        if [ "$actual_sha256" = "$expected_sha256" ]; then
          printf 'current'
        else
          printf 'stale'
        fi
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        let status = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard success else {
            throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(status)
        }
        switch status {
        case "not_installed":
            return .notInstalled
        case "current":
            return .current
        case "stale":
            return .stale
        default:
            throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(
                "Unable to verify relay connector checksum: \(status)"
            )
        }
    }

    nonisolated static func relayConnectorActivationCommand(candidateRemotePath: String) -> String {
        """
        set -e
        target_path="\(AgenTTYHostRuntime.hostConnectorBinaryRemotePath)"
        candidate_path="\(candidateRemotePath)"
        config_path="\(AgenTTYHostRuntime.hostConnectorConfigRemotePath)"
        cleanup() {
          rm -f "$candidate_path"
        }
        trap cleanup 0 1 2 15
        [ -f "$config_path" ]
        "$candidate_path" probe-control --config "$config_path"
        mv -f "$candidate_path" "$target_path"
        trap - 0 1 2 15

        expected_command="$target_path --config $config_path"
        process_list="$(ps -ww -Ao pid=,command= 2>/dev/null || true)"
        restarted=0
        while read -r pid command; do
          [ -n "$pid" ] || continue
          if [ "$command" = "$expected_command" ] && kill -TERM "$pid" 2>/dev/null; then
            restarted=$((restarted + 1))
          fi
        done <<EOF
        $process_list
        EOF
        printf 'updated restarted=%s' "$restarted"
        """
    }

    private struct AgenTTYGatheredHostRuntimeFacts {
        let staticMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata
        let agentAssetsMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata
        let binaryMetadata: AgenTTYInstalledHostRuntimeBinaryMetadata
        let staticAssetsPresent: Bool
        let agentAssetsPresent: Bool
        let binaryPayloadPresent: Bool
        let managedTerminfoPresent: Bool
        let runtimePayloadIntegrityValid: Bool
        let commands: AgenTTYResolvedHostRuntimeCommands
    }

    /// One combined remote script that returns every fact the provisioning
    /// steps would otherwise query through separate exec round trips, and
    /// performs the unconditional idempotent housekeeping (tmux session-name
    /// contract, legacy file cleanup) inline. Returns nil when the script
    /// failed or returned incomplete output, in which case callers use the
    /// original step-by-step path.
    private static func gatherHostRuntimeFacts(
        ssh: SSHClientSession
    ) async -> AgenTTYGatheredHostRuntimeFacts? {
        let staticRequirements = AgenTTYHostRuntimeBundleCache.runtimeStaticRemoteRequirements
        let agentRequirements = AgenTTYHostRuntimeBundleCache.notificationStaticRemoteRequirements
        let binaryRequirements = [
            AgenTTYRemoteFileRequirement(
                remotePath: AgenTTYHostRuntime.tmuxBinaryRemotePath,
                executable: true
            ),
            AgenTTYRemoteFileRequirement(
                remotePath: AgenTTYHostRuntime.notifyBinaryRemotePath,
                executable: true
            ),
        ]
        let terminfoEntryNames = requiredManagedTerminfoEntryNames

        let staticChecks = presenceCheckScript(for: staticRequirements, keyPrefix: "static")
        let agentChecks = presenceCheckScript(for: agentRequirements, keyPrefix: "agent")
        let binaryChecks = presenceCheckScript(for: binaryRequirements, keyPrefix: "bin")
        let terminfoChecks = terminfoEntryNames.enumerated().map { index, entryName in
            """
            if [ -d "\(AgenTTYHostRuntime.terminfoRootRemotePath)" ] && \
            find "\(AgenTTYHostRuntime.terminfoRootRemotePath)" -type f -name "\(entryName)" -print -quit | grep -q .; then
              printf 'ti_\(index)=ok\\n'
            else
              printf 'ti_\(index)=missing\\n'
            fi
            """
        }.joined(separator: "\n")
        let runtimeIntegrityCheck = runtimePayloadIntegrityCheckScript(
            successCommand: "printf 'payload_integrity=ok\\n'",
            failureCommand: "printf 'payload_integrity=invalid\\n'"
        )

        let sessionNamePath = AgenTTYHostRuntime.tmuxSessionNameRemotePath
        let sessionNameLiteral = SSHClientSession.shellSingleQuoted(AgenTTYHostRuntime.tmuxSessionName)
        let legacyPaths = AgenTTYHostRuntime.legacyRemotePaths.joined(separator: " ")

        let command = """
        set +e
        umask 077
        printf 'static_version=%s\\n' "$(cat "\(AgenTTYHostRuntime.runtimeAssetsVersionRemotePath)" 2>/dev/null || true)"
        printf 'agent_assets_version=%s\\n' "$(cat "\(AgenTTYHostRuntime.notificationAssetsVersionRemotePath)" 2>/dev/null || true)"
        printf 'runtime_version=%s\\n' "$(cat "\(AgenTTYHostRuntime.binaryRuntimeVersionRemotePath)" 2>/dev/null || true)"
        printf 'platform=%s\\n' "$(cat "\(AgenTTYHostRuntime.hostPlatformRemotePath)" 2>/dev/null || true)"
        \(staticChecks)
        \(agentChecks)
        \(binaryChecks)
        \(terminfoChecks)
        \(runtimeIntegrityCheck)
        AGENTTY_BIN="$HOME/.agentty/bin"

        resolve_real() {
          command_name="$1"
          filtered_path=''
          old_ifs="$IFS"
          IFS=':'
          for entry in $PATH; do
            if [ "$entry" = "$AGENTTY_BIN" ]; then
              continue
            fi
            if [ -z "$filtered_path" ]; then
              filtered_path="$entry"
            else
              filtered_path="$filtered_path:$entry"
            fi
          done
          IFS="$old_ifs"

          if [ -n "$filtered_path" ]; then
            PATH="$filtered_path" command -v "$command_name" || true
          fi
        }

        shell_path="${SHELL:-}"
        if [ -z "$shell_path" ]; then
          shell_path="$(command -v zsh || command -v bash || command -v sh || true)"
        fi

        printf 'shell=%s\\n' "$shell_path"
        printf 'claude=%s\\n' "$(resolve_real claude)"
        printf 'codex=%s\\n' "$(resolve_real codex)"
        printf 'installed_shell=%s\\n' "$(cat "\(AgenTTYHostRuntime.shellRealpathRemotePath)" 2>/dev/null || true)"
        printf 'installed_claude=%s\\n' "$(cat "\(AgenTTYHostRuntime.claudeRealpathRemotePath)" 2>/dev/null || true)"
        printf 'installed_codex=%s\\n' "$(cat "\(AgenTTYHostRuntime.codexRealpathRemotePath)" 2>/dev/null || true)"
        if mkdir -p "$HOME/.agentty/config" \
          && printf %s \(sessionNameLiteral) > "\(sessionNamePath).part" \
          && mv "\(sessionNamePath).part" "\(sessionNamePath)" \
          && chmod 600 "\(sessionNamePath)"; then
          rm -f \(legacyPaths)
          printf 'housekeeping=done\\n'
        else
          printf 'housekeeping=failed\\n'
        fi
        """

        let (success, output) = await ssh.runCommandCapturingOutput(command)
        guard success else {
            EsmaLog.terminal.notice("host runtime fact gathering failed; using full provisioning path")
            return nil
        }

        var values: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard values["housekeeping"] == "done" else {
            EsmaLog.terminal.notice(
                "host runtime fact gathering housekeeping incomplete; using full provisioning path"
            )
            return nil
        }
        let parsedRuntimePayloadIntegrity = values["payload_integrity"].map { value in
            value == "ok"
        }
        guard
            let staticAssetsPresent = allChecksPassed(
                in: values,
                keyPrefix: "static",
                expectedCount: staticRequirements.count
            ),
            let agentAssetsPresent = allChecksPassed(
                in: values,
                keyPrefix: "agent",
                expectedCount: agentRequirements.count
            ),
            let binaryPayloadPresent = allChecksPassed(
                in: values,
                keyPrefix: "bin",
                expectedCount: binaryRequirements.count
            ),
            let managedTerminfoPresent = allChecksPassed(
                in: values,
                keyPrefix: "ti",
                expectedCount: terminfoEntryNames.count
            ),
            let runtimePayloadIntegrityValid = parsedRuntimePayloadIntegrity
        else {
            EsmaLog.terminal.notice(
                "host runtime fact gathering returned incomplete checks; using full provisioning path"
            )
            return nil
        }

        let hostPlatform = values["platform"].flatMap { AgenTTYRemoteHostPlatform(rawValue: $0) }
        let nonEmpty: (String?) -> String? = { value in
            value.flatMap { $0.isEmpty ? nil : $0 }
        }

        return AgenTTYGatheredHostRuntimeFacts(
            staticMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata(
                version: nonEmpty(values["static_version"]),
                hostPlatform: hostPlatform
            ),
            agentAssetsMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata(
                version: nonEmpty(values["agent_assets_version"]),
                hostPlatform: hostPlatform
            ),
            binaryMetadata: AgenTTYInstalledHostRuntimeBinaryMetadata(
                runtimeVersion: nonEmpty(values["runtime_version"]),
                hostPlatform: hostPlatform
            ),
            staticAssetsPresent: staticAssetsPresent,
            agentAssetsPresent: agentAssetsPresent,
            binaryPayloadPresent: binaryPayloadPresent,
            managedTerminfoPresent: managedTerminfoPresent,
            runtimePayloadIntegrityValid: runtimePayloadIntegrityValid,
            commands: AgenTTYResolvedHostRuntimeCommands(
                shellPath: nonEmpty(values["shell"]),
                claudePath: nonEmpty(values["claude"]),
                codexPath: nonEmpty(values["codex"]),
                installedShellPath: nonEmpty(values["installed_shell"]),
                installedClaudePath: nonEmpty(values["installed_claude"]),
                installedCodexPath: nonEmpty(values["installed_codex"])
            )
        )
    }

    private static func presenceCheckScript(
        for requirements: [AgenTTYRemoteFileRequirement],
        keyPrefix: String
    ) -> String {
        requirements.enumerated().map { index, requirement in
            let testOperator = requirement.executable ? "-x" : "-f"
            return """
            if [ \(testOperator) "\(requirement.remotePath)" ]; then
              printf '\(keyPrefix)_\(index)=ok\\n'
            else
              printf '\(keyPrefix)_\(index)=missing\\n'
            fi
            """
        }.joined(separator: "\n")
    }

    /// Returns true when every `<prefix>_N` key reported ok, false when any
    /// reported missing, and nil when the output did not contain all expected
    /// keys (treated as a gathering failure by callers).
    private static func allChecksPassed(
        in values: [String: String],
        keyPrefix: String,
        expectedCount: Int
    ) -> Bool? {
        var passedCount = 0
        for index in 0..<expectedCount {
            guard let status = values["\(keyPrefix)_\(index)"] else {
                return nil
            }
            if status == "ok" {
                passedCount += 1
            }
        }
        return passedCount == expectedCount
    }

    static func writeRemoteFile(
        _ data: Data,
        remotePath: String,
        executable: Bool = false,
        ssh: SSHClientSession
    ) async throws {
        let expectedSHA256 = sha256Hex(data)
        let didWrite = await ssh.writeRemoteFile(
            data,
            remotePath: remotePath,
            executable: executable,
            expectedSHA256: expectedSHA256
        )
        if didWrite {
            return
        }

        EsmaLog.terminal.error(
            "host runtime remote write failed path=\(remotePath, privacy: .public) retrying=true"
        )

        let didRetryWrite = await ssh.writeRemoteFile(
            data,
            remotePath: remotePath,
            executable: executable,
            expectedSHA256: expectedSHA256
        )
        guard didRetryWrite else {
            throw AgenTTYHostRuntimeProvisionError.remoteWriteFailed(remotePath)
        }

        EsmaLog.terminal.notice(
            "host runtime remote write recovered on retry path=\(remotePath, privacy: .public)"
        )
    }

    static func removeRemoteFiles(
        _ remotePaths: [String],
        ssh: SSHClientSession
    ) async throws {
        guard !remotePaths.isEmpty else { return }

        let command = """
        set -e
        rm -f \(remotePaths.joined(separator: " "))
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        guard success else {
            throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(output)
        }
    }

    static func removeLegacyRemoteFiles(
        ssh: SSHClientSession
    ) async throws {
        try await removeRemoteFiles(AgenTTYHostRuntime.legacyRemotePaths, ssh: ssh)
    }

    fileprivate static func resolveHostRuntimeCommands(
        ssh: SSHClientSession
    ) async throws -> AgenTTYResolvedHostRuntimeCommands {
        let command = """
        set -e
        AGENTTY_BIN="$HOME/.agentty/bin"
        SHELL_REALPATH_FILE="$HOME/.agentty/state/shell-realpath"
        CLAUDE_REALPATH_FILE="$HOME/.agentty/state/claude-realpath"
        CODEX_REALPATH_FILE="$HOME/.agentty/state/codex-realpath"

        resolve_real() {
          command_name="$1"
          filtered_path=''
          old_ifs="$IFS"
          IFS=':'
          for entry in $PATH; do
            if [ "$entry" = "$AGENTTY_BIN" ]; then
              continue
            fi
            if [ -z "$filtered_path" ]; then
              filtered_path="$entry"
            else
              filtered_path="$filtered_path:$entry"
            fi
          done
          IFS="$old_ifs"

          if [ -n "$filtered_path" ]; then
            PATH="$filtered_path" command -v "$command_name" || true
          fi
        }

        shell_path="${SHELL:-}"
        if [ -z "$shell_path" ]; then
          shell_path="$(command -v zsh || command -v bash || command -v sh || true)"
        fi

        printf 'shell=%s\\n' "$shell_path"
        printf 'claude=%s\\n' "$(resolve_real claude)"
        printf 'codex=%s\\n' "$(resolve_real codex)"
        printf 'installed_shell=%s\\n' "$(cat "$SHELL_REALPATH_FILE" 2>/dev/null || true)"
        printf 'installed_claude=%s\\n' "$(cat "$CLAUDE_REALPATH_FILE" 2>/dev/null || true)"
        printf 'installed_codex=%s\\n' "$(cat "$CODEX_REALPATH_FILE" 2>/dev/null || true)"
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard success else {
            throw AgenTTYHostRuntimeProvisionError.remoteCommandFailed(trimmedOutput)
        }

        var values: [String: String] = [:]
        for rawLine in trimmedOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        return AgenTTYResolvedHostRuntimeCommands(
            shellPath: values["shell"].flatMap { $0.isEmpty ? nil : $0 },
            claudePath: values["claude"].flatMap { $0.isEmpty ? nil : $0 },
            codexPath: values["codex"].flatMap { $0.isEmpty ? nil : $0 },
            installedShellPath: values["installed_shell"].flatMap { $0.isEmpty ? nil : $0 },
            installedClaudePath: values["installed_claude"].flatMap { $0.isEmpty ? nil : $0 },
            installedCodexPath: values["installed_codex"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func syncStaticAssetsIfNeeded(
        logLabel: String,
        loadedAssets: AgenTTYLoadedHostRuntimeAssets,
        installedMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata,
        ssh: SSHClientSession,
        uploader: (AgenTTYLoadedHostRuntimeAssets) async throws -> Void
    ) async throws -> Bool {
        let assetsVersionMatchesInstalled = loadedAssets.version == installedMetadata.version
        let assetsPlatformMatchesInstalled = loadedAssets.hostPlatform == installedMetadata.hostPlatform
        let metadataMatchesInstalled = assetsVersionMatchesInstalled && assetsPlatformMatchesInstalled
        let remoteAssetsPresent = metadataMatchesInstalled
            ? await remoteFilesMatchRequirements(
                loadedAssets.assets.compactMap { $0.spec.remoteRequirement },
                ssh: ssh,
                logLabel: logLabel
            )
            : false
        let staticAssetsCurrent =
            metadataMatchesInstalled &&
            remoteAssetsPresent

        EsmaLog.terminal.info(
            "\(logLabel, privacy: .public) provision start platform=\(loadedAssets.hostPlatform.rawValue, privacy: .public) installed_assets_version=\(installedMetadata.version ?? "none", privacy: .public) target_assets_version=\(loadedAssets.version, privacy: .public)"
        )

        if staticAssetsCurrent {
            EsmaLog.terminal.info("\(logLabel, privacy: .public) static assets already current")
            return true
        }

        try await uploader(loadedAssets)
        try await writeRemoteFile(
            Data(loadedAssets.version.utf8),
            remotePath: loadedAssets.group.versionRemotePath,
            ssh: ssh
        )
        try await writeRemoteFile(
            Data(loadedAssets.hostPlatform.rawValue.utf8),
            remotePath: AgenTTYHostRuntime.hostPlatformRemotePath,
            ssh: ssh
        )
        return false
    }

    private static func syncRuntimePayloadIfNeeded(
        hostPlatform: AgenTTYRemoteHostPlatform,
        installedMetadata: AgenTTYInstalledHostRuntimeBinaryMetadata,
        ssh: SSHClientSession
    ) async throws {
        let buildFlavor = AgenTTYBuildFlavor.current()
        let resolvedArtifacts = try await artifactStore.resolvedArtifacts(
            for: hostPlatform,
            buildFlavor: buildFlavor
        )
        let integrityManifest = runtimePayloadIntegrityManifest(for: resolvedArtifacts)
        let resolvedMetadataMatchesInstalled =
            installedMetadata.runtimeVersion == resolvedArtifacts.runtimeVersion &&
            installedMetadata.hostPlatform == hostPlatform
        if resolvedMetadataMatchesInstalled,
           await remoteRuntimePayloadMatches(
               integrityManifest: integrityManifest,
               ssh: ssh
           ) {
            EsmaLog.terminal.info(
                "host runtime payload already current runtime_version=\(resolvedArtifacts.runtimeVersion, privacy: .public) platform=\(hostPlatform.rawValue, privacy: .public)"
            )
            return
        }

        try await writeRemoteFile(
            resolvedArtifacts.tmuxData,
            remotePath: AgenTTYHostRuntime.tmuxBinaryRemotePath,
            executable: true,
            ssh: ssh
        )
        try await writeRemoteFile(
            resolvedArtifacts.notifyData,
            remotePath: AgenTTYHostRuntime.notifyBinaryRemotePath,
            executable: true,
            ssh: ssh
        )
        for terminfoEntry in resolvedArtifacts.terminfoEntries {
            try await writeRemoteFile(
                terminfoEntry.data,
                remotePath: AgenTTYHostRuntime.terminfoEntryRemotePath(
                    relativePath: terminfoEntry.relativePath
                ),
                ssh: ssh
            )
        }
        try await writeRemoteFile(
            Data(integrityManifest.utf8),
            remotePath: AgenTTYHostRuntime.runtimePayloadIntegrityRemotePath,
            ssh: ssh
        )
        try await writeRemoteFile(
            Data(resolvedArtifacts.runtimeVersion.utf8),
            remotePath: AgenTTYHostRuntime.binaryRuntimeVersionRemotePath,
            ssh: ssh
        )
        try await writeRemoteFile(
            Data(hostPlatform.rawValue.utf8),
            remotePath: AgenTTYHostRuntime.hostPlatformRemotePath,
            ssh: ssh
        )
        EsmaLog.terminal.info(
            "host runtime payload synced runtime_version=\(resolvedArtifacts.runtimeVersion, privacy: .public) platform=\(hostPlatform.rawValue, privacy: .public)"
        )
    }

    nonisolated static func runtimePayloadIntegrityManifest(
        for artifacts: AgenTTYResolvedHostRuntimeArtifacts
    ) -> String {
        var entries = [
            "\(artifacts.tmuxSHA256)  libexec/tmux",
            "\(artifacts.notifySHA256)  libexec/agentty-notify",
        ]
        entries.append(contentsOf: artifacts.terminfoEntries
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.sha256)  share/terminfo/\($0.relativePath)" })
        return entries.joined(separator: "\n")
    }

    private static func remoteRuntimePayloadMatches(
        integrityManifest: String,
        ssh: SSHClientSession
    ) async -> Bool {
        let expectedManifest = SSHClientSession.shellSingleQuoted(integrityManifest)
        let integrityCheck = runtimePayloadIntegrityCheckScript(
            successCommand: "true",
            failureCommand: "exit 1"
        )
        let command = """
        set -e
        expected_integrity_manifest=\(expectedManifest)
        actual_integrity_manifest="$(cat \"\(AgenTTYHostRuntime.runtimePayloadIntegrityRemotePath)\" 2>/dev/null || true)"
        [ "$actual_integrity_manifest" = "$expected_integrity_manifest" ]
        \(integrityCheck)
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        if !success {
            EsmaLog.terminal.notice(
                "host runtime integrity probe failed; payload will be repaired output=\(output.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
            )
        }
        return success
    }

    private static func runtimePayloadIntegrityCheckScript(
        successCommand: String,
        failureCommand: String
    ) -> String {
        """
        verify_runtime_payload_integrity() {
          checksum_file="\(AgenTTYHostRuntime.runtimePayloadIntegrityRemotePath)"
          [ -f "$checksum_file" ] || return 1
          if command -v sha256sum >/dev/null 2>&1; then
            (cd "\(AgenTTYHostRuntime.rootRemotePath)" && sha256sum -c "$checksum_file" >/dev/null 2>&1)
          elif command -v shasum >/dev/null 2>&1; then
            (cd "\(AgenTTYHostRuntime.rootRemotePath)" && shasum -a 256 -c "$checksum_file" >/dev/null 2>&1)
          else
            return 1
          fi
        }
        if verify_runtime_payload_integrity; then
          \(successCommand)
        else
          \(failureCommand)
        fi
        """
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let value = String(byte, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }

    private static func resolveHostPlatform(
        ssh: SSHClientSession,
        installedMetadata: AgenTTYInstalledHostRuntimeAssetsMetadata
    ) async throws -> AgenTTYRemoteHostPlatform {
        if let hostPlatform = installedMetadata.hostPlatform {
            return hostPlatform
        }
        return try await AgenTTYRemoteHostPlatform.detect(ssh: ssh)
    }

    private static func uploadStaticAssets(
        _ loadedAssets: AgenTTYLoadedHostRuntimeAssets,
        ssh: SSHClientSession
    ) async throws {
        for asset in loadedAssets.assets {
            EsmaLog.terminal.info(
                "host runtime upload asset=\(asset.spec.remotePath, privacy: .public) bytes=\(asset.data.count)"
            )
            try await writeRemoteFile(
                asset.data,
                remotePath: asset.spec.remotePath,
                executable: asset.spec.executable,
                ssh: ssh
            )
        }
    }

    private static func uploadStaticAgentAssets(
        _ loadedAssets: AgenTTYLoadedHostRuntimeAssets,
        ssh: SSHClientSession
    ) async throws {
        for asset in loadedAssets.assets where asset.spec.shouldUploadWithStaticAssets {
            try await writeRemoteFile(
                asset.data,
                remotePath: asset.spec.remotePath,
                executable: asset.spec.executable,
                ssh: ssh
            )
        }
    }

    private static func syncCommandWrapper(
        commandName: String,
        resolvedPath: String?,
        installedPath: String?,
        wrapperRemotePath: String,
        realpathRemotePath: String,
        asset: AgenTTYLoadedHostRuntimeAsset?,
        staticAssetsCurrent: Bool,
        ssh: SSHClientSession
    ) async throws -> Bool {
        guard let resolvedPath,
              !resolvedPath.isEmpty,
              let asset else {
            try await removeRemoteFiles(
                [wrapperRemotePath, realpathRemotePath],
                ssh: ssh
            )
            EsmaLog.terminal.info(
                "host agent integration unavailable command=\(commandName, privacy: .public)"
            )
            return false
        }

        if installedPath != resolvedPath {
            try await writeRemoteFile(
                Data(resolvedPath.utf8),
                remotePath: realpathRemotePath,
                ssh: ssh
            )
        }
        let wrapperPresent = staticAssetsCurrent
            ? await remoteFilesMatchRequirements(
                [
                    AgenTTYRemoteFileRequirement(
                        remotePath: wrapperRemotePath,
                        executable: true
                    )
                ],
                ssh: ssh,
                logLabel: "host agent integration wrapper command=\(commandName)"
            )
            : false
        if !staticAssetsCurrent || !wrapperPresent {
            try await writeRemoteFile(
                asset.data,
                remotePath: wrapperRemotePath,
                executable: true,
                ssh: ssh
            )
        }
        EsmaLog.terminal.info(
            "host agent integration ready command=\(commandName, privacy: .public) realpath=\(resolvedPath, privacy: .public)"
        )
        return true
    }

    private static func remoteFilesMatchRequirements(
        _ requirements: [AgenTTYRemoteFileRequirement],
        ssh: SSHClientSession,
        logLabel: String
    ) async -> Bool {
        guard !requirements.isEmpty else {
            return true
        }

        let checks = requirements.enumerated().map { index, requirement in
            let testOperator = requirement.executable ? "-x" : "-f"
            return """
            if [ \(testOperator) "\(requirement.remotePath)" ]; then
              printf 'check_\(index)=ok\\n'
            else
              printf 'check_\(index)=missing\\n'
            fi
            """
        }.joined(separator: "\n")

        let command = """
        set +e
        \(checks)
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        guard success else {
            EsmaLog.terminal.error(
                "\(logLabel, privacy: .public) presence probe failed output=\(output.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
            )
            return false
        }

        var statuses: [Int: String] = [:]
        var missingPaths: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }

            let key = String(parts[0])
            let status = String(parts[1])
            guard let index = Int(key.replacingOccurrences(of: "check_", with: "")),
                  requirements.indices.contains(index) else {
                continue
            }
            statuses[index] = status
            if status == "missing" {
                missingPaths.append(requirements[index].remotePath)
            }
        }

        guard statuses.count == requirements.count else {
            EsmaLog.terminal.error(
                "\(logLabel, privacy: .public) presence probe returned incomplete output expected=\(requirements.count) observed=\(statuses.count)"
            )
            return false
        }

        guard missingPaths.isEmpty else {
            EsmaLog.terminal.notice(
                "\(logLabel, privacy: .public) drift detected missing_paths=\(missingPaths.joined(separator: ","), privacy: .public)"
            )
            return false
        }
        return true
    }

    private static func managedTerminfoEntriesPresent(
        named entryNames: [String],
        ssh: SSHClientSession
    ) async -> Bool {
        guard !entryNames.isEmpty else {
            return true
        }

        let checks = entryNames.enumerated().map { index, entryName in
            """
            if find "\(AgenTTYHostRuntime.terminfoRootRemotePath)" -type f -name "\(entryName)" -print -quit | grep -q .; then
              printf 'check_\(index)=ok\\n'
            else
              printf 'check_\(index)=missing\\n'
            fi
            """
        }.joined(separator: "\n")

        let command = """
        set +e
        if [ ! -d "\(AgenTTYHostRuntime.terminfoRootRemotePath)" ]; then
          for index in $(seq 0 \(entryNames.count - 1)); do
            printf 'check_%s=missing\\n' "$index"
          done
        else
        \(checks)
        fi
        """
        let (success, output) = await ssh.runCommandCapturingOutput(command)
        guard success else {
            EsmaLog.terminal.error(
                "host runtime managed terminfo presence probe failed output=\(output.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
            )
            return false
        }

        var statuses: [Int: String] = [:]
        var missingEntries: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }

            let key = String(parts[0])
            let status = String(parts[1])
            guard let index = Int(key.replacingOccurrences(of: "check_", with: "")),
                  entryNames.indices.contains(index) else {
                continue
            }
            statuses[index] = status
            if status == "missing" {
                missingEntries.append(entryNames[index])
            }
        }

        guard statuses.count == entryNames.count else {
            EsmaLog.terminal.error(
                "host runtime managed terminfo presence probe returned incomplete output expected=\(entryNames.count) observed=\(statuses.count)"
            )
            return false
        }

        guard missingEntries.isEmpty else {
            EsmaLog.terminal.notice(
                "host runtime managed terminfo drift detected missing_entries=\(missingEntries.joined(separator: ","), privacy: .public)"
            )
            return false
        }
        return true
    }

    private static func installedStaticAssetsMetadata(
        ssh: SSHClientSession,
        group: AgenTTYHostRuntimeAssetGroup
    ) async -> AgenTTYInstalledHostRuntimeAssetsMetadata {
        let command = """
        printf 'version='
        cat \(group.versionRemotePath) 2>/dev/null || true
        printf '\\nplatform='
        cat \(AgenTTYHostRuntime.hostPlatformRemotePath) 2>/dev/null || true
        """
        let (_, output) = await ssh.runCommandCapturingOutput(command)

        var installedVersion: String?
        var installedHostPlatform: AgenTTYRemoteHostPlatform?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "version":
                installedVersion = value
            case "platform":
                installedHostPlatform = AgenTTYRemoteHostPlatform(rawValue: value)
            default:
                continue
            }
        }

        return AgenTTYInstalledHostRuntimeAssetsMetadata(
            version: installedVersion,
            hostPlatform: installedHostPlatform
        )
    }

    private static func installedBinaryRuntimeMetadata(
        ssh: SSHClientSession
    ) async -> AgenTTYInstalledHostRuntimeBinaryMetadata {
        let command = """
        printf 'runtime_version='
        cat \(AgenTTYHostRuntime.binaryRuntimeVersionRemotePath) 2>/dev/null || true
        printf '\\nplatform='
        cat \(AgenTTYHostRuntime.hostPlatformRemotePath) 2>/dev/null || true
        """
        let (_, output) = await ssh.runCommandCapturingOutput(command)

        var installedRuntimeVersion: String?
        var installedHostPlatform: AgenTTYRemoteHostPlatform?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "runtime_version":
                installedRuntimeVersion = value
            case "platform":
                installedHostPlatform = AgenTTYRemoteHostPlatform(rawValue: value)
            default:
                continue
            }
        }

        return AgenTTYInstalledHostRuntimeBinaryMetadata(
            runtimeVersion: installedRuntimeVersion,
            hostPlatform: installedHostPlatform
        )
    }
}

enum AgenTTYNotificationHostProvisioner {
    static func provision(
        ssh: SSHClientSession,
        relaySession: AgenTTYNotifyRelaySession
    ) async throws -> AgenTTYNotificationProvisionResult {
        try await AgenTTYHostRuntimeProvisioner.writeRemoteFile(
            try notifyConfigData(relaySession: relaySession),
            remotePath: AgenTTYHostRuntime.notifyConfigRemotePath,
            ssh: ssh
        )
        EsmaLog.terminal.info(
            "notifications host wrote notify.json expires_at=\(relaySession.expiresAtEpochSeconds)"
        )

        let resolvedCommands = try await AgenTTYHostRuntimeProvisioner.resolveHostRuntimeCommands(
            ssh: ssh
        )

        return AgenTTYNotificationProvisionResult(
            claudeInstalled: resolvedCommands.claudePath != nil,
            codexInstalled: resolvedCommands.codexPath != nil
        )
    }

    private static func notifyConfigData(
        relaySession: AgenTTYNotifyRelaySession
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            AgenTTYRemoteNotifyConfig(
                url: AgenTTYRelayConfiguration.baseURL.absoluteString,
                relayToken: relaySession.relayToken,
                expiresAtEpochSeconds: Int64(relaySession.expiresAtEpochSeconds)
            )
        )
    }
}
