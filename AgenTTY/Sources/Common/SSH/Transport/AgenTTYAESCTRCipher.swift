import Crypto
import Foundation
import _CryptoExtras

/// One AES-CTR keystream for one direction of an SSH transport.
///
/// `AES._CTR` is stateless and seekable, so the keystream position is tracked here
/// as a count of consumed 16-byte blocks and the counter block for each call is
/// derived from the initial counter block. That is what lets a single packet be
/// processed in two steps (length block, then remainder) without the two steps
/// drifting apart. Every chunk AgenTTY feeds through this type is block aligned,
/// which keeps the derivation exact.
///
/// A single instance is not safe for concurrent use; NIOSSH confines the packet
/// parser and serializer to the channel's event loop, and the inbound and outbound
/// directions use separate instances.
nonisolated final class AgenTTYAESCTRCipher {
    static let counterBlockSize = 16

    private var key: SymmetricKey
    private var initialCounterBlock: [UInt8]
    private var blocksConsumed: UInt64

    init(key: SymmetricKey, initialCounterBlock: [UInt8]) throws {
        guard initialCounterBlock.count == Self.counterBlockSize else {
            throw AgenTTYSSHTransportProtectionError.invalidInitialCounterBlockLength(
                expected: Self.counterBlockSize,
                actual: initialCounterBlock.count
            )
        }

        self.key = key
        self.initialCounterBlock = initialCounterBlock
        blocksConsumed = 0
    }

    /// A rekey restarts the keystream completely: new key, new initial counter
    /// block, and no residual block offset carried over from the previous epoch.
    func reset(key: SymmetricKey, initialCounterBlock: [UInt8]) throws {
        guard initialCounterBlock.count == Self.counterBlockSize else {
            throw AgenTTYSSHTransportProtectionError.invalidInitialCounterBlockLength(
                expected: Self.counterBlockSize,
                actual: initialCounterBlock.count
            )
        }

        self.key = key
        self.initialCounterBlock = initialCounterBlock
        blocksConsumed = 0
    }

    /// CTR encryption and decryption are the same XOR against the keystream, so a
    /// single entry point serves both directions.
    func apply(to bytes: [UInt8]) throws -> Data {
        guard !bytes.isEmpty else { return Data() }
        guard bytes.count % Self.counterBlockSize == 0 else {
            throw AgenTTYSSHTransportProtectionError.unalignedCipherChunk(byteCount: bytes.count)
        }

        let nonce = try AES._CTR.Nonce(
            nonceBytes: Self.counterBlock(base: initialCounterBlock, advancedBy: blocksConsumed)
        )
        let transformed = try AES._CTR.encrypt(bytes, using: key, nonce: nonce)
        guard transformed.count == bytes.count else {
            throw AgenTTYSSHTransportProtectionError.cipherOutputLengthMismatch(
                expected: bytes.count,
                actual: transformed.count
            )
        }

        blocksConsumed &+= UInt64(bytes.count / Self.counterBlockSize)
        return transformed
    }

    /// RFC 4344 §4: the 16-byte counter block is a big-endian integer that advances
    /// by one per encrypted block. Overflow past the top byte wraps, matching the
    /// underlying `AES_ctr128` behavior.
    static func counterBlock(base: [UInt8], advancedBy blocks: UInt64) -> [UInt8] {
        var block = base
        var carry = blocks
        var index = block.count - 1

        while index >= 0, carry > 0 {
            let sum = UInt64(block[index]) + (carry & 0xFF)
            block[index] = UInt8(truncatingIfNeeded: sum)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }

        return block
    }
}
