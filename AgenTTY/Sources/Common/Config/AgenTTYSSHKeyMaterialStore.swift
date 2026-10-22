import Foundation
import Crypto
import _CryptoExtras
import NIOSSH
@unsafe @preconcurrency import Security

nonisolated enum AgenTTYSSHKeyMaterialError: LocalizedError, Equatable {
    case bootstrapSeedKeyMaterialUnavailable
    case invalidBootstrapSeedKeyMaterial
    case keyMaterialNotFound
    case keyMaterialCorrupt
    case keychainStoreFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case encryptedPrivateKeyNotSupported
    case privateKeyPassphraseRequired
    case privateKeyPassphraseIncorrect
    case unsupportedPrivateKeyCipher(String)
    case rsaKeyTooSmall
    case unsupportedPrivateKeyFormat
    case invalidPrivateKeyFormat
    case unsupportedPrivateKeyType(String)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .bootstrapSeedKeyMaterialUnavailable:
            "Bootstrap SSH key material is unavailable for this build."
        case .invalidBootstrapSeedKeyMaterial:
            "The bootstrap SSH key material is invalid."
        case .keyMaterialNotFound:
            "No private key material was found for the selected key."
        case .keyMaterialCorrupt:
            "Stored private key material is corrupt."
        case .keychainStoreFailed:
            "Failed to store private key material in Keychain."
        case .keychainReadFailed:
            "Failed to read private key material from Keychain."
        case .keychainDeleteFailed:
            "Failed to delete private key material from Keychain."
        case .encryptedPrivateKeyNotSupported:
            "This encrypted private key format is not supported. Re-export it with `ssh-keygen -p -o -f <key>`."
        case .privateKeyPassphraseRequired:
            "This private key is passphrase-protected. Enter its passphrase and try again."
        case .privateKeyPassphraseIncorrect:
            "That passphrase did not unlock this private key."
        case .unsupportedPrivateKeyCipher(let cipher):
            "Private keys encrypted with \(cipher) are not supported. Re-export the key with `ssh-keygen -p -o -f <key>` to use the default aes256-ctr cipher."
        case .rsaKeyTooSmall:
            "This RSA key is smaller than \(AgenTTYSSHPrivateKeyParser.minimumRSAKeySizeInBits) bits. "
                + "Import a stronger key (`ssh-keygen -t rsa -b 4096`) or use an Ed25519 key instead."
        case .unsupportedPrivateKeyFormat:
            "Unsupported private key format."
        case .invalidPrivateKeyFormat:
            "The provided private key is invalid."
        case .unsupportedPrivateKeyType(let type):
            "Unsupported private key type: \(type)."
        case .internalError(let message):
            "An internal error occurred: \(message)."
        }
    }
}

struct AgenTTYStoredSSHPrivateKey: Sendable {
    enum Kind: String, Codable, Sendable {
        case ed25519
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
        case rsa
    }

    let kind: Kind
    /// Curve keys store their scalar; `.rsa` stores the PKCS#1 DER produced by `derRepresentation`.
    let rawRepresentation: Data

    nonisolated private var kindTag: UInt8 {
        switch kind {
        case .ed25519: 1
        case .ecdsaP256: 2
        case .ecdsaP384: 3
        case .ecdsaP521: 4
        case .rsa: 5
        }
    }

    var sshKeyType: SSHKeyType {
        switch kind {
        case .ed25519: .ed25519
        case .ecdsaP256: .ecdsa256
        case .ecdsaP384: .ecdsa384
        case .ecdsaP521: .ecdsa521
        case .rsa: .rsa
        }
    }

    nonisolated func makeNIOSSHPrivateKey() throws -> NIOSSHPrivateKey {
        switch kind {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
            return NIOSSHPrivateKey(ed25519Key: key)
        case .ecdsaP256:
            let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
            return NIOSSHPrivateKey(p256Key: key)
        case .ecdsaP384:
            let key = try P384.Signing.PrivateKey(rawRepresentation: rawRepresentation)
            return NIOSSHPrivateKey(p384Key: key)
        case .ecdsaP521:
            let key = try P521.Signing.PrivateKey(rawRepresentation: rawRepresentation)
            return NIOSSHPrivateKey(p521Key: key)
        case .rsa:
            let key = try _RSA.Signing.PrivateKey(derRepresentation: rawRepresentation)
            return try NIOSSHPrivateKey(rsaKey: key)
        }
    }

