import Foundation
import NIOSSH

nonisolated enum AgenTTYSSHTransportProtectionSchemes {
    /// The advertised cipher list, in client preference order. NIOSSH negotiates
    /// client-order-first, so the bundled AES-GCM schemes stay in front and existing
    /// hosts keep negotiating exactly what they do today; the classic RFC 4253
    /// encrypt-and-MAC CTR schemes are the compatibility tail for Dropbear-class
    /// servers that offer nothing else.
    ///
    /// This is a function rather than a stored value because
    /// `[NIOSSHTransportProtection.Type]` is an existential-metatype array; building
    /// it inside the `@Sendable` channel initializer avoids capturing a global.
    static func clientSchemes() -> [NIOSSHTransportProtection.Type] {
        // The assignment performs the covariant upcast from the bundled array's
        // `(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type` element type.
        var schemes: [NIOSSHTransportProtection.Type] = Constants.bundledTransportProtectionSchemes
        // Appends are individual because an array literal of differing metatypes
        // infers `[Any]`. ChaCha requires the fork's 64-byte key expansion and
        // sequence-number-aware length decryption; both are in the pinned revision.
        schemes.append(ChaCha20Poly1305TransportProtection.self)
        schemes.append(AgenTTYAES256CTRTransportProtection.self)
        schemes.append(AgenTTYAES128CTRTransportProtection.self)
        return schemes
    }
}
