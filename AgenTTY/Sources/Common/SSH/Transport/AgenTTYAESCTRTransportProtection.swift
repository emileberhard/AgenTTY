import Foundation
import NIOCore
import NIOSSH

/// `aes256-ctr` with `hmac-sha2-256`, as offered by Dropbear-class SSH servers.
///
/// `ivSize` is 16 because RFC 4344 §4 makes the *initial counter block* the IV for
/// the `aes*-ctr` ciphers; NIOSSH truncates the derived IV to `keySizes.ivSize`
/// before handing it to `init(initialKeys:)`.
nonisolated final class AgenTTYAES256CTRTransportProtection: NIOSSHTransportProtection {
    static let cipherName = "aes256-ctr"
    static let macName: String? = "hmac-sha2-256"
    static let cipherBlockSize = AgenTTYAESCTRTransportProtectionCore.cipherBlockSize
    static let keySizes = ExpectedKeySizes(ivSize: 16, encryptionKeySize: 32, macKeySize: 32)

    private let core: AgenTTYAESCTRTransportProtectionCore

    var macBytes: Int { AgenTTYAESCTRTransportProtectionCore.macBytes }
    var lengthEncrypted: Bool { true }

    init(initialKeys: NIOSSHSessionKeys) throws {
        core = try AgenTTYAESCTRTransportProtectionCore(
            initialKeys: initialKeys,
            expectedEncryptionKeySize: Self.keySizes.encryptionKeySize
        )
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        try core.updateKeys(newKeys)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        try core.decryptFirstBlock(&source)
    }

    func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        try core.decryptAndVerifyRemainingPacket(&source, sequenceNumber: sequenceNumber)
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        try core.encryptPacket(&destination, sequenceNumber: sequenceNumber)
    }
}

/// `aes128-ctr` with `hmac-sha2-256`. Identical to the 256-bit scheme apart from
/// the encryption key size.
nonisolated final class AgenTTYAES128CTRTransportProtection: NIOSSHTransportProtection {
    static let cipherName = "aes128-ctr"
    static let macName: String? = "hmac-sha2-256"
    static let cipherBlockSize = AgenTTYAESCTRTransportProtectionCore.cipherBlockSize
    static let keySizes = ExpectedKeySizes(ivSize: 16, encryptionKeySize: 16, macKeySize: 32)

    private let core: AgenTTYAESCTRTransportProtectionCore

    var macBytes: Int { AgenTTYAESCTRTransportProtectionCore.macBytes }
    var lengthEncrypted: Bool { true }

    init(initialKeys: NIOSSHSessionKeys) throws {
        core = try AgenTTYAESCTRTransportProtectionCore(
            initialKeys: initialKeys,
            expectedEncryptionKeySize: Self.keySizes.encryptionKeySize
        )
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        try core.updateKeys(newKeys)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        try core.decryptFirstBlock(&source)
    }

    func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        try core.decryptAndVerifyRemainingPacket(&source, sequenceNumber: sequenceNumber)
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        try core.encryptPacket(&destination, sequenceNumber: sequenceNumber)
    }
}