    nonisolated func openSSHPublicKey() throws -> String {
        let privateKey = try makeNIOSSHPrivateKey()
        return String(openSSHPublicKey: privateKey.publicKey)
    }

    nonisolated func fingerprint() throws -> String {
        let publicKey = try openSSHPublicKey()
        do {
            return try AgenTTYSSHFingerprint.sha256(fromOpenSSHPublicKey: publicKey)
        } catch {
            throw AgenTTYSSHKeyMaterialError.keyMaterialCorrupt
        }
    }

    nonisolated func encodePayload() -> Data {
        var payload = Data([kindTag])
        payload.append(rawRepresentation)
        return payload
    }

    nonisolated static func decodePayload(_ payload: Data) -> AgenTTYStoredSSHPrivateKey? {
        guard let kindTag = payload.first else { return nil }
        guard let kind = kind(from: kindTag) else { return nil }
        let raw = Data(payload.dropFirst())
        guard !raw.isEmpty else { return nil }
        return AgenTTYStoredSSHPrivateKey(kind: kind, rawRepresentation: raw)
    }

    nonisolated private static func kind(from tag: UInt8) -> Kind? {
        switch tag {
        case 1: .ed25519
        case 2: .ecdsaP256
        case 3: .ecdsaP384
        case 4: .ecdsaP521
        case 5: .rsa
        default: nil
        }
    }

    nonisolated static func bootstrapSeedMaterial() throws -> AgenTTYStoredSSHPrivateKey {
        guard let rawBase64 = AgenTTYSSHSeedPolicy.bootstrapSeedPrivateKeyRawBase64 else {
            throw AgenTTYSSHKeyMaterialError.bootstrapSeedKeyMaterialUnavailable
        }

        guard let raw = Data(base64Encoded: rawBase64), raw.count == 32 else {
            throw AgenTTYSSHKeyMaterialError.invalidBootstrapSeedKeyMaterial
        }

        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return AgenTTYStoredSSHPrivateKey(kind: .ed25519, rawRepresentation: raw)
    }
}

nonisolated final class AgenTTYSSHKeyMaterialStore: @unchecked Sendable {
    private let serviceName: String

    @MainActor
    convenience init() {
        self.init(flavor: .current())
    }

    init(flavor: AgenTTYBuildFlavor) {
        serviceName = flavor.sshKeyMaterialKeychainServiceV1
    }

    func hasMaterial(for keyID: UUID) -> Bool {
        do {
            _ = try loadMaterial(for: keyID)
            return true
        } catch {
            return false
        }
    }

    func store(_ material: AgenTTYStoredSSHPrivateKey, for keyID: UUID) throws {
        let payload = material.encodePayload()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keyID.uuidString,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status != errSecItemNotFound {
            throw AgenTTYSSHKeyMaterialError.keychainStoreFailed(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgenTTYSSHKeyMaterialError.keychainStoreFailed(addStatus)
        }
    }

    func loadMaterial(for keyID: UUID) throws -> AgenTTYStoredSSHPrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keyID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw AgenTTYSSHKeyMaterialError.keyMaterialNotFound
        }
        guard status == errSecSuccess else {
            throw AgenTTYSSHKeyMaterialError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw AgenTTYSSHKeyMaterialError.keyMaterialCorrupt
        }
        guard let material = AgenTTYStoredSSHPrivateKey.decodePayload(data) else {
            throw AgenTTYSSHKeyMaterialError.keyMaterialCorrupt
        }
        return material
    }

    func loadPrivateKey(for keyID: UUID) throws -> NIOSSHPrivateKey {
        let material = try loadMaterial(for: keyID)
        return try material.makeNIOSSHPrivateKey()
    }

    func deleteMaterial(for keyID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keyID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw AgenTTYSSHKeyMaterialError.keychainDeleteFailed(status)
    }
}

enum AgenTTYSSHPrivateKeyParser {
    /// AgenTTY refuses RSA keys weaker than this, independently of what the key file parses as.
    nonisolated static let minimumRSAKeySizeInBits = 2048

