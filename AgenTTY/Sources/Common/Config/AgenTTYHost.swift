import Foundation

struct AgenTTYConnectionTarget: Equatable, Sendable {
    let hostID: UUID
    let authentication: AgenTTYConnectionAuthentication
    let host: String
    let username: String
    let port: Int
    let connectHost: String
    let connectPort: Int

    nonisolated func connecting(to host: String, port: Int) -> Self {
        Self(
            hostID: hostID,
            authentication: authentication,
            host: self.host,
            username: username,
            port: self.port,
            connectHost: host,
            connectPort: port
        )
    }
}

enum AgenTTYHostConnectionRoutePolicy: String, Codable, Equatable, Hashable, Sendable {
    case directOnly = "direct_only"
    case directThenRelay = "direct_then_relay"
}

enum AgenTTYConnectionAuthentication: Equatable, Sendable {
    case key(UUID)
    case passwordBootstrap(targetKeyID: UUID, credentialID: UUID)
}

enum AgenTTYHostAuthentication: Equatable, Hashable, Sendable {
    case key(UUID)
    case passwordBootstrap(targetKeyID: UUID, credentialID: UUID)
}

extension AgenTTYHostAuthentication: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case keyID
        case targetKeyID
        case credentialID
    }

    private enum Mode: String, Codable {
        case key
        case passwordBootstrap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .key:
            self = .key(try container.decode(UUID.self, forKey: .keyID))
        case .passwordBootstrap:
            self = .passwordBootstrap(
                targetKeyID: try container.decode(UUID.self, forKey: .targetKeyID),
                credentialID: try container.decode(UUID.self, forKey: .credentialID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let keyID):
            try container.encode(Mode.key, forKey: .mode)
            try container.encode(keyID, forKey: .keyID)
        case .passwordBootstrap(let targetKeyID, let credentialID):
            try container.encode(Mode.passwordBootstrap, forKey: .mode)
            try container.encode(targetKeyID, forKey: .targetKeyID)
            try container.encode(credentialID, forKey: .credentialID)
        }
    }
}

extension AgenTTYHostAuthentication {
    nonisolated var connectionAuthentication: AgenTTYConnectionAuthentication {
        switch self {
        case .key(let keyID):
            .key(keyID)
        case .passwordBootstrap(let targetKeyID, let credentialID):
            .passwordBootstrap(targetKeyID: targetKeyID, credentialID: credentialID)
        }
    }

    nonisolated var keyID: UUID? {
        switch self {
        case .key(let keyID):
            keyID
        case .passwordBootstrap(let targetKeyID, _):
            targetKeyID
        }
    }

    nonisolated var credentialID: UUID? {
        switch self {
        case .key:
            nil
        case .passwordBootstrap(_, let credentialID):
            credentialID
        }
    }
}

struct AgenTTYHost: Codable, Identifiable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case name
        case address
        case usesTailscaleAddress = "uses_tailscale_address"
        case port
        case username
        case authentication
        case connectionRoutePolicy = "connection_route_policy"
        case relayHostID = "relay_host_id"
        case sshKeyID
    }

    nonisolated var connectionTarget: AgenTTYConnectionTarget {
        AgenTTYConnectionTarget(
            hostID: id,
            authentication: authentication.connectionAuthentication,
            host: address,
            username: username,
            port: port,
            connectHost: address,
            connectPort: port
        )
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: UUID
    let label: String
    let address: String
    let usesTailscaleAddress: Bool
    let port: Int
    let username: String
    let authentication: AgenTTYHostAuthentication
    let connectionRoutePolicy: AgenTTYHostConnectionRoutePolicy
    let relayHostID: String?

    nonisolated init(
        id: UUID,
        label: String,
        address: String,
        usesTailscaleAddress: Bool = false,
        port: Int,
        username: String,
        authentication: AgenTTYHostAuthentication,
        connectionRoutePolicy: AgenTTYHostConnectionRoutePolicy = .directOnly,
        relayHostID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.usesTailscaleAddress = usesTailscaleAddress
        self.port = port
        self.username = username
        self.authentication = authentication
        self.connectionRoutePolicy = connectionRoutePolicy
        let normalizedRelayHostID = relayHostID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayHostID = normalizedRelayHostID?.isEmpty == false ? normalizedRelayHostID : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        usesTailscaleAddress = try container.decodeIfPresent(Bool.self, forKey: .usesTailscaleAddress) ?? false
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)

        if let authentication = try container.decodeIfPresent(AgenTTYHostAuthentication.self, forKey: .authentication) {
            self.authentication = authentication
            connectionRoutePolicy = try container.decodeIfPresent(
                AgenTTYHostConnectionRoutePolicy.self,
                forKey: .connectionRoutePolicy
            ) ?? .directOnly
            let decodedRelayHostID = try container.decodeIfPresent(String.self, forKey: .relayHostID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            relayHostID = decodedRelayHostID?.isEmpty == false ? decodedRelayHostID : nil
            return
        }

        let legacyKeyID = try container.decode(UUID.self, forKey: .sshKeyID)
        authentication = .key(legacyKeyID)
        connectionRoutePolicy = .directOnly
        relayHostID = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(address, forKey: .address)
        try container.encode(usesTailscaleAddress, forKey: .usesTailscaleAddress)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authentication, forKey: .authentication)
        try container.encode(connectionRoutePolicy, forKey: .connectionRoutePolicy)
        try container.encodeIfPresent(relayHostID, forKey: .relayHostID)
    }
}

struct AgenTTYHostDraft: Equatable, Sendable {
    let label: String
    let address: String
    let usesTailscaleAddress: Bool
    let port: Int
    let username: String
    let authentication: AgenTTYHostAuthentication
    let connectionRoutePolicy: AgenTTYHostConnectionRoutePolicy
    let relayHostID: String?

    init?(
        label: String,
        address: String,
        usesTailscaleAddress: Bool = false,
        port: Int,
        username: String,
        authentication: AgenTTYHostAuthentication,
        connectionRoutePolicy: AgenTTYHostConnectionRoutePolicy = .directOnly,
        relayHostID: String? = nil
    ) {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAddress = AgenTTYHostAddressNormalizer.normalizeForStorage(address)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRelayHostID = relayHostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRelayHostID = normalizedRelayHostID?.isEmpty == false ? normalizedRelayHostID : nil

        guard !normalizedLabel.isEmpty,
              !normalizedAddress.isEmpty,
              !normalizedUsername.isEmpty,
              (1...65_535).contains(port) else {
            return nil
        }

        self.label = normalizedLabel
        self.address = normalizedAddress
        self.usesTailscaleAddress = usesTailscaleAddress
        self.port = port
        self.username = normalizedUsername
        self.authentication = authentication
        self.connectionRoutePolicy = resolvedRelayHostID == nil ? .directOnly : connectionRoutePolicy
        self.relayHostID = resolvedRelayHostID
    }
}
