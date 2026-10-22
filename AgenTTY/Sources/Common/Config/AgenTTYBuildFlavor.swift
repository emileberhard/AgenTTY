import Foundation

nonisolated enum AgenTTYBuildFlavor: String, Sendable {
    case main
    case dev
    case exp

    static func current(bundle: Bundle = .main) -> AgenTTYBuildFlavor {
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        if bundleIdentifier.hasSuffix(".dev") {
            return .dev
        }
        if bundleIdentifier.hasSuffix(".exp") {
            return .exp
        }
        return .main
    }

    var allowsBootstrapSSHConfiguration: Bool {
        switch self {
        case .main:
            false
        case .dev, .exp:
            true
        }
    }

    var hostsStorageKeyV2: String {
        "hosts.\(rawValue).v2"
    }

    var activeHostIDStorageKeyV2: String {
        "hosts.\(rawValue).active.id.v2"
    }

    var sshKeysStorageKeyV2: String {
        "sshkeys.\(rawValue).v2"
    }

    var trustedHostKeysStorageKeyV1: String {
        "trusted-host-keys.\(rawValue).v1"
    }

    var sshKeyMaterialKeychainServiceV1: String {
        "\(AgenTTYBuildConfiguration.keychainNamespace).\(rawValue).ssh-key-material.v1"
    }

    var sshPasswordBootstrapKeychainServiceV1: String {
        "\(AgenTTYBuildConfiguration.keychainNamespace).\(rawValue).ssh-password-bootstrap.v1"
    }

    var relayDeviceIdentityKeychainServiceV1: String {
        "\(AgenTTYBuildConfiguration.keychainNamespace).\(rawValue).relay-device-identity.v1"
    }

    var notificationPushEnvironment: AgenTTYNotifyRelayPushEnvironment {
        switch self {
        case .main:
            .production
        case .dev, .exp:
            .development
        }
    }

    var enforcesLifetimeAccessPaywall: Bool {
        switch self {
        case .main:
            true
        case .dev, .exp:
            false
        }
    }
}

nonisolated struct AgenTTYSSHBootstrapConfiguration: Sendable {
    let host: String
    let label: String
    let username: String
    let privateKeyRawBase64: String
}

nonisolated enum AgenTTYSSHBootstrapConfigurationProvider {
    static var current: AgenTTYSSHBootstrapConfiguration? {
#if AGENTTY_BOOTSTRAP_SEED
        guard let bootstrap = AgenTTYLocalSecrets.sshBootstrap else { return nil }
        return AgenTTYSSHBootstrapConfiguration(
            host: bootstrap.host,
            label: bootstrap.label,
            username: bootstrap.username,
            privateKeyRawBase64: bootstrap.privateKeyRawBase64
        )
#else
        nil
#endif
    }
}