    /// `passphrase` is used verbatim and only applies to encrypted `openssh-key-v1` containers.
    static func parse(
        _ rawPrivateKeyText: String,
        passphrase: String? = nil
    ) throws -> AgenTTYStoredSSHPrivateKey {
        let text = rawPrivateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED") {
            throw AgenTTYSSHKeyMaterialError.encryptedPrivateKeyNotSupported
        }

        if text.contains("BEGIN RSA PRIVATE KEY") {
            // The 1024-bit-capable initializer is deliberate: AgenTTY's own floor below then reports
            // a weak key as such instead of surfacing BoringSSL's opaque parameter-size failure.
            guard let rsaKey = try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: text) else {
                throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
            }
            return try makeRSAMaterial(rsaKey)
        }

        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKey(text, passphrase: passphrase)
        }

        if text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN EC PRIVATE KEY") {
            return try parsePEMPrivateKey(text)
        }

        if let raw = Data(base64Encoded: text), raw.count == 32 {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return AgenTTYStoredSSHPrivateKey(kind: .ed25519, rawRepresentation: raw)
        }

        throw AgenTTYSSHKeyMaterialError.unsupportedPrivateKeyFormat
    }

    private static func parsePEMPrivateKey(_ text: String) throws -> AgenTTYStoredSSHPrivateKey {
        if let p256 = try? P256.KeyAgreement.PrivateKey(pemRepresentation: text) {
            _ = try P256.Signing.PrivateKey(rawRepresentation: p256.rawRepresentation)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP256, rawRepresentation: p256.rawRepresentation)
        }
        if let p384 = try? P384.KeyAgreement.PrivateKey(pemRepresentation: text) {
            _ = try P384.Signing.PrivateKey(rawRepresentation: p384.rawRepresentation)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP384, rawRepresentation: p384.rawRepresentation)
        }
        if let p521 = try? P521.KeyAgreement.PrivateKey(pemRepresentation: text) {
            _ = try P521.Signing.PrivateKey(rawRepresentation: p521.rawRepresentation)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP521, rawRepresentation: p521.rawRepresentation)
        }

        // PKCS#8 can also carry RSA. `init(derRepresentation:)` handles PKCS#8 explicitly, whereas
        // BoringSSL's PEM reader is only documented for PKCS#1.
        if let der = decodePEMBody(from: text),
           let rsaKey = try? _RSA.Signing.PrivateKey(unsafeDERRepresentation: der) {
            return try makeRSAMaterial(rsaKey)
        }

        throw AgenTTYSSHKeyMaterialError.unsupportedPrivateKeyFormat
    }

    private static func makeRSAMaterial(
        _ key: _RSA.Signing.PrivateKey
    ) throws -> AgenTTYStoredSSHPrivateKey {
        guard key.keySizeInBits >= minimumRSAKeySizeInBits else {
            throw AgenTTYSSHKeyMaterialError.rsaKeyTooSmall
        }
        return AgenTTYStoredSSHPrivateKey(kind: .rsa, rawRepresentation: key.derRepresentation)
    }

    private static func parseOpenSSHPrivateKey(
        _ pemText: String,
        passphrase: String?
    ) throws -> AgenTTYStoredSSHPrivateKey {
        guard let blob = decodePEMBody(from: pemText) else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        var reader = SSHBinaryReader(data: blob)

        guard let magic = reader.read(count: 15), String(decoding: magic, as: UTF8.self) == "openssh-key-v1\u{0}" else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        let cipherName = try reader.readStringUTF8()
        let kdfName = try reader.readStringUTF8()
        let kdfOptions = try reader.readStringData()
        let isEncrypted = cipherName != "none"

        let keyCount = Int(try reader.readUInt32())
        guard keyCount >= 1 else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        for _ in 0..<keyCount {
            _ = try reader.readStringData() // public keys
        }

        var privateSection = try reader.readStringData()

        if isEncrypted {
            privateSection = try AgenTTYOpenSSHKeyDecryption.decryptPrivateSection(
                cipherName: cipherName,
                kdfName: kdfName,
                kdfOptions: kdfOptions,
                privateSection: privateSection,
                passphrase: passphrase
            )
        }

        var privateReader = SSHBinaryReader(data: privateSection)

        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            // The paired check integers are OpenSSH's only passphrase verifier.
            throw isEncrypted
                ? AgenTTYSSHKeyMaterialError.privateKeyPassphraseIncorrect
                : AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        let keyType = try privateReader.readStringUTF8()

        switch keyType {
        case "ssh-rsa":
            // OpenSSH serializes RSA privates as n, e, d, iqmp, p, q. `iqmp` is recomputed from
            // p and q on construction, so it is read past rather than kept.
            let modulus = try privateReader.readStringData()
            let publicExponent = try privateReader.readStringData()
            let privateExponent = try privateReader.readStringData()
            _ = try privateReader.readStringData() // iqmp
            let primeP = try privateReader.readStringData()
            let primeQ = try privateReader.readStringData()

            guard let rsaKey = try? _RSA.Signing.PrivateKey(
                n: strippedMPInt(modulus),
                e: strippedMPInt(publicExponent),
                d: strippedMPInt(privateExponent),
                p: strippedMPInt(primeP),
                q: strippedMPInt(primeQ)
            ) else {
                throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
            }
            return try makeRSAMaterial(rsaKey)

        case "ssh-ed25519":
            _ = try privateReader.readStringData() // public key
            let privateKey = try privateReader.readStringData()
            guard privateKey.count >= 32 else {
                throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
            }
            let seed = privateKey.prefix(32)
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return AgenTTYStoredSSHPrivateKey(kind: .ed25519, rawRepresentation: Data(seed))

        case "ecdsa-sha2-nistp256":
            _ = try privateReader.readStringUTF8() // curve name
            _ = try privateReader.readStringData() // public key point
            let scalar = try privateReader.readStringData()
            let normalizedScalar = normalizeECScalar(scalar, expectedLength: 32)
            _ = try P256.Signing.PrivateKey(rawRepresentation: normalizedScalar)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP256, rawRepresentation: normalizedScalar)

        case "ecdsa-sha2-nistp384":
            _ = try privateReader.readStringUTF8()
            _ = try privateReader.readStringData()
            let scalar = try privateReader.readStringData()
            let normalizedScalar = normalizeECScalar(scalar, expectedLength: 48)
            _ = try P384.Signing.PrivateKey(rawRepresentation: normalizedScalar)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP384, rawRepresentation: normalizedScalar)

        case "ecdsa-sha2-nistp521":
            _ = try privateReader.readStringUTF8()
            _ = try privateReader.readStringData()
            let scalar = try privateReader.readStringData()
            let normalizedScalar = normalizeECScalar(scalar, expectedLength: 66)
            _ = try P521.Signing.PrivateKey(rawRepresentation: normalizedScalar)
            return AgenTTYStoredSSHPrivateKey(kind: .ecdsaP521, rawRepresentation: normalizedScalar)

        default:
            throw AgenTTYSSHKeyMaterialError.unsupportedPrivateKeyType(keyType)
        }
    }

    private static func decodePEMBody(from pemText: String) -> Data? {
        let base64Body = pemText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()

        return Data(base64Encoded: base64Body)
    }

    /// SSH mpints carry a leading `0x00` whenever the high bit would otherwise read as a sign bit.
    private static func strippedMPInt(_ value: Data) -> Data {
        Data(value.drop(while: { $0 == 0 }))
    }

    private static func normalizeECScalar(_ scalar: Data, expectedLength: Int) -> Data {
        if scalar.count == expectedLength {
            return scalar
        }

        if scalar.count == expectedLength + 1, scalar.first == 0 {
            return Data(scalar.dropFirst())
        }

        if scalar.count < expectedLength {
            var padded = Data(repeating: 0, count: expectedLength - scalar.count)
            padded.append(scalar)
            return padded
        }

        return Data(scalar.suffix(expectedLength))
    }
}

nonisolated struct SSHBinaryReader {
    private let data: Data
    private var index: Data.Index

    init(data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func readUInt32() throws -> UInt32 {
        guard let bytes = read(count: 4) else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }
        return bytes.reduce(0) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    mutating func readStringData() throws -> Data {
        let length = try Int(readUInt32())
        guard let bytes = read(count: length) else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }
        return bytes
    }

    mutating func readStringUTF8() throws -> String {
        let value = try readStringData()
        guard let string = String(data: value, encoding: .utf8) else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }
        return string
    }

    mutating func read(count: Int) -> Data? {
        guard count >= 0 else { return nil }
        guard let endIndex = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
            return nil
        }
        let value = data[index..<endIndex]
        index = endIndex
        return Data(value)
    }
}
