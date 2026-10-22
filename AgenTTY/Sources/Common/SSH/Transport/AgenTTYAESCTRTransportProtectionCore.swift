import Crypto
import Foundation
import NIOCore
import NIOSSH

/// RFC 4253 encrypt-and-MAC transport protection: AES in CTR mode for
/// confidentiality plus a separate HMAC-SHA2-256 over the plaintext packet.
///
/// The two concrete schemes differ only in their encryption key size, so the
/// protocol logic lives here once and the wrappers supply the static negotiation
/// metadata.
nonisolated final class AgenTTYAESCTRTransportProtectionCore {
    static let cipherBlockSize = 16
    /// hmac-sha2-256 tag length.
    static let macBytes = 32
    /// OpenSSH's `PACKET_MAX_SIZE`.
    static let maximumPacketLength: UInt32 = 262_144
    /// padding_length + one payload byte + four padding bytes, rounded up to a block.
    static let minimumPacketLength: UInt32 = 12

    private let expectedEncryptionKeySize: Int
    private let inboundCipher: AgenTTYAESCTRCipher
    private let outboundCipher: AgenTTYAESCTRCipher
    private var inboundMACKey: SymmetricKey
    private var outboundMACKey: SymmetricKey

    init(initialKeys: NIOSSHSessionKeys, expectedEncryptionKeySize: Int) throws {
        self.expectedEncryptionKeySize = expectedEncryptionKeySize
        try Self.validate(initialKeys, expectedEncryptionKeySize: expectedEncryptionKeySize)

        inboundCipher = try AgenTTYAESCTRCipher(
            key: initialKeys.inboundEncryptionKey,
            initialCounterBlock: initialKeys.initialInboundIV
        )
        outboundCipher = try AgenTTYAESCTRCipher(
            key: initialKeys.outboundEncryptionKey,
            initialCounterBlock: initialKeys.initialOutboundIV
        )
        inboundMACKey = initialKeys.inboundMACKey
        outboundMACKey = initialKeys.outboundMACKey
    }

    /// A rekey replaces both keystreams *and* both MAC keys. Missing either half
    /// leaves the session silently using stale key material.
    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        try Self.validate(newKeys, expectedEncryptionKeySize: expectedEncryptionKeySize)

        try inboundCipher.reset(
            key: newKeys.inboundEncryptionKey,
            initialCounterBlock: newKeys.initialInboundIV
        )
        try outboundCipher.reset(
            key: newKeys.outboundEncryptionKey,
            initialCounterBlock: newKeys.initialOutboundIV
        )
        inboundMACKey = newKeys.inboundMACKey
        outboundMACKey = newKeys.outboundMACKey
    }

    /// Decrypts the first cipher block in place so the packet length becomes readable.
    ///
    /// `source` is the parser's accumulated inbound buffer, which may already hold
    /// bytes of the next packet, so exactly one block is decrypted here.
    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard source.readableBytes >= Self.cipherBlockSize,
              let ciphertext = source.getBytes(at: source.readerIndex, length: Self.cipherBlockSize)
        else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: source.readableBytes
            )
        }

        let plaintext = try inboundCipher.apply(to: ciphertext)
        source.setBytes(plaintext, at: source.readerIndex)

        guard let packetLength = source.getInteger(at: source.readerIndex, as: UInt32.self) else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: source.readableBytes
            )
        }

        // With an encrypted length field NIOSSH sizes the next read straight from
        // this value and applies no bound of its own, so the sanity checks below are
        // load-bearing rather than defensive polish. Block alignment follows from
        // `writeSSHPacket(lengthEncrypted: true, blockSize: 16)` and is a cheap
        // corruption detector.
        guard packetLength >= Self.minimumPacketLength,
              packetLength <= Self.maximumPacketLength,
              (packetLength + 4) % UInt32(Self.cipherBlockSize) == 0
        else {
            throw AgenTTYSSHTransportProtectionError.invalidPacketLength(packetLength)
        }
    }

    /// Decrypts everything after the first block, verifies the MAC, and returns the payload.
    ///
    /// Encrypt-and-MAC order is decrypt, then verify, then expose, so no
    /// unauthenticated plaintext other than the length field ever leaves this method.
    func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        let readerIndex = source.readerIndex
        let framedLength = source.readableBytes - Self.macBytes

        guard framedLength >= Self.cipherBlockSize,
              framedLength % Self.cipherBlockSize == 0,
              let decryptedFirstBlock = source.getBytes(at: readerIndex, length: Self.cipherBlockSize),
              let remainingCiphertext = source.getBytes(
                  at: readerIndex + Self.cipherBlockSize,
                  length: framedLength - Self.cipherBlockSize
              ),
              let receivedMAC = source.getBytes(at: readerIndex + framedLength, length: Self.macBytes)
        else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: source.readableBytes
            )
        }

        let remainingPlaintext = try inboundCipher.apply(to: remainingCiphertext)

        // RFC 4253 §6.4: mac = MAC(key, sequence_number || unencrypted_packet).
        var mac = HMAC<SHA256>(key: inboundMACKey)
        mac.update(data: Self.sequenceNumberBytes(sequenceNumber))
        mac.update(data: decryptedFirstBlock)
        mac.update(data: remainingPlaintext)
        guard Self.constantTimeEquals(mac.finalize(), receivedMAC) else {
            throw AgenTTYSSHTransportProtectionError.integrityCheckFailed
        }

        source.setBytes(remainingPlaintext, at: readerIndex + Self.cipherBlockSize)

        guard let packetLength = source.readInteger(as: UInt32.self),
              Int(packetLength) == framedLength - 4
        else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: source.readableBytes
            )
        }
        guard let paddingLength = source.readInteger(as: UInt8.self), paddingLength >= 4 else {
            throw AgenTTYSSHTransportProtectionError.insufficientPadding
        }

        let payloadLength = Int(packetLength) - 1 - Int(paddingLength)
        guard payloadLength >= 0, let payload = source.readSlice(length: payloadLength) else {
            throw AgenTTYSSHTransportProtectionError.excessPadding
        }

        // The parser requires this method to consume the whole slice it was given.
        source.moveReaderIndex(forwardBy: Int(paddingLength) + Self.macBytes)
        return payload
    }

    /// MACs the plaintext packet, encrypts it in place, and appends the tag.
    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let readerIndex = destination.readerIndex
        let framedLength = destination.readableBytes

        guard framedLength >= Self.cipherBlockSize,
              framedLength % Self.cipherBlockSize == 0,
              let plaintext = destination.getBytes(at: readerIndex, length: framedLength)
        else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: framedLength
            )
        }

        var mac = HMAC<SHA256>(key: outboundMACKey)
        mac.update(data: Self.sequenceNumberBytes(sequenceNumber))
        mac.update(data: plaintext)
        let authenticationCode = mac.finalize()

        let ciphertext = try outboundCipher.apply(to: plaintext)
        destination.setBytes(ciphertext, at: readerIndex)

        let written = destination.writeBytes(authenticationCode)
        precondition(written == Self.macBytes, "Unexpected hmac-sha2-256 tag length")
    }

    private static func validate(
        _ keys: NIOSSHSessionKeys,
        expectedEncryptionKeySize: Int
    ) throws {
        let expectedBitCount = expectedEncryptionKeySize * 8
        guard keys.inboundEncryptionKey.bitCount == expectedBitCount else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptionKeySize(
                expectedBytes: expectedEncryptionKeySize,
                actualBits: keys.inboundEncryptionKey.bitCount
            )
        }
        guard keys.outboundEncryptionKey.bitCount == expectedBitCount else {
            throw AgenTTYSSHTransportProtectionError.invalidEncryptionKeySize(
                expectedBytes: expectedEncryptionKeySize,
                actualBits: keys.outboundEncryptionKey.bitCount
            )
        }
    }

    static func sequenceNumberBytes(_ sequenceNumber: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: sequenceNumber >> 24),
            UInt8(truncatingIfNeeded: sequenceNumber >> 16),
            UInt8(truncatingIfNeeded: sequenceNumber >> 8),
            UInt8(truncatingIfNeeded: sequenceNumber),
        ]
    }

    /// swift-crypto's `MessageAuthenticationCode` equality routes to a constant-time
    /// compare, but on Darwin `Crypto` is CryptoKit and CryptoKit only documents
    /// constant time for `isValidAuthenticationCode`, which would force a contiguous
    /// copy of every packet. Six explicit lines remove both the copy and the ambiguity.
    static func constantTimeEquals(_ mac: HMAC<SHA256>.MAC, _ received: [UInt8]) -> Bool {
        guard mac.byteCount == received.count else { return false }

        var difference: UInt8 = 0
        for (expected, actual) in zip(mac, received) {
            difference |= expected ^ actual
        }
        return difference == 0
    }
}
