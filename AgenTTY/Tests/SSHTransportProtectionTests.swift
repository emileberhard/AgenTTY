import Crypto
import Foundation
import NIOCore
import NIOSSH
import XCTest
@testable import AgenTTY_iOS

private typealias Core = AgenTTYAESCTRTransportProtectionCore

final class SSHTransportProtectionTests: XCTestCase {
    // MARK: - Fixtures

    private let allocator = ByteBufferAllocator()

    private func makeKeys(encryptionKeySize: Int, seed: UInt8 = 0) -> NIOSSHSessionKeys {
        func material(_ count: Int, _ tag: UInt8) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) &+ tag &+ seed }
        }

        return NIOSSHSessionKeys(
            initialInboundIV: material(16, 1),
            initialOutboundIV: material(16, 2),
            inboundEncryptionKey: SymmetricKey(data: Data(material(encryptionKeySize, 3))),
            outboundEncryptionKey: SymmetricKey(data: Data(material(encryptionKeySize, 4))),
            inboundMACKey: SymmetricKey(data: Data(material(32, 5))),
            outboundMACKey: SymmetricKey(data: Data(material(32, 6)))
        )
    }

    /// The peer's view of the same session: our outbound direction is its inbound.
    private func mirrored(_ keys: NIOSSHSessionKeys) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: keys.initialOutboundIV,
            initialOutboundIV: keys.initialInboundIV,
            inboundEncryptionKey: keys.outboundEncryptionKey,
            outboundEncryptionKey: keys.inboundEncryptionKey,
            inboundMACKey: keys.outboundMACKey,
            outboundMACKey: keys.inboundMACKey
        )
    }

    /// Mirrors `writeSSHPacket(lengthEncrypted: true, blockSize: 16)`.
    private func makeFramedPacket(payload: [UInt8]) -> ByteBuffer {
        let unpaddedLength = payload.count + 5
        var paddingLength = 16 - (unpaddedLength % 16)
        if paddingLength < 4 {
            paddingLength += 16
        }
        let packetLength = 1 + payload.count + paddingLength

        var buffer = allocator.buffer(capacity: packetLength + 4 + Core.macBytes)
        buffer.writeInteger(UInt32(packetLength))
        buffer.writeInteger(UInt8(paddingLength))
        buffer.writeBytes(payload)
        buffer.writeBytes([UInt8](repeating: 0xAB, count: paddingLength))
        return buffer
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    private func bytes(of buffer: ByteBuffer) -> [UInt8] {
        buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
    }

    /// Runs the exact two-phase sequence `SSHPacketParser` uses.
    @discardableResult
    private func receive(
        _ buffer: inout ByteBuffer,
        with receiver: Core,
        sequenceNumber: UInt32
    ) throws -> [UInt8] {
        try receiver.decryptFirstBlock(&buffer)

        let packetLength = try XCTUnwrap(buffer.getInteger(at: buffer.readerIndex, as: UInt32.self))
        let framedTotal = Int(packetLength) + 4 + Core.macBytes
        var slice = try XCTUnwrap(buffer.readSlice(length: framedTotal))

        let payload = try receiver.decryptAndVerifyRemainingPacket(&slice, sequenceNumber: sequenceNumber)
        XCTAssertEqual(slice.readableBytes, 0, "the parser requires the whole slice to be consumed")
        return bytes(of: payload)
    }

    // MARK: - 5.1 Round trip

    func testRoundTripAES256() throws {
        try assertRoundTrip(encryptionKeySize: 32)
    }

    func testRoundTripAES128() throws {
        try assertRoundTrip(encryptionKeySize: 16)
    }

    private func assertRoundTrip(encryptionKeySize: Int) throws {
        let keys = makeKeys(encryptionKeySize: encryptionKeySize)
        let sender = try Core(initialKeys: keys, expectedEncryptionKeySize: encryptionKeySize)
        let receiver = try Core(initialKeys: mirrored(keys), expectedEncryptionKeySize: encryptionKeySize)

        let payload: [UInt8] = Array("hello agentty transport".utf8)
        var buffer = makeFramedPacket(payload: payload)
        let framedLength = buffer.readableBytes
        let plaintextFrame = bytes(of: buffer)

        try sender.encryptPacket(&buffer, sequenceNumber: 3)
        XCTAssertEqual(buffer.readableBytes, framedLength + Core.macBytes)
        XCTAssertNotEqual(
            Array(bytes(of: buffer).prefix(framedLength)),
            plaintextFrame,
            "ciphertext must differ from plaintext"
        )

        XCTAssertEqual(try receive(&buffer, with: receiver, sequenceNumber: 3), payload)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    // MARK: - 5.2 Multi-packet counter drift

    func testManyPacketsStayKeystreamAligned() throws {
        let keys = makeKeys(encryptionKeySize: 32)
        let sender = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: mirrored(keys), expectedEncryptionKeySize: 32)

        let payloadLengths = [1, 15, 16, 17, 4096]
        var wire = allocator.buffer(capacity: 0)
        var payloads: [[UInt8]] = []

        for sequenceNumber in 0..<20 {
            let length = payloadLengths[sequenceNumber % payloadLengths.count]
            let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0 &+ sequenceNumber) }
            payloads.append(payload)

            var packet = makeFramedPacket(payload: payload)
            try sender.encryptPacket(&packet, sequenceNumber: UInt32(sequenceNumber))
            wire.writeBuffer(&packet)
        }

        for sequenceNumber in 0..<20 {
            XCTAssertEqual(
                try receive(&wire, with: receiver, sequenceNumber: UInt32(sequenceNumber)),
                payloads[sequenceNumber],
                "packet \(sequenceNumber) decrypted incorrectly"
            )
        }
        XCTAssertEqual(wire.readableBytes, 0)
    }

    func testShortReadBetweenFirstBlockAndRemainderStaysAligned() throws {
        let keys = makeKeys(encryptionKeySize: 32)
        let sender = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: mirrored(keys), expectedEncryptionKeySize: 32)

        let payload: [UInt8] = (0..<200).map { UInt8(truncatingIfNeeded: $0) }
        var packet = makeFramedPacket(payload: payload)
        try sender.encryptPacket(&packet, sequenceNumber: 11)
        let wireBytes = bytes(of: packet)

        // Phase one: only the first cipher block has arrived.
        var partial = allocator.buffer(capacity: wireBytes.count)
        partial.writeBytes(wireBytes.prefix(Core.cipherBlockSize))
        try receiver.decryptFirstBlock(&partial)

        let packetLength = try XCTUnwrap(partial.getInteger(at: partial.readerIndex, as: UInt32.self))
        XCTAssertEqual(Int(packetLength) + 4 + Core.macBytes, wireBytes.count)

        // Phase two: the rest arrives and the parser resumes without re-decrypting
        // the first block.
        partial.writeBytes(wireBytes.dropFirst(Core.cipherBlockSize))
        var slice = try XCTUnwrap(partial.readSlice(length: partial.readableBytes))
        let decrypted = try receiver.decryptAndVerifyRemainingPacket(&slice, sequenceNumber: 11)
        XCTAssertEqual(bytes(of: decrypted), payload)
        XCTAssertEqual(slice.readableBytes, 0)

        // A following packet must still line up.
        var next = makeFramedPacket(payload: [0x01, 0x02, 0x03])
        try sender.encryptPacket(&next, sequenceNumber: 12)
        XCTAssertEqual(try receive(&next, with: receiver, sequenceNumber: 12), [0x01, 0x02, 0x03])
    }

    // MARK: - 5.3 Rekey

    func testRekeyResetsCiphersAndMACKeys() throws {
        let keys = makeKeys(encryptionKeySize: 32)
        let sender = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: mirrored(keys), expectedEncryptionKeySize: 32)
        let staleSender = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)

        for sequenceNumber in UInt32(0)..<3 {
            var packet = makeFramedPacket(payload: [UInt8(sequenceNumber)])
            // Keep the stale sender's keystream in lockstep so its later packet is
            // rejected because of the rekey, not because of a counter mismatch.
            var staleCopy = packet
            try sender.encryptPacket(&packet, sequenceNumber: sequenceNumber)
            try staleSender.encryptPacket(&staleCopy, sequenceNumber: sequenceNumber)
            XCTAssertEqual(
                try receive(&packet, with: receiver, sequenceNumber: sequenceNumber),
                [UInt8(sequenceNumber)]
            )
        }

        let rekeyed = makeKeys(encryptionKeySize: 32, seed: 91)
        try sender.updateKeys(rekeyed)
        try receiver.updateKeys(mirrored(rekeyed))

        var freshPacket = makeFramedPacket(payload: Array("after rekey".utf8))
        try sender.encryptPacket(&freshPacket, sequenceNumber: 3)
        XCTAssertEqual(
            try receive(&freshPacket, with: receiver, sequenceNumber: 3),
            Array("after rekey".utf8)
        )

        // A packet still produced under the old key set must not verify.
        var stalePacket = makeFramedPacket(payload: Array("stale".utf8))
        try staleSender.encryptPacket(&stalePacket, sequenceNumber: 4)
        XCTAssertThrowsError(try receive(&stalePacket, with: receiver, sequenceNumber: 4))
    }

    func testChangingOnlyTheMACKeyBreaksVerification() throws {
        let senderKeys = makeKeys(encryptionKeySize: 32)
        var receiverKeys = mirrored(senderKeys)
        receiverKeys.inboundMACKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))

        let sender = try Core(initialKeys: senderKeys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: receiverKeys, expectedEncryptionKeySize: 32)

        var packet = makeFramedPacket(payload: Array("mac key drift".utf8))
        try sender.encryptPacket(&packet, sequenceNumber: 0)

        XCTAssertThrowsError(try receive(&packet, with: receiver, sequenceNumber: 0)) { error in
            XCTAssertEqual(error as? AgenTTYSSHTransportProtectionError, .integrityCheckFailed)
        }
    }

    func testChangingOnlyTheEncryptionKeyBreaksDecryption() throws {
        let senderKeys = makeKeys(encryptionKeySize: 32)
        var receiverKeys = mirrored(senderKeys)
        receiverKeys.inboundEncryptionKey = SymmetricKey(data: Data(repeating: 0x3C, count: 32))

        let sender = try Core(initialKeys: senderKeys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: receiverKeys, expectedEncryptionKeySize: 32)

        var packet = makeFramedPacket(payload: Array("encryption key drift".utf8))
        try sender.encryptPacket(&packet, sequenceNumber: 0)

        XCTAssertThrowsError(try receive(&packet, with: receiver, sequenceNumber: 0))
    }

    // MARK: - 5.4 Tampering

    func testTamperedMACIsRejected() throws {
        var packet = try makeEncryptedPacket(payload: Array("tamper the tag".utf8), sequenceNumber: 2)
        let tagIndex = packet.buffer.writerIndex - Core.macBytes
        flipBit(in: &packet.buffer, at: tagIndex)

        XCTAssertThrowsError(try receive(&packet.buffer, with: packet.receiver, sequenceNumber: 2)) { error in
            XCTAssertEqual(error as? AgenTTYSSHTransportProtectionError, .integrityCheckFailed)
        }
    }

    func testTamperedCiphertextBodyIsRejected() throws {
        var packet = try makeEncryptedPacket(payload: Array("tamper the body".utf8), sequenceNumber: 2)
        flipBit(in: &packet.buffer, at: packet.buffer.readerIndex + Core.cipherBlockSize + 1)

        XCTAssertThrowsError(try receive(&packet.buffer, with: packet.receiver, sequenceNumber: 2)) { error in
            XCTAssertEqual(error as? AgenTTYSSHTransportProtectionError, .integrityCheckFailed)
        }
    }

    /// The first block is decrypted before anything is authenticated, so corruption
    /// there still has to be caught by the MAC.
    func testTamperedFirstBlockPayloadIsRejected() throws {
        var packet = try makeEncryptedPacket(payload: Array("tamper the padding byte".utf8), sequenceNumber: 2)
        flipBit(in: &packet.buffer, at: packet.buffer.readerIndex + 4)

        XCTAssertThrowsError(try receive(&packet.buffer, with: packet.receiver, sequenceNumber: 2)) { error in
            XCTAssertEqual(error as? AgenTTYSSHTransportProtectionError, .integrityCheckFailed)
        }
    }

    func testTamperedLengthFieldIsRejected() throws {
        var packet = try makeEncryptedPacket(payload: Array("tamper the length".utf8), sequenceNumber: 2)
        // Setting the top length bit pushes the decrypted length far past the bound.
        flipBit(in: &packet.buffer, at: packet.buffer.readerIndex, mask: 0x80)

        XCTAssertThrowsError(try packet.receiver.decryptFirstBlock(&packet.buffer)) { error in
            guard case .invalidPacketLength = error as? AgenTTYSSHTransportProtectionError else {
                XCTFail("expected an invalid packet length, got \(error)")
                return
            }
        }
    }

    private func makeEncryptedPacket(
        payload: [UInt8],
        sequenceNumber: UInt32
    ) throws -> (buffer: ByteBuffer, receiver: Core) {
        let keys = makeKeys(encryptionKeySize: 32)
        let sender = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
        let receiver = try Core(initialKeys: mirrored(keys), expectedEncryptionKeySize: 32)

        var buffer = makeFramedPacket(payload: payload)
        try sender.encryptPacket(&buffer, sequenceNumber: sequenceNumber)
        return (buffer, receiver)
    }

    private func flipBit(in buffer: inout ByteBuffer, at index: Int, mask: UInt8 = 0x01) {
        let original = buffer.getInteger(at: index, as: UInt8.self) ?? 0
        buffer.setInteger(original ^ mask, at: index, as: UInt8.self)
    }

    // MARK: - 5.5 Length-field guards

    func testDecryptFirstBlockRejectsOutOfRangeLengths() throws {
        let keys = makeKeys(encryptionKeySize: 32)
        let receiver = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
        // Matches the receiver's inbound keystream so a chosen plaintext block can
        // be delivered exactly once per iteration.
        let peer = try AgenTTYAESCTRCipher(
            key: keys.inboundEncryptionKey,
            initialCounterBlock: keys.initialInboundIV
        )

        for badLength: UInt32 in [0, 11, 13, 300_000] {
            var block = bigEndianBytes(badLength)
            block.append(contentsOf: [UInt8](repeating: 0, count: 12))
            let ciphertext = try peer.apply(to: block)

            var buffer = allocator.buffer(capacity: Core.cipherBlockSize)
            buffer.writeBytes(ciphertext)

            XCTAssertThrowsError(try receiver.decryptFirstBlock(&buffer)) { error in
                XCTAssertEqual(
                    error as? AgenTTYSSHTransportProtectionError,
                    .invalidPacketLength(badLength),
                    "length \(badLength) must be rejected"
                )
            }
        }
    }

    func testDecryptFirstBlockAcceptsMinimumAndMaximumLengths() throws {
        for acceptedLength: UInt32 in [12, 262_140] {
            let keys = makeKeys(encryptionKeySize: 32)
            let receiver = try Core(initialKeys: keys, expectedEncryptionKeySize: 32)
            let peer = try AgenTTYAESCTRCipher(
                key: keys.inboundEncryptionKey,
                initialCounterBlock: keys.initialInboundIV
            )

            var block = bigEndianBytes(acceptedLength)
            block.append(contentsOf: [UInt8](repeating: 0, count: 12))
            let ciphertext = try peer.apply(to: block)

            var buffer = allocator.buffer(capacity: Core.cipherBlockSize)
            buffer.writeBytes(ciphertext)
            XCTAssertNoThrow(try receiver.decryptFirstBlock(&buffer))
        }
    }

    // MARK: - 5.6 Sequence-number binding

    func testMACIsBoundToTheSequenceNumber() throws {
        var packet = try makeEncryptedPacket(payload: Array("bound to seq".utf8), sequenceNumber: 7)

        XCTAssertThrowsError(try receive(&packet.buffer, with: packet.receiver, sequenceNumber: 8)) { error in
            XCTAssertEqual(error as? AgenTTYSSHTransportProtectionError, .integrityCheckFailed)
        }
    }

    // MARK: - 5.7 Known-answer vectors

    /// NIST SP 800-38A F.5.5 / F.5.6, CTR-AES256. The four plaintext blocks are fed
    /// across two calls so the derived counter block is proven to advance correctly
    /// between calls, which is exactly what the split first-block/remainder path needs.
    func testNISTAES256CTRKnownAnswerVectorAcrossTwoCalls() throws {
        let key = SymmetricKey(
            data: Data(hexBytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"))
        )
        let counterBlock = hexBytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let cipher = try AgenTTYAESCTRCipher(key: key, initialCounterBlock: counterBlock)

        let firstBlock = hexBytes("6bc1bee22e409f96e93d7e117393172a")
        let remainingBlocks = hexBytes(
            "ae2d8a571e03ac9c9eb76fac45af8e51"
                + "30c81c46a35ce411e5fbc1191a0a52ef"
                + "f69f2445df4f9b17ad2b417be66c3710"
        )

        let firstCiphertext = try cipher.apply(to: firstBlock)
        XCTAssertEqual(Array(firstCiphertext), hexBytes("601ec313775789a5b7a7f504bbf3d228"))

        let remainingCiphertext = try cipher.apply(to: remainingBlocks)
        XCTAssertEqual(
            Array(remainingCiphertext),
            hexBytes(
                "f443e3ca4d62b59aca84e990cacaf5c5"
                    + "2b0930daa23de94ce87017ba2d84988d"
                    + "dfc9c58db67aada613c2dd08457941a6"
            )
        )
    }

    func testCounterBlockAdvancesBigEndianAcrossByteBoundaries() {
        let base = hexBytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

        XCTAssertEqual(AgenTTYAESCTRCipher.counterBlock(base: base, advancedBy: 0), base)
        XCTAssertEqual(
            AgenTTYAESCTRCipher.counterBlock(base: base, advancedBy: 1),
            hexBytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdff00")
        )
        XCTAssertEqual(
            AgenTTYAESCTRCipher.counterBlock(base: base, advancedBy: 3),
            hexBytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdff02")
        )
        XCTAssertEqual(
            AgenTTYAESCTRCipher.counterBlock(
                base: hexBytes("000000000000000000000000ffffffff"),
                advancedBy: 1
            ),
            hexBytes("00000000000000000000000100000000")
        )
    }

    /// RFC 4231 test case 2, which also exercises `constantTimeEquals`.
    func testRFC4231HMACSHA256Vector() {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: Data("Jefe".utf8)))
        mac.update(data: Data("what do ya want for nothing?".utf8))
        let code = mac.finalize()

        let expected = hexBytes("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertTrue(Core.constantTimeEquals(code, expected))
        XCTAssertFalse(Core.constantTimeEquals(code, Array(expected.dropLast())))

        var tampered = expected
        tampered[31] ^= 0x01
        XCTAssertFalse(Core.constantTimeEquals(code, tampered))
    }

    func testSequenceNumberBytesAreBigEndian() {
        XCTAssertEqual(Core.sequenceNumberBytes(0x0102_0304), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(Core.sequenceNumberBytes(0), [0, 0, 0, 0])
        XCTAssertEqual(Core.sequenceNumberBytes(.max), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    // MARK: - 5.8 Scheme registration

    func testClientSchemesKeepGCMFirstAndAddCTRTail() {
        let schemes = AgenTTYSSHTransportProtectionSchemes.clientSchemes()
        XCTAssertEqual(schemes.count, 5)
        XCTAssertEqual(
            schemes.map { $0.cipherName },
            [
                "aes256-gcm@openssh.com",
                "aes128-gcm@openssh.com",
                "chacha20-poly1305@openssh.com",
                "aes256-ctr",
                "aes128-ctr",
            ]
        )

        for scheme in schemes.suffix(2) {
            XCTAssertEqual(scheme.macName, "hmac-sha2-256")
            XCTAssertEqual(scheme.cipherBlockSize, 16)
            XCTAssertEqual(scheme.keySizes.ivSize, 16)
            XCTAssertEqual(scheme.keySizes.macKeySize, 32)
        }

        XCTAssertEqual(AgenTTYAES256CTRTransportProtection.keySizes.encryptionKeySize, 32)
        XCTAssertEqual(AgenTTYAES128CTRTransportProtection.keySizes.encryptionKeySize, 16)

        let keys256 = makeKeys(encryptionKeySize: 32)
        let scheme256 = try? AgenTTYAES256CTRTransportProtection(initialKeys: keys256)
        XCTAssertEqual(scheme256?.macBytes, 32)
        XCTAssertEqual(scheme256?.lengthEncrypted, true)

        let keys128 = makeKeys(encryptionKeySize: 16)
        let scheme128 = try? AgenTTYAES128CTRTransportProtection(initialKeys: keys128)
        XCTAssertEqual(scheme128?.macBytes, 32)
        XCTAssertEqual(scheme128?.lengthEncrypted, true)
    }

    func testSchemeRejectsWrongEncryptionKeySize() {
        XCTAssertThrowsError(
            try AgenTTYAES256CTRTransportProtection(initialKeys: makeKeys(encryptionKeySize: 16))
        ) { error in
            XCTAssertEqual(
                error as? AgenTTYSSHTransportProtectionError,
                .invalidEncryptionKeySize(expectedBytes: 32, actualBits: 128)
            )
        }
    }

    // MARK: - 5.9 Key-exchange failure classification

    func testAlgorithmNegotiationFailureIsClassifiedAsPermanent() {
        XCTAssertTrue(
            AgenTTYSSHTransportFailureClassifier.isAlgorithmNegotiationFailure(.keyExchangeNegotiationFailure)
        )
        XCTAssertFalse(
            AgenTTYSSHTransportFailureClassifier.isAlgorithmNegotiationFailure(.invalidOpenSSHPublicKey)
        )

        let outcome = AgenTTYSSHTransportFailureClassifier.algorithmNegotiationOutcome
        XCTAssertEqual(outcome.category, .algorithmNegotiationFailed)
        XCTAssertEqual(outcome.failureStage, .transport)
        XCTAssertFalse(outcome.wasReady)
        XCTAssertFalse(outcome.shouldReconnect)
    }

    func testUnrelatedErrorsAreNotClassifiedAsNegotiationFailures() {
        XCTAssertNil(
            AgenTTYSSHTransportFailureClassifier.outcome(
                for: NSError(domain: "test", code: 1)
            )
        )

        XCTAssertThrowsError(try NIOSSHPublicKey(openSSHPublicKey: "definitely-not-a-key")) { error in
            XCTAssertNil(AgenTTYSSHTransportFailureClassifier.outcome(for: error))
            XCTAssertFalse(SSHClientSession.containsPermanentConnectFailure(error))
        }
    }

    func testAlgorithmNegotiationOutcomeGetsDedicatedRecoveryGuidance() {
        let guidance = AgenTTYSSHRecoveryGuidance.guidance(
            for: AgenTTYSSHTransportFailureClassifier.algorithmNegotiationOutcome
        )

        XCTAssertEqual(guidance.title, "No Shared Encryption Method")
        XCTAssertTrue(guidance.message.contains("aes256-ctr"))
        XCTAssertTrue(guidance.message.contains("chacha20-poly1305@openssh.com"))
        XCTAssertTrue(guidance.suggestions.contains { $0.subtitle.contains("aes-ctr") })
    }

    func testNegotiationRecoveryCardsAreComponentSpecific() {
        let hostKeyOutcome = AgenTTYSSHTerminationOutcome(
            category: .algorithmNegotiationFailed,
            failureStage: .transport,
            rawReason: "no shared SSH host key algorithm with this host",
            wasReady: false,
            shouldReconnect: false,
            negotiationDetail: AgenTTYSSHNegotiationFailureDetail(
                component: .hostKey,
                localAlgorithms: ["ssh-ed25519", "rsa-sha2-512"],
                remoteAlgorithms: ["ssh-dss"]
            )
        )
        let hostKeyGuidance = AgenTTYSSHRecoveryGuidance.guidance(for: hostKeyOutcome)
        XCTAssertEqual(hostKeyGuidance.title, "No Shared Host Key Type")
        XCTAssertTrue(hostKeyGuidance.message.contains("This host offers: ssh-dss."))

        let kexOutcome = AgenTTYSSHTerminationOutcome(
            category: .algorithmNegotiationFailed,
            failureStage: .transport,
            rawReason: "no shared SSH key exchange algorithm with this host",
            wasReady: false,
            shouldReconnect: false,
            negotiationDetail: AgenTTYSSHNegotiationFailureDetail(
                component: .keyExchange,
                localAlgorithms: ["curve25519-sha256"],
                remoteAlgorithms: ["diffie-hellman-group14-sha1"]
            )
        )
        XCTAssertEqual(
            AgenTTYSSHRecoveryGuidance.guidance(for: kexOutcome).title,
            "No Shared Key Exchange Method"
        )

        let macOutcome = AgenTTYSSHTerminationOutcome(
            category: .algorithmNegotiationFailed,
            failureStage: .transport,
            rawReason: "no shared SSH message authentication algorithm with this host",
            wasReady: false,
            shouldReconnect: false,
            negotiationDetail: AgenTTYSSHNegotiationFailureDetail(
                component: .mac,
                localAlgorithms: ["hmac-sha2-256"],
                remoteAlgorithms: ["hmac-md5"]
            )
        )
        XCTAssertEqual(
            AgenTTYSSHRecoveryGuidance.guidance(for: macOutcome).title,
            "No Shared Message Authentication"
        )
    }

    func testForkComponentsCollapseOntoUserMeaningfulOnes() {
        XCTAssertEqual(AgenTTYSSHNegotiationFailureDetail.Component(.transportProtection), .encryption)
        XCTAssertEqual(AgenTTYSSHNegotiationFailureDetail.Component(.asymmetricNegotiation), .encryption)
        XCTAssertEqual(AgenTTYSSHNegotiationFailureDetail.Component(.hostKey), .hostKey)
        XCTAssertEqual(AgenTTYSSHNegotiationFailureDetail.Component(.keyExchange), .keyExchange)
        XCTAssertEqual(AgenTTYSSHNegotiationFailureDetail.Component(.mac), .mac)
    }

    func testAlgorithmNegotiationFailureCountsTowardCircuitBreaker() {
        XCTAssertTrue(AgenTTYPreReadyFailureCircuitBreaker.countsTowardTrip(.algorithmNegotiationFailed))
        XCTAssertEqual(AgenTTYSSHDisconnectCategory.algorithmNegotiationFailed.analyticsValue, .other)
    }

    // MARK: - Helpers

    private func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }

        return bytes
    }
}