nonisolated enum AgenTTYSSHSeedPolicy {
    static let bootstrapSeedKeyID = UUID(uuidString: "3E3BFEB7-2E7E-4B68-9A89-9A28F11B2A63")!
    static let bootstrapSeedHostID = UUID(uuidString: "6F31FDF8-1CC0-4DD0-9F80-2A30FCF0A5A6")!
    static let bootstrapSeedMacBookHostID = UUID(uuidString: "8CB62533-3E4A-4A66-B01D-C9CC16C4905D")!
    static let bootstrapSeedKeyName = "agentty@iphone"

    static var isScreenshotMode: Bool {
#if AGENTTY_BOOTSTRAP_SEED
        ProcessInfo.processInfo.arguments.contains("-ASC_SCREENSHOT")
#else
        false
#endif
    }

    static var isBootstrapSeedCompiledIn: Bool {
        AgenTTYSSHBootstrapConfigurationProvider.current != nil
    }

    static func shouldSeedBootstrapConfiguration(for flavor: AgenTTYBuildFlavor) -> Bool {
        flavor.allowsBootstrapSSHConfiguration && isBootstrapSeedCompiledIn
    }

    static func bootstrapSeedHost() -> AgenTTYHost? {
        guard let bootstrapConfiguration = AgenTTYSSHBootstrapConfigurationProvider.current else {
            return nil
        }

        return AgenTTYHost(
            id: bootstrapSeedHostID,
            label: bootstrapConfiguration.label,
            address: bootstrapConfiguration.host,
            port: AgenTTYConnection.defaultPort,
            username: bootstrapConfiguration.username,
            authentication: .key(bootstrapSeedKeyID),
            connectionRoutePolicy: .directOnly,
            relayHostID: nil
        )
    }

    static func bootstrapSeedHosts(for flavor: AgenTTYBuildFlavor) -> [AgenTTYHost] {
        guard let bootstrapHost = bootstrapSeedHost() else {
            return []
        }

        guard flavor == .dev, let macBook = bootstrapSeedMacBookHost() else {
            return [bootstrapHost]
        }
        return [bootstrapHost, macBook]
    }

    static func bootstrapSeedMacBookHost() -> AgenTTYHost? {
        guard let bootstrapConfiguration = AgenTTYSSHBootstrapConfigurationProvider.current else {
            return nil
        }

        guard let address = AgenTTYLocalSecrets.sshBootstrap?.secondaryHost else { return nil }
        return AgenTTYHost(
            id: bootstrapSeedMacBookHostID,
            label: "macbook",
            address: address,
            port: AgenTTYConnection.defaultPort,
            username: bootstrapConfiguration.username,
            authentication: .key(bootstrapSeedKeyID),
            connectionRoutePolicy: .directOnly,
            relayHostID: nil
        )
    }

    static func screenshotDemoHosts() -> [AgenTTYHost]? {
        guard isScreenshotMode,
              let bootstrapHost = bootstrapSeedHost() else {
            return nil
        }

        let macMini = AgenTTYHost(
            id: bootstrapHost.id,
            label: "workstation",
            address: bootstrapHost.address,
            usesTailscaleAddress: bootstrapHost.usesTailscaleAddress,
            port: bootstrapHost.port,
            username: bootstrapHost.username,
            authentication: bootstrapHost.authentication,
            connectionRoutePolicy: bootstrapHost.connectionRoutePolicy,
            relayHostID: bootstrapHost.relayHostID
        )
        let laptop = AgenTTYHost(
            id: bootstrapSeedMacBookHostID,
            label: "laptop",
            address: "laptop.example.invalid",
            port: AgenTTYConnection.defaultPort,
            username: "developer",
            authentication: .key(bootstrapSeedKeyID),
            connectionRoutePolicy: .directOnly,
            relayHostID: nil
        )
        return [macMini, laptop]
    }

    static var bootstrapSeedPrivateKeyRawBase64: String? {
        AgenTTYSSHBootstrapConfigurationProvider.current?.privateKeyRawBase64
    }
}

nonisolated enum AgenTTYScreenshotScreen: String, Sendable {
    case terminal = "01-terminal-anywhere"
    case themes = "02-themes"
    case hosts = "03-hosts"
    case switchHosts = "04-switch-hosts"
    case keys = "05-secure-keys"

    static var current: AgenTTYScreenshotScreen? {
#if AGENTTY_BOOTSTRAP_SEED
        guard AgenTTYSSHSeedPolicy.isScreenshotMode else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-ASC_SCREENSHOT_SCREEN"),
              arguments.indices.contains(flagIndex + 1) else {
            return .terminal
        }
        return AgenTTYScreenshotScreen(rawValue: arguments[flagIndex + 1])
#else
        nil
#endif
    }
}

nonisolated enum AgenTTYScreenshotReadySignal {
    private static let filename = "agentty-screenshot-ready"

    static func reset() {
        guard AgenTTYSSHSeedPolicy.isScreenshotMode else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func markReady(_ screen: AgenTTYScreenshotScreen) {
        guard AgenTTYSSHSeedPolicy.isScreenshotMode else { return }
        try? screen.rawValue.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private static var markerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}
