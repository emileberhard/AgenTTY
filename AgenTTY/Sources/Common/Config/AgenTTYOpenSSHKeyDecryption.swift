import Foundation
import Crypto
import _CryptoExtras

/// Decrypts the private section of a passphrase-protected `openssh-key-v1` container.
///
/// Only `ssh-keygen`'s current default (`aes256-ctr` + `bcrypt` KDF) is supported; every other
/// cipher fails closed with an actionable re-export instruction rather than being guessed at.
nonisolated enum AgenTTYOpenSSHKeyDecryption {
    static let supportedCipherName = "aes256-ctr"
    static let supportedKDFName = "bcrypt"

    /// `aes256-ctr` consumes a 32-byte key followed by a 16-byte initial counter block.
    private static let keyByteCount = 32
    private static let counterBlockByteCount = 16

    /// `ssh-keygen -a` accepts arbitrary values; cap it so a hostile file cannot pin the CPU.
    private static let maximumRounds = 1024

    /// Cipher support is decided before the passphrase is demanded, so an unusable key reports
    /// the real reason instead of asking for a passphrase it will reject anyway.
    static func decryptPrivateSection(
        cipherName: String,
        kdfName: String,
        kdfOptions: Data,
        privateSection: Data,
        passphrase: String?
    ) throws -> Data {
        guard cipherName == supportedCipherName else {
            throw AgenTTYSSHKeyMaterialError.unsupportedPrivateKeyCipher(cipherName)
        }
        guard kdfName == supportedKDFName else {
            throw AgenTTYSSHKeyMaterialError.encryptedPrivateKeyNotSupported
        }
        guard let passphrase, !passphrase.isEmpty else {
            throw AgenTTYSSHKeyMaterialError.privateKeyPassphraseRequired
        }

        var optionsReader = SSHBinaryReader(data: kdfOptions)
        let salt = try optionsReader.readStringData()
        let rounds = Int(try optionsReader.readUInt32())
        guard !salt.isEmpty, rounds >= 1, rounds <= maximumRounds else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        guard !privateSection.isEmpty, privateSection.count % counterBlockByteCount == 0 else {
            throw AgenTTYSSHKeyMaterialError.invalidPrivateKeyFormat
        }

        let derived = try BcryptPBKDF.derive(
            passphrase: [UInt8](passphrase.utf8),
            salt: [UInt8](salt),
            rounds: rounds,
            outputByteCount: keyByteCount + counterBlockByteCount
        )

        let key = SymmetricKey(data: Array(derived[..<keyByteCount]))
        let nonce = try AES._CTR.Nonce(nonceBytes: Array(derived[keyByteCount...]))
        return try AES._CTR.decrypt(privateSection, using: key, nonce: nonce)
    }
}
