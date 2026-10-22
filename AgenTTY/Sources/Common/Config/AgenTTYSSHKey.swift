import Foundation

enum SSHKeyType: String, Codable, CaseIterable, Sendable {
    case ed25519
    case ecdsa256 = "ecdsa-256"
    case ecdsa384 = "ecdsa-384"
    case ecdsa521 = "ecdsa-521"
    case rsa

    /// Every other case is import-only. AgenTTY generates Ed25519 and nothing else.
    static let generatable: [SSHKeyType] = [.ed25519]

    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa256: "ECDSA P-256"
        case .ecdsa384: "ECDSA P-384"
        case .ecdsa521: "ECDSA P-521"
        case .rsa: "RSA"
        }
    }
}

enum AgenTTYSSHKeySource: String, Codable, Sendable {
    case generated
    case imported
    case seededBootstrap

    private static let legacySeededRawValue = "seededLegacy"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        if rawValue == Self.legacySeededRawValue {
            self = .seededBootstrap
            return
        }

        guard let parsed = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported SSH key source: \(rawValue)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .generated:
            "generated"
        case .imported:
            "imported"
        case .seededBootstrap:
            "imported"
        }
    }
}

struct AgenTTYSSHKey: Codable, Identifiable, Equatable, Hashable, Sendable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: UUID
    let name: String
    let keyType: SSHKeyType
    let publicKey: String
    let publicKeyFingerprint: String
    let source: AgenTTYSSHKeySource
    let createdAt: Date
}
