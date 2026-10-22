import Foundation

/// `NIOSSHError` has no public initializer, so AgenTTY's own transport protection
/// schemes throw this instead. NIOSSH propagates any `Error` thrown from
/// `NIOSSHTransportProtection` up through the packet parser to `fireErrorCaught`,
/// which is where `AgenTTYSSHTransportFailureClassifier` picks failures up.
nonisolated enum AgenTTYSSHTransportProtectionError: Error, Equatable {
    case invalidEncryptionKeySize(expectedBytes: Int, actualBits: Int)
    case invalidInitialCounterBlockLength(expected: Int, actual: Int)
    case unalignedCipherChunk(byteCount: Int)
    case cipherOutputLengthMismatch(expected: Int, actual: Int)
    case invalidEncryptedPacketLength(readableBytes: Int)
    case invalidPacketLength(UInt32)
    case insufficientPadding
    case excessPadding
    case integrityCheckFailed
}
