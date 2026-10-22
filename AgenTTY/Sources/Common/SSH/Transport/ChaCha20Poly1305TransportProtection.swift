import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// Failures raised by ``ChaCha20Poly1305TransportProtection``.
///
/// `NIOSSHError` has no public initializer, and the sibling AES-CTR schemes own
/// `AgenTTYSSHTransportProtectionError`, so this scheme carries its own cases.
/// NIOSSH propagates anything thrown from `NIOSSHTransportProtection` up through
/// the packet parser to `fireErrorCaught`.
nonisolated enum ChaCha20Poly1305TransportProtectionError: Error, Equatable {
    case invalidEncryptionKeySize(expectedBytes: Int, actualBits: Int)
    case invalidEncryptedPacketLength(readableBytes: Int)
    case invalidPacketLength(UInt32)
    case declaredLengthMismatch(declared: UInt32, actual: Int)
    case integrityCheckFailed
    case insufficientPadding
    case excessPadding
    /// `decryptFirstBlock(_:)` was reached before the inbound sequence number for
    /// that packet could be established. See the discussion on
    /// ``ChaCha20Poly1305TransportProtection/decryptFirstBlock(_:)``.
    case inboundSequenceNumberUnavailable
    /// The sequence number the parser reported for the packet body did not match
    /// the one used to decrypt that packet's length field.
    case sequenceNumberMismatch(expected: UInt32, actual: UInt32)
}

