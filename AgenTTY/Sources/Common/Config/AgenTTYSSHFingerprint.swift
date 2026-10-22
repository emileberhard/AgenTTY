import Foundation
import Crypto

enum AgenTTYSSHFingerprintError: Error {
    case invalidOpenSSHPublicKey
}

enum AgenTTYSSHFingerprint {
    nonisolated static func sha256(fromOpenSSHPublicKey openSSH: String) throws -> String {
        let segments = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard segments.count >= 2,
              let keyData = Data(base64Encoded: String(segments[1])) else {
            throw AgenTTYSSHFingerprintError.invalidOpenSSHPublicKey
        }

        let digest = SHA256.hash(data: keyData)
        let fingerprint = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(fingerprint)"
    }
}
