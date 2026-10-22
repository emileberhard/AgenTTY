import Foundation
import Observation
import Crypto

enum AgenTTYSSHKeyStoreError: LocalizedError {
    case invalidName
    case generationOnlySupportsEd25519
    case keyNotFound
    case keyMaterialFailure(AgenTTYSSHKeyMaterialError)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Key name is required."
        case .generationOnlySupportsEd25519:
            "Only Ed25519 key generation is supported."
        case .keyNotFound:
            "Key was not found."
        case .keyMaterialFailure(let error):
            error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class AgenTTYSSHKeyStore {
    private static let legacyMetadataStorageKey = "sshkeys.v1"

    private let storageKey: String

    private(set) var keys: [AgenTTYSSHKey]
    private(set) var usableKeyIDs: Set<UUID>

    @ObservationIgnored
    private let flavor: AgenTTYBuildFlavor
    @ObservationIgnored
    private let materialStore: AgenTTYSSHKeyMaterialStore
    @ObservationIgnored
    private let userDefaults: UserDefaults

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store,
        flavor: AgenTTYBuildFlavor = .current(),
        materialStore: AgenTTYSSHKeyMaterialStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.flavor = flavor
        self.materialStore = materialStore ?? AgenTTYSSHKeyMaterialStore(flavor: flavor)
        storageKey = flavor.sshKeysStorageKeyV2
        keys = []
        usableKeyIDs = []

        if AgenTTYSSHSeedPolicy.isScreenshotMode {
            _ = ensureBootstrapSeedKey()
            refreshUsableKeyIDs()
            return
        }

        let persistedV2 = loadV2Keys()
        let initialKeys: [AgenTTYSSHKey]
        if let persisted = persistedV2 {
            initialKeys = persisted
        } else {
            initialKeys = migrateFromLegacyIfNeeded()
        }
        keys = initialKeys

        var shouldPersistMetadata = persistedV2 == nil
        if let persistedV2, persistedV2 != keys {
            shouldPersistMetadata = true
        }

        if AgenTTYSSHSeedPolicy.shouldSeedBootstrapConfiguration(for: flavor) {
            shouldPersistMetadata = ensureBootstrapSeedKey() || shouldPersistMetadata
        } else {
            shouldPersistMetadata = pruneBootstrapSeedKeyIfPresent() || shouldPersistMetadata
        }

        refreshUsableKeyIDs()
        if shouldPersistMetadata {
            persist()
        }
    }

    func addGeneratedKey(name: String, keyType: SSHKeyType) -> Result<UUID, AgenTTYSSHKeyStoreError> {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return .failure(.invalidName)
        }
        guard keyType == .ed25519 else {
            return .failure(.generationOnlySupportsEd25519)
        }