/// `chacha20-poly1305@openssh.com`, as specified by OpenSSH's
/// `PROTOCOL.chacha20poly1305` and implemented by its `cipher-chachapoly.c`.
///
/// The negotiated 64-byte key is split into two independent ChaCha20 keys:
/// `K_2 = key[0..<32]` covers the payload and derives the Poly1305 one-time key,
/// `K_1 = key[32..<64]` covers the 4-byte length field on its own. Both use the
/// same nonce, which is the packet's sequence number.
///
/// OpenSSH uses the original ChaCha layout (64-bit counter, 8-byte IV) with
/// `iv = POKE_U64(seqnr)`; `Insecure.ChaCha20CTR` is BoringSSL's RFC 8439 layout
/// (32-bit counter, 12-byte nonce). The two agree exactly when the nonce is four
/// zero bytes followed by the big-endian 64-bit sequence number — and because
/// NIOSSH's sequence number is a `UInt32`, that is eight zero bytes followed by
/// four big-endian sequence bytes.
///
/// `lengthEncrypted` is `false` even though the length field *is* encrypted:
/// NIOSSH only consults that flag for padding arithmetic
/// (`SSHPacketSerializer.writeSSHPacket`), and OpenSSH computes padding over
/// `padding_length ‖ payload ‖ padding` with the 4-byte length excluded
/// (`aadlen = 4`). `false` is what reproduces OpenSSH's padding.
///
/// A single instance is not safe for concurrent use; NIOSSH confines the packet
/// parser and serializer to the channel's event loop.
nonisolated final class ChaCha20Poly1305TransportProtection: NIOSSHTransportProtection {
    static let cipherName = "chacha20-poly1305@openssh.com"
    /// AEAD construction: the MAC negotiation result is ignored, as with the
    /// bundled `*-gcm@openssh.com` schemes.
    static let macName: String? = nil
    static let cipherBlockSize = 8
    /// `encryptionKeySize` is 64 because the scheme needs two 32-byte ChaCha20
    /// keys per direction. `macKeySize` is unused; a non-zero value only avoids
    /// constructing a zero-length `SymmetricKey` during key derivation.
    static let keySizes = ExpectedKeySizes(ivSize: 0, encryptionKeySize: 64, macKeySize: 16)

    /// OpenSSH's `PACKET_MAX_SIZE`.
    static let maximumPacketLength: UInt32 = 262_144
    /// padding_length + one payload byte + four padding bytes, rounded up to a block.
    static let minimumPacketLength: UInt32 = 8

    private static let lengthFieldSize = 4
    private static let polyKeyByteCount = 32

    private var inbound: DirectionalKeys
    private var outbound: DirectionalKeys

    /// The sequence number ``decryptFirstBlock(_:)`` should use for the next
    /// packet, tracked because NIOSSH does not pass one to that method.
    private var nextInboundSequenceNumber: UInt32?
    /// The sequence number the pending packet's length field was decrypted with.
    private var pendingInboundSequenceNumber: UInt32?

    var macBytes: Int { Poly1305.tagByteCount }
    var lengthEncrypted: Bool { false }

    init(initialKeys: NIOSSHSessionKeys) throws {
        inbound = try DirectionalKeys(initialKeys.inboundEncryptionKey)
        outbound = try DirectionalKeys(initialKeys.outboundEncryptionKey)
    }

    /// A rekey replaces both key pairs. Sequence numbers are deliberately *not*
    /// reset: RFC 4253 §6.4 keeps them running across a rekey, and so does the
    /// nonce derived from them.
    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        inbound = try DirectionalKeys(newKeys.inboundEncryptionKey)
        outbound = try DirectionalKeys(newKeys.outboundEncryptionKey)
    }

    // MARK: - Inbound

    /// Decrypts the 4-byte length field in place.
    ///
    /// NIOSSH does not hand a sequence number to this method, but this cipher
    /// derives the length keystream from exactly that value, so it has to be
    /// tracked here. The parser calls `decryptFirstBlock` and
    /// `decryptAndVerifyRemainingPacket` strictly in pairs, in order, so after
    /// the first packet the next number is simply the previous one plus one.
    ///
    /// The number for the *first* packet after keys are installed cannot be
    /// derived from the current NIOSSH API at all — it depends on how many
    /// cleartext packets preceded `SSH_MSG_NEWKEYS`. Registering this scheme
    /// therefore requires the fork to pass the parser's sequence number in (a
    /// `sequenceNumber:` parameter on `decryptFirstBlock`, which is what
    /// OpenSSH's own `chachapoly_get_length` takes); until then this entry point
    /// fails closed rather than guessing.
    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard let sequenceNumber = nextInboundSequenceNumber else {
            throw ChaCha20Poly1305TransportProtectionError.inboundSequenceNumberUnavailable
        }
        try decryptFirstBlock(&source, sequenceNumber: sequenceNumber)
    }

    /// Sequence-number-explicit form of ``decryptFirstBlock(_:)``; this is the
    /// shape the fork should call.
    func decryptFirstBlock(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws {
        guard source.readableBytes >= Self.cipherBlockSize,
              let ciphertext = source.getBytes(at: source.readerIndex, length: Self.lengthFieldSize)
        else {
            throw ChaCha20Poly1305TransportProtectionError.invalidEncryptedPacketLength(
                readableBytes: source.readableBytes
            )
        }

        let nonce = Self.nonce(for: sequenceNumber)
        let plaintext = try Self.chaCha20(
            message: ciphertext,
            key: inbound.lengthKey,
            counter: 0,
            nonce: nonce
        )
        source.setBytes(plaintext, at: source.readerIndex)

        // The parser sizes its next read straight from this value and applies no
        // bound of its own, so a hostile server could otherwise make it buffer
        // megabytes before the tag is ever checked. Block alignment follows from
        // `writeSSHPacket(lengthEncrypted: false, blockSize: 8)`.
        guard let packetLength = source.getInteger(at: source.readerIndex, as: UInt32.self),
              packetLength >= Self.minimumPacketLength,
              packetLength <= Self.maximumPacketLength,
              packetLength % UInt32(Self.cipherBlockSize) == 0
        else {
            throw ChaCha20Poly1305TransportProtectionError.invalidPacketLength(
                source.getInteger(at: source.readerIndex, as: UInt32.self) ?? 0
            )
        }

        pendingInboundSequenceNumber = sequenceNumber
    }

    /// Verifies the Poly1305 tag, then decrypts the packet body.
    ///
    /// `source` holds `plaintextLength(4) ‖ ciphertextBody ‖ tag(16)` — the length
    /// field was already replaced with its plaintext by ``decryptFirstBlock(_:)``.
    /// The tag covers the *ciphertext* length bytes, so those are reconstructed by
    /// re-encrypting the plaintext under this packet's sequence number: ChaCha20 is
    /// a stream cipher, so that reproduces the exact original bytes and keeps the
    /// scheme free of cross-call state that nothing would validate.
    func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        if let pending = pendingInboundSequenceNumber, pending != sequenceNumber {
            throw ChaCha20Poly1305TransportProtectionError.sequenceNumberMismatch(
                expected: pending,
                actual: sequenceNumber
            )
        }

        let readerIndex = source.readerIndex
        let ciphertextLength = source.readableBytes - Self.lengthFieldSize - Poly1305.tagByteCount

        let plaintextLengthBytes: [UInt8]
        let ciphertextBody: [UInt8]
        let receivedTag: [UInt8]

        // Nested scope so the `getBytes` copies are finished before anything
        // mutates `source` and triggers a copy-on-write of the shared storage.
        do {
            guard ciphertextLength >= Self.cipherBlockSize,
                  ciphertextLength % Self.cipherBlockSize == 0,
                  let lengthBytes = source.getBytes(at: readerIndex, length: Self.lengthFieldSize),
                  let body = source.getBytes(
                      at: readerIndex + Self.lengthFieldSize,
                      length: ciphertextLength
                  ),
                  let tag = source.getBytes(
                      at: readerIndex + Self.lengthFieldSize + ciphertextLength,
                      length: Poly1305.tagByteCount
                  )
            else {
                throw ChaCha20Poly1305TransportProtectionError.invalidEncryptedPacketLength(
                    readableBytes: source.readableBytes
                )
            }
            plaintextLengthBytes = lengthBytes
            ciphertextBody = body
            receivedTag = tag
        }

        let declaredLength = Self.readUInt32(plaintextLengthBytes)
        guard declaredLength == UInt32(ciphertextLength) else {
            throw ChaCha20Poly1305TransportProtectionError.declaredLengthMismatch(
                declared: declaredLength,
                actual: ciphertextLength
            )
        }

        let nonce = Self.nonce(for: sequenceNumber)
        let reconstructedLengthCiphertext = try Self.chaCha20(
            message: plaintextLengthBytes,
            key: inbound.lengthKey,
            counter: 0,
            nonce: nonce
        )
        let polyKey = try Self.polyKey(key: inbound.payloadKey, nonce: nonce)

        var authenticated = [UInt8]()
        authenticated.reserveCapacity(Self.lengthFieldSize + ciphertextLength)
        authenticated.append(contentsOf: reconstructedLengthCiphertext)
        authenticated.append(contentsOf: ciphertextBody)

        // Verify before decrypting: no unauthenticated plaintext beyond the length
        // field may ever escape this method.
        guard Poly1305.constantTimeEquals(
            Poly1305.computeTag(key: polyKey, message: authenticated),
            receivedTag
        ) else {
            throw ChaCha20Poly1305TransportProtectionError.integrityCheckFailed
        }

        let plaintext = try Self.chaCha20(
            message: ciphertextBody,
            key: inbound.payloadKey,
            counter: 1,
            nonce: nonce
        )

        guard let paddingLength = plaintext.first, paddingLength >= 4 else {
            throw ChaCha20Poly1305TransportProtectionError.insufficientPadding
        }
        let payloadLength = plaintext.count - 1 - Int(paddingLength)
        guard payloadLength >= 0 else {
            throw ChaCha20Poly1305TransportProtectionError.excessPadding
        }

        pendingInboundSequenceNumber = nil
        nextInboundSequenceNumber = sequenceNumber &+ 1

        // Write the payload over the tail of the slice, then hand back exactly
        // that region. The parser requires the whole slice to be consumed.
        source.moveReaderIndex(to: source.writerIndex - payloadLength)
        source.setBytes(plaintext[1..<(1 + payloadLength)], at: source.readerIndex)

        // Safe to force-unwrap: the reader index was just placed `payloadLength`
        // bytes before the writer index.
        return source.readSlice(length: payloadLength)!
    }

    // MARK: - Outbound

    /// Encrypts `length(4) ‖ padding_length(1) ‖ payload ‖ padding` in place and
    /// appends the 16-byte Poly1305 tag.
    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let readerIndex = destination.readerIndex
        let bodyLength = destination.readableBytes - Self.lengthFieldSize

        let plaintextLengthBytes: [UInt8]
        let plaintextBody: [UInt8]

        do {
            guard bodyLength >= Self.cipherBlockSize,
                  bodyLength % Self.cipherBlockSize == 0,
                  let lengthBytes = destination.getBytes(at: readerIndex, length: Self.lengthFieldSize),
                  let body = destination.getBytes(
                      at: readerIndex + Self.lengthFieldSize,
                      length: bodyLength
                  )
            else {
                throw ChaCha20Poly1305TransportProtectionError.invalidEncryptedPacketLength(
                    readableBytes: destination.readableBytes
                )
            }
            plaintextLengthBytes = lengthBytes
            plaintextBody = body
        }

        let declaredLength = Self.readUInt32(plaintextLengthBytes)
        guard declaredLength == UInt32(bodyLength) else {
            throw ChaCha20Poly1305TransportProtectionError.declaredLengthMismatch(
                declared: declaredLength,
                actual: bodyLength
            )
        }

        let nonce = Self.nonce(for: sequenceNumber)
        let ciphertextLengthBytes = try Self.chaCha20(
            message: plaintextLengthBytes,
            key: outbound.lengthKey,
            counter: 0,
            nonce: nonce
        )
        let polyKey = try Self.polyKey(key: outbound.payloadKey, nonce: nonce)
        let ciphertextBody = try Self.chaCha20(
            message: plaintextBody,
            key: outbound.payloadKey,
            counter: 1,
            nonce: nonce
        )

        var authenticated = [UInt8]()
        authenticated.reserveCapacity(Self.lengthFieldSize + bodyLength)
        authenticated.append(contentsOf: ciphertextLengthBytes)
        authenticated.append(contentsOf: ciphertextBody)

        destination.setBytes(ciphertextLengthBytes, at: readerIndex)
        destination.setBytes(ciphertextBody, at: readerIndex + Self.lengthFieldSize)

        let written = destination.writeBytes(Poly1305.computeTag(key: polyKey, message: authenticated))
        precondition(written == Poly1305.tagByteCount, "Unexpected Poly1305 tag length")
    }

    // MARK: - Primitives

    /// `4 zero bytes ‖ UInt64(sequenceNumber).bigEndian`, which is what makes
    /// `Insecure.ChaCha20CTR`'s RFC 8439 state identical to OpenSSH's.
    static func nonce(for sequenceNumber: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[8] = UInt8(truncatingIfNeeded: sequenceNumber >> 24)
        bytes[9] = UInt8(truncatingIfNeeded: sequenceNumber >> 16)
        bytes[10] = UInt8(truncatingIfNeeded: sequenceNumber >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: sequenceNumber)
        return bytes
    }

    static func chaCha20(
        message: [UInt8],
        key: SymmetricKey,
        counter: UInt32,
        nonce: [UInt8]
    ) throws -> [UInt8] {
        let nonce = try Insecure.ChaCha20CTR.Nonce(data: nonce)
        let counter = try Insecure.ChaCha20CTR.Counter(offset: counter)
        return [UInt8](try Insecure.ChaCha20CTR.encrypt(message, using: key, counter: counter, nonce: nonce))
    }

    /// The Poly1305 one-time key is the first 32 bytes of the payload key's
    /// keystream at counter 0 (RFC 8439 §2.6).
    static func polyKey(key: SymmetricKey, nonce: [UInt8]) throws -> [UInt8] {
        try chaCha20(
            message: [UInt8](repeating: 0, count: polyKeyByteCount),
            key: key,
            counter: 0,
            nonce: nonce
        )
    }

    private static func readUInt32(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    /// The two ChaCha20 keys for one direction, as split by OpenSSH's
    /// `chachapoly_new`.
    struct DirectionalKeys {
        /// `key[0..<32]` — payload keystream and Poly1305 key derivation.
        let payloadKey: SymmetricKey
        /// `key[32..<64]` — length-field keystream only.
        let lengthKey: SymmetricKey

        init(_ key: SymmetricKey) throws {
            let expectedBitCount = ChaCha20Poly1305TransportProtection.keySizes.encryptionKeySize * 8
            guard key.bitCount == expectedBitCount else {
                throw ChaCha20Poly1305TransportProtectionError.invalidEncryptionKeySize(
                    expectedBytes: ChaCha20Poly1305TransportProtection.keySizes.encryptionKeySize,
                    actualBits: key.bitCount
                )
            }

            let bytes = unsafe key.withUnsafeBytes { unsafe [UInt8]($0) }
            payloadKey = SymmetricKey(data: bytes[0..<32])
            lengthKey = SymmetricKey(data: bytes[32..<64])
        }
    }
}
