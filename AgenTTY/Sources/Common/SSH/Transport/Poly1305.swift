import Foundation

/// RFC 8439 §2.5 Poly1305 one-time authenticator.
///
/// `Crypto.ChaChaPoly` cannot be reused for `chacha20-poly1305@openssh.com`:
/// OpenSSH authenticates the raw `encryptedLength ‖ encryptedPayload`
/// concatenation with no RFC 8439 AAD/length framing, so the bare primitive is
/// required.
///
/// The accumulator is the classic five-limb, 26-bits-per-limb representation
/// (`poly1305-donna`), held in `UInt64` so no intermediate product can overflow.
/// Every operation is arithmetic or bitwise: there is no branch, table lookup,
/// or early exit that depends on the key, the accumulator, or the tag.
nonisolated struct Poly1305 {
    static let keyByteCount = 32
    static let tagByteCount = 16

    private static let blockByteCount = 16
    private static let limbMask: UInt64 = 0x3ff_ffff

    /// Clamped `r`, split into five 26-bit limbs (RFC 8439 §2.5.1).
    private let r0: UInt64
    private let r1: UInt64
    private let r2: UInt64
    private let r3: UInt64
    private let r4: UInt64

    /// `5 * r[n]`, precomputed for the reduction step.
    private let s1: UInt64
    private let s2: UInt64
    private let s3: UInt64
    private let s4: UInt64

    /// `s` from the key, as four little-endian 32-bit words, added at the end.
    private let pad0: UInt64
    private let pad1: UInt64
    private let pad2: UInt64
    private let pad3: UInt64

    private var h0: UInt64 = 0
    private var h1: UInt64 = 0
    private var h2: UInt64 = 0
    private var h3: UInt64 = 0
    private var h4: UInt64 = 0

    private var partialBlock = [UInt8](repeating: 0, count: Poly1305.blockByteCount)
    private var partialBlockCount = 0

    /// - Precondition: `key` is exactly ``keyByteCount`` bytes. The key is always
    ///   produced by our own ChaCha20 derivation, never by a remote peer, so a
    ///   wrong length is a programming error rather than a protocol failure.
    init(key: [UInt8]) {
        precondition(key.count == Poly1305.keyByteCount, "Poly1305 requires a 32-byte one-time key")

        let t0 = Poly1305.loadLittleEndian32(key, 0)
        let t1 = Poly1305.loadLittleEndian32(key, 4)
        let t2 = Poly1305.loadLittleEndian32(key, 8)
        let t3 = Poly1305.loadLittleEndian32(key, 12)

        // Splitting into 26-bit limbs and clamping `r` to
        // 0x0ffffffc0ffffffc0ffffffc0fffffff are folded into one masking step.
        r0 = t0 & 0x3ff_ffff
        r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ff_ff03
        r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ff_c0ff
        r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f0_3fff
        r4 = (t3 >> 8) & 0x00f_ffff

        s1 = r1 &* 5
        s2 = r2 &* 5
        s3 = r3 &* 5
        s4 = r4 &* 5

        pad0 = Poly1305.loadLittleEndian32(key, 16)
        pad1 = Poly1305.loadLittleEndian32(key, 20)
        pad2 = Poly1305.loadLittleEndian32(key, 24)
        pad3 = Poly1305.loadLittleEndian32(key, 28)
    }

    /// Authenticates `message` under `key` in one call.
    static func computeTag(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var authenticator = Poly1305(key: key)
        authenticator.update(message)
        return authenticator.finalize()
    }

    /// Compares two tags without leaking where they first differ.
    ///
    /// The length check is on public framing data (the tag width is fixed by the
    /// cipher), not on secret content.
    static func constantTimeEquals<Left: Collection, Right: Collection>(
        _ left: Left,
        _ right: Right
    ) -> Bool where Left.Element == UInt8, Right.Element == UInt8 {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    mutating func update(_ bytes: [UInt8]) {
        var index = bytes.startIndex

        // Top up a partially filled block first.
        if partialBlockCount > 0 {
            let wanted = min(Poly1305.blockByteCount - partialBlockCount, bytes.count)
            for offset in 0..<wanted {
                partialBlock[partialBlockCount + offset] = bytes[index + offset]
            }
            partialBlockCount += wanted
            index += wanted

            // Still short of a block, which means `bytes` is exhausted.
            guard partialBlockCount == Poly1305.blockByteCount else { return }

            accumulate(partialBlock, at: 0, isFinalBlock: false)
            partialBlockCount = 0
        }

        // Whole blocks are consumed straight out of the caller's array.
        while bytes.endIndex - index >= Poly1305.blockByteCount {
            accumulate(bytes, at: index, isFinalBlock: false)
            index += Poly1305.blockByteCount
        }

        // Whatever is left starts the next partial block.
        let remaining = bytes.endIndex - index
        for offset in 0..<remaining {
            partialBlock[offset] = bytes[index + offset]
        }
        partialBlockCount = remaining
    }

    mutating func finalize() -> [UInt8] {
        if partialBlockCount > 0 {
            // RFC 8439 §2.5.1: the final short block is terminated by a 0x01 byte
            // instead of the implicit high bit, then zero-padded.
            partialBlock[partialBlockCount] = 1
            for index in (partialBlockCount + 1)..<Poly1305.blockByteCount {
                partialBlock[index] = 0
            }
            accumulate(partialBlock, at: 0, isFinalBlock: true)
            partialBlockCount = 0
        }

        // Fully carry the accumulator.
        var carry = h1 >> 26
        h1 &= Poly1305.limbMask
        h2 &+= carry
        carry = h2 >> 26
        h2 &= Poly1305.limbMask
        h3 &+= carry
        carry = h3 >> 26
        h3 &= Poly1305.limbMask
        h4 &+= carry
        carry = h4 >> 26
        h4 &= Poly1305.limbMask
        h0 &+= carry &* 5
        carry = h0 >> 26
        h0 &= Poly1305.limbMask
        h1 &+= carry

        // g = h + 5 - 2^130, i.e. h - p. The borrow out of the top limb tells us
        // whether h was already reduced.
        var g0 = h0 &+ 5
        carry = g0 >> 26
        g0 &= Poly1305.limbMask
        var g1 = h1 &+ carry
        carry = g1 >> 26
        g1 &= Poly1305.limbMask
        var g2 = h2 &+ carry
        carry = g2 >> 26
        g2 &= Poly1305.limbMask
        var g3 = h3 &+ carry
        carry = g3 >> 26
        g3 &= Poly1305.limbMask
        var g4 = h4 &+ carry &- (1 << 26)

        // Branchless select: borrow (h < p) keeps h, no borrow takes g.
        var mask = (g4 >> 63) &- 1
        g0 &= mask
        g1 &= mask
        g2 &= mask
        g3 &= mask
        g4 &= mask
        mask = ~mask
        h0 = (h0 & mask) | g0
        h1 = (h1 & mask) | g1
        h2 = (h2 & mask) | g2
        h3 = (h3 & mask) | g3
        h4 = (h4 & mask) | g4

        // Repack the 26-bit limbs into four 32-bit words (h mod 2^128).
        h0 = (h0 | (h1 << 26)) & 0xffff_ffff
        h1 = ((h1 >> 6) | (h2 << 20)) & 0xffff_ffff
        h2 = ((h2 >> 12) | (h3 << 14)) & 0xffff_ffff
        h3 = ((h3 >> 18) | (h4 << 8)) & 0xffff_ffff

        // tag = (h + s) mod 2^128
        var wide = h0 &+ pad0
        h0 = wide & 0xffff_ffff
        wide = h1 &+ pad1 &+ (wide >> 32)
        h1 = wide & 0xffff_ffff
        wide = h2 &+ pad2 &+ (wide >> 32)
        h2 = wide & 0xffff_ffff
        wide = h3 &+ pad3 &+ (wide >> 32)
        h3 = wide & 0xffff_ffff

        var tag = [UInt8](repeating: 0, count: Poly1305.tagByteCount)
        Poly1305.storeLittleEndian32(h0, into: &tag, at: 0)
        Poly1305.storeLittleEndian32(h1, into: &tag, at: 4)
        Poly1305.storeLittleEndian32(h2, into: &tag, at: 8)
        Poly1305.storeLittleEndian32(h3, into: &tag, at: 12)
        return tag
    }

    /// h = (h + block) * r mod 2^130 - 5, with a partial carry chain.
    private mutating func accumulate(_ bytes: [UInt8], at offset: Int, isFinalBlock: Bool) {
        // Every full block carries an implicit 1 bit above its 128 bits; the
        // padded final block already has its 0x01 terminator inside the data.
        let highBit: UInt64 = isFinalBlock ? 0 : (1 << 24)

        h0 &+= Poly1305.loadLittleEndian32(bytes, offset) & Poly1305.limbMask
        h1 &+= (Poly1305.loadLittleEndian32(bytes, offset + 3) >> 2) & Poly1305.limbMask
        h2 &+= (Poly1305.loadLittleEndian32(bytes, offset + 6) >> 4) & Poly1305.limbMask
        h3 &+= (Poly1305.loadLittleEndian32(bytes, offset + 9) >> 6) & Poly1305.limbMask
        h4 &+= (Poly1305.loadLittleEndian32(bytes, offset + 12) >> 8) | highBit

        // Each product is at most ~2^56, so UInt64 cannot overflow here.
        let d0 = h0 &* r0 &+ h1 &* s4 &+ h2 &* s3 &+ h3 &* s2 &+ h4 &* s1
        let d1 = h0 &* r1 &+ h1 &* r0 &+ h2 &* s4 &+ h3 &* s3 &+ h4 &* s2
        let d2 = h0 &* r2 &+ h1 &* r1 &+ h2 &* r0 &+ h3 &* s4 &+ h4 &* s3
        let d3 = h0 &* r3 &+ h1 &* r2 &+ h2 &* r1 &+ h3 &* r0 &+ h4 &* s4
        let d4 = h0 &* r4 &+ h1 &* r3 &+ h2 &* r2 &+ h3 &* r1 &+ h4 &* r0

        var carry = d0 >> 26
        h0 = d0 & Poly1305.limbMask
        var wide = d1 &+ carry
        carry = wide >> 26
        h1 = wide & Poly1305.limbMask
        wide = d2 &+ carry
        carry = wide >> 26
        h2 = wide & Poly1305.limbMask
        wide = d3 &+ carry
        carry = wide >> 26
        h3 = wide & Poly1305.limbMask
        wide = d4 &+ carry
        carry = wide >> 26
        h4 = wide & Poly1305.limbMask
        h0 &+= carry &* 5
        carry = h0 >> 26
        h0 &= Poly1305.limbMask
        h1 &+= carry
    }

    private static func loadLittleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 24)
    }

    private static func storeLittleEndian32(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
