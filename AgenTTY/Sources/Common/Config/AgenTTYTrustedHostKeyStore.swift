import Foundation
import NIOSSH

enum AgenTTYTrustedHostKeyValidationError: LocalizedError {
    case hostKeyMismatch(expectedFingerprint: String, receivedFingerprint: String)
    case invalidHostKey

    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let expected, let received):
            "SSH host key mismatch. Expected \(expected), got \(received)."
        case .invalidHostKey:
            "Received an invalid SSH host key."
        }
    }
}

struct AgenTTYTrustedHostKeyRecord: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case address
        case port
        case publicKey = "public_key"
        case publicKeys = "public_keys"
        case firstSeenAt = "first_seen_at"
    }

    let hostID: UUID
    let address: String
    let port: Int
    let publicKeys: [String]
    let firstSeenAt: Date

    nonisolated init(
        hostID: UUID,
        address: String,
        port: Int,
        publicKeys: [String],
        firstSeenAt: Date
    ) {
        self.hostID = hostID
        self.address = address
        self.port = port
        self.publicKeys = publicKeys
        self.firstSeenAt = firstSeenAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        firstSeenAt = try container.decode(Date.self, forKey: .firstSeenAt)

        if let publicKeys = try container.decodeIfPresent([String].self, forKey: .publicKeys),
           !publicKeys.isEmpty {
            self.publicKeys = publicKeys
            return
        }

        let publicKey = try container.decode(String.self, forKey: .publicKey)
        publicKeys = [publicKey]
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(publicKeys, forKey: .publicKeys)
        try container.encode(firstSeenAt, forKey: .firstSeenAt)
    }

    nonisolated func contains(publicKey: String) -> Bool {
        publicKeys.contains(publicKey)
    }

    nonisolated var preferredFingerprint: String {
        guard let firstPublicKey = publicKeys.first,
              let fingerprint = try? AgenTTYTrustedHostKeyStore.makeFingerprint(firstPublicKey) else {
            return "unknown"
        }
        return fingerprint
    }
}

nonisolated final class AgenTTYTrustedHostKeyStore: @unchecked Sendable {
    private let storageKey: String
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "dev.agentty.ssh.trusted-host-keys")
    private var persistScheduled = false

    private var recordsByHostID: [UUID: AgenTTYTrustedHostKeyRecord]

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @MainActor
    convenience init() {
        self.init(userDefaults: AgenTTYSharedDefaults.store, flavor: .current())
    }

    init(userDefaults: UserDefaults, flavor: AgenTTYBuildFlavor) {
        self.userDefaults = userDefaults
        storageKey = flavor.trustedHostKeysStorageKeyV1
        recordsByHostID = [:]

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? Self.decoder.decode([AgenTTYTrustedHostKeyRecord].self, from: data) {
            recordsByHostID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.hostID, $0) })
        }
    }

    func validateAndStore(
        hostID: UUID,
        address: String,
        port: Int,
        hostKey: NIOSSHPublicKey,
        acceptedOpenSSHPublicKeys: [String] = [],
        storesValidatedKey: Bool = true
    ) throws {
        let (openSSHPublicKey, fingerprint) = try Self.makeCandidateKeyMaterial(hostKey: hostKey)
        let acceptedPublicKeys = acceptedOpenSSHPublicKeys.isEmpty
            ? []
            : try Self.normalizeOpenSSHPublicKeys(acceptedOpenSSHPublicKeys)
        let expectedAcceptedFingerprint = try acceptedPublicKeys.first.map(Self.makeFingerprint)

        try queue.sync {
            guard let existing = recordsByHostID[hostID] else {
                if !acceptedPublicKeys.isEmpty {
                    guard acceptedPublicKeys.contains(openSSHPublicKey) else {
                        throw AgenTTYTrustedHostKeyValidationError.hostKeyMismatch(
                            expectedFingerprint: expectedAcceptedFingerprint ?? "unknown",
                            receivedFingerprint: fingerprint
                        )
                    }
                }

                if storesValidatedKey {
                    recordsByHostID[hostID] = AgenTTYTrustedHostKeyRecord(
                        hostID: hostID,
                        address: address,
                        port: port,
                        publicKeys: acceptedPublicKeys.isEmpty ? [openSSHPublicKey] : acceptedPublicKeys,
                        firstSeenAt: Date()
                    )
                    schedulePersistLocked()
                }
                return
            }

            guard existing.contains(publicKey: openSSHPublicKey) else {
                throw AgenTTYTrustedHostKeyValidationError.hostKeyMismatch(
                    expectedFingerprint: existing.preferredFingerprint,
                    receivedFingerprint: fingerprint
                )
            }

            guard storesValidatedKey,
                  (existing.address != address || existing.port != port) else {
                return
            }

            recordsByHostID[hostID] = AgenTTYTrustedHostKeyRecord(
                hostID: existing.hostID,
                address: address,
                port: port,
                publicKeys: existing.publicKeys,
                firstSeenAt: existing.firstSeenAt
            )
            schedulePersistLocked()
        }
    }

    func storePinnedHostKeys(
        hostID: UUID,
        address: String,
        port: Int,
        openSSHPublicKeys: [String]
    ) throws {
        let normalizedPublicKeys = try Self.normalizeOpenSSHPublicKeys(openSSHPublicKeys)

        queue.sync {
            recordsByHostID[hostID] = AgenTTYTrustedHostKeyRecord(
                hostID: hostID,
                address: address,
                port: port,
                publicKeys: normalizedPublicKeys,
                firstSeenAt: Date()
            )
            schedulePersistLocked()
        }
    }

    func trustedFingerprint(hostID: UUID, address: String, port: Int) -> String? {
        queue.sync {
            guard let record = recordsByHostID[hostID], record.address == address, record.port == port else {
                return nil
            }
            return record.preferredFingerprint
        }
    }

    func resetTrustedHostKey(hostID: UUID) {
        queue.sync {
            guard recordsByHostID.removeValue(forKey: hostID) != nil else {
                return
            }
            schedulePersistLocked()
        }
    }

    private static func makeCandidateKeyMaterial(
        hostKey: NIOSSHPublicKey
    ) throws -> (publicKey: String, fingerprint: String) {
        let publicKey = String(openSSHPublicKey: hostKey)
        let fingerprint = try makeFingerprint(publicKey)
        return (publicKey, fingerprint)
    }

    fileprivate static func makeFingerprint(_ openSSHPublicKey: String) throws -> String {
        do {
            return try AgenTTYSSHFingerprint.sha256(fromOpenSSHPublicKey: openSSHPublicKey)
        } catch {
            throw AgenTTYTrustedHostKeyValidationError.invalidHostKey
        }
    }

    private static func normalizeOpenSSHPublicKeys(_ openSSHPublicKeys: [String]) throws -> [String] {
        let normalizedPublicKeys = Array(
            NSOrderedSet(array: openSSHPublicKeys.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        ).compactMap { $0 as? String }

        guard !normalizedPublicKeys.isEmpty else {
            throw AgenTTYTrustedHostKeyValidationError.invalidHostKey
        }

        return normalizedPublicKeys
    }

    private func schedulePersistLocked() {
        guard !persistScheduled else { return }
        persistScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            self.persistLocked()
            self.persistScheduled = false
        }
    }

    private func persistLocked() {
        let values = Array(recordsByHostID.values)
        if let data = try? Self.encoder.encode(values) {
            userDefaults.set(data, forKey: storageKey)
        }
    }
}