        do {
            let generated = Curve25519.Signing.PrivateKey()
            let material = AgenTTYStoredSSHPrivateKey(
                kind: .ed25519,
                rawRepresentation: generated.rawRepresentation
            )

            let keyID = UUID()
            try materialStore.store(material, for: keyID)
            let metadata = try makeMetadata(
                id: keyID,
                name: normalizedName,
                material: material,
                source: .generated,
                createdAt: Date()
            )
            keys.append(metadata)
            usableKeyIDs.insert(keyID)
            persist()
            return .success(keyID)
        } catch let error as AgenTTYSSHKeyMaterialError {
            return .failure(.keyMaterialFailure(error))
        } catch {
            EsmaLog.app.error("failed generating key: \(error, privacy: .public)")
            return .failure(.keyMaterialFailure(.internalError(error.localizedDescription)))
        }
    }

    func addImportedKey(
        name: String,
        privateKeyText: String,
        passphrase: String? = nil
    ) -> Result<UUID, AgenTTYSSHKeyStoreError> {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return .failure(.invalidName)
        }

        do {
            let material = try AgenTTYSSHPrivateKeyParser.parse(privateKeyText, passphrase: passphrase)
            let keyID = UUID()
            try materialStore.store(material, for: keyID)
            let metadata = try makeMetadata(
                id: keyID,
                name: normalizedName,
                material: material,
                source: .imported,
                createdAt: Date()
            )
            keys.append(metadata)
            usableKeyIDs.insert(keyID)
            persist()
            return .success(keyID)
        } catch let error as AgenTTYSSHKeyMaterialError {
            return .failure(.keyMaterialFailure(error))
        } catch {
            EsmaLog.app.error("failed importing key: \(error, privacy: .public)")
            return .failure(.keyMaterialFailure(.internalError(error.localizedDescription)))
        }
    }

    func updateKeyName(id: UUID, name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return false }

        let existing = keys[index]
        keys[index] = AgenTTYSSHKey(
            id: existing.id,
            name: normalizedName,
            keyType: existing.keyType,
            publicKey: existing.publicKey,
            publicKeyFingerprint: existing.publicKeyFingerprint,
            source: existing.source,
            createdAt: existing.createdAt
        )
        persist()
        return true
    }

    func deleteKey(id: UUID) -> Result<Void, AgenTTYSSHKeyStoreError> {
        guard let index = keys.firstIndex(where: { $0.id == id }) else {
            return .failure(.keyNotFound)
        }

        do {
            try materialStore.deleteMaterial(for: id)
        } catch let error as AgenTTYSSHKeyMaterialError {
            return .failure(.keyMaterialFailure(error))
        } catch {
            return .failure(.keyMaterialFailure(.keychainDeleteFailed(errSecInternalError)))
        }

        keys.remove(at: index)
        usableKeyIDs.remove(id)
        persist()
        return .success(())
    }

    func contains(id: UUID) -> Bool {
        keys.contains(where: { $0.id == id })
    }

    func hasUsableMaterial(for keyID: UUID) -> Bool {
        usableKeyIDs.contains(keyID)
    }

    func keyName(for keyID: UUID) -> String? {
        keys.first(where: { $0.id == keyID })?.name
    }

    func publicKey(for keyID: UUID) -> String? {
        keys.first(where: { $0.id == keyID })?.publicKey
    }

    func userAuthentication(for keyID: UUID, username: String) throws -> AgenTTYSSHUserAuthentication {
        let material = try materialStore.loadMaterial(for: keyID)
        return .privateKey(
            username: username,
            privateKey: try material.makeNIOSSHPrivateKey()
        )
    }

    func defaultGeneratedKeyID(named preferredName: String) -> UUID? {
        if let existingKey = keysWithUsableMaterial.first(where: { $0.name == preferredName }) {
            return existingKey.id
        }

        switch addGeneratedKey(name: preferredName, keyType: .ed25519) {
        case .success(let keyID):
            return keyID
        case .failure(let error):
            EsmaLog.app.error("failed creating default ssh key: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var keysWithUsableMaterial: [AgenTTYSSHKey] {
        keys.filter { usableKeyIDs.contains($0.id) }
    }

    private func makeMetadata(
        id: UUID,
        name: String,
        material: AgenTTYStoredSSHPrivateKey,
        source: AgenTTYSSHKeySource,
        createdAt: Date
    ) throws -> AgenTTYSSHKey {
        let publicKey = try material.openSSHPublicKey()
        let fingerprint = try AgenTTYSSHFingerprint.sha256(fromOpenSSHPublicKey: publicKey)
        return AgenTTYSSHKey(
            id: id,
            name: name,
            keyType: material.sshKeyType,
            publicKey: publicKey,
            publicKeyFingerprint: fingerprint,
            source: source,
            createdAt: createdAt
        )
    }

    private func loadV2Keys() -> [AgenTTYSSHKey]? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return nil
        }
        return try? Self.decoder.decode([AgenTTYSSHKey].self, from: data)
    }

    private func migrateFromLegacyIfNeeded() -> [AgenTTYSSHKey] {
        guard let data = userDefaults.data(forKey: Self.legacyMetadataStorageKey) else {
            return []
        }

        if let decodedV2 = try? Self.decoder.decode([AgenTTYSSHKey].self, from: data) {
            return decodedV2
        }

        // Legacy v1 keys were placeholders only and did not include private material.
        return []
    }

    private func ensureBootstrapSeedKey() -> Bool {
        var didMutateMetadata = false
        do {
            let material = try AgenTTYStoredSSHPrivateKey.bootstrapSeedMaterial()
            if !materialStore.hasMaterial(for: AgenTTYSSHSeedPolicy.bootstrapSeedKeyID) {
                try materialStore.store(material, for: AgenTTYSSHSeedPolicy.bootstrapSeedKeyID)
            }

            let seededMetadata = try makeMetadata(
                id: AgenTTYSSHSeedPolicy.bootstrapSeedKeyID,
                name: AgenTTYSSHSeedPolicy.bootstrapSeedKeyName,
                material: material,
                source: .seededBootstrap,
                createdAt: Date(timeIntervalSince1970: 0)
            )

            if let existingIndex = keys.firstIndex(where: { $0.id == AgenTTYSSHSeedPolicy.bootstrapSeedKeyID }) {
                if keys[existingIndex] != seededMetadata {
                    keys[existingIndex] = seededMetadata
                    didMutateMetadata = true
                }
            } else {
                keys.insert(seededMetadata, at: 0)
                didMutateMetadata = true
            }
            usableKeyIDs.insert(AgenTTYSSHSeedPolicy.bootstrapSeedKeyID)
        } catch let error as AgenTTYSSHKeyMaterialError {
            EsmaLog.app.error("failed to bootstrap ssh key: \(error.localizedDescription, privacy: .public)")
        } catch {
            EsmaLog.app.error("failed to bootstrap ssh key: \(error, privacy: .public)")
        }
        return didMutateMetadata
    }

    private func pruneBootstrapSeedKeyIfPresent() -> Bool {
        let bootstrapID = AgenTTYSSHSeedPolicy.bootstrapSeedKeyID
        let originalCount = keys.count
        keys.removeAll { $0.id == bootstrapID }
        usableKeyIDs.remove(bootstrapID)
        do {
            try materialStore.deleteMaterial(for: bootstrapID)
        } catch let error as AgenTTYSSHKeyMaterialError {
            EsmaLog.app.error("failed pruning bootstrap ssh key material: \(error.localizedDescription, privacy: .public)")
        } catch {
            EsmaLog.app.error("failed pruning bootstrap ssh key material: \(error, privacy: .public)")
        }
        return keys.count != originalCount
    }

    private func refreshUsableKeyIDs() {
        usableKeyIDs = Set(keys.lazy.filter { self.materialStore.hasMaterial(for: $0.id) }.map(\.id))
    }

    private func persist() {
        do {
            let encoded = try Self.encoder.encode(keys)
            userDefaults.set(encoded, forKey: storageKey)
        } catch {
            EsmaLog.app.error("failed to encode SSH keys: \(error, privacy: .public)")
        }
    }
}
