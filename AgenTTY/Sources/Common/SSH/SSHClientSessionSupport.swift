import Foundation
import NIOCore
import NIOSSH

nonisolated enum AgenTTYSSHTransportFailureClassifier {
    /// NIOSSH reports an unusable cipher/MAC/key-exchange cross-product as
    /// `keyExchangeNegotiationFailure`. Reconnecting cannot fix it, so it has to
    /// reach the user instead of feeding the silent reconnect backoff loop.
    static let algorithmNegotiationOutcome = AgenTTYSSHTerminationOutcome(
        category: .algorithmNegotiationFailed,
        failureStage: .transport,
        rawReason: "no shared SSH algorithm with this host",
        wasReady: false,
        shouldReconnect: false
    )

    static func outcome(for error: Error) -> AgenTTYSSHTerminationOutcome? {
        guard let sshError = negotiationFailureError(in: error) else { return nil }

        guard let failure = sshError.negotiationFailure else {
            return algorithmNegotiationOutcome
        }
        let component = AgenTTYSSHNegotiationFailureDetail.Component(failure.component)

        return AgenTTYSSHTerminationOutcome(
            category: .algorithmNegotiationFailed,
            failureStage: .transport,
            rawReason: "no shared SSH \(componentRawReasonNoun(component)) algorithm with this host",
            wasReady: false,
            shouldReconnect: false,
            negotiationDetail: AgenTTYSSHNegotiationFailureDetail(
                component: component,
                localAlgorithms: failure.localAlgorithms,
                remoteAlgorithms: failure.remoteAlgorithms
            )
        )
    }

    private static func componentRawReasonNoun(
        _ component: AgenTTYSSHNegotiationFailureDetail.Component
    ) -> String {
        switch component {
        case .keyExchange: "key exchange"
        case .hostKey: "host key"
        case .encryption: "encryption"
        case .mac: "message authentication"
        }
    }

    private static func negotiationFailureError(in error: Error) -> NIOSSHError? {
        if let sshError = error as? NIOSSHError, isAlgorithmNegotiationFailure(sshError.type) {
            return sshError
        }

        let userInfo = (error as NSError).userInfo
        for value in userInfo.values {
            if let nestedError = value as? Error,
               let sshError = negotiationFailureError(in: nestedError) {
                return sshError
            }
        }

        return nil
    }
}

nonisolated extension AgenTTYSSHNegotiationFailureDetail.Component {
    /// The fork's fine-grained components collapse onto the four user-meaningful ones:
    /// `transportProtection` (an agreed cipher/MAC pair with no registered scheme) and
    /// `asymmetricNegotiation` (per-direction disagreement) are both cipher-level
    /// problems from the user's point of view.
    init(_ component: NIOSSHError.NegotiationFailure.Component) {
        switch component {
        case .keyExchange:
            self = .keyExchange
        case .hostKey:
            self = .hostKey
        case .encryption, .transportProtection, .asymmetricNegotiation:
            self = .encryption
        case .mac:
            self = .mac
        }
    }
}

nonisolated extension AgenTTYSSHTransportFailureClassifier {
    /// Every unusable kex/cipher/MAC cross-product arrives as this one error type
    /// with no publicly readable diagnostics, so the type is the whole signal.
    static func isAlgorithmNegotiationFailure(_ errorType: NIOSSHError.ErrorType) -> Bool {
        errorType == .keyExchangeNegotiationFailure
    }

    static func containsAlgorithmNegotiationFailure(_ error: Error) -> Bool {
        if let sshError = error as? NIOSSHError, isAlgorithmNegotiationFailure(sshError.type) {
            return true
        }

        let userInfo = (error as NSError).userInfo
        for value in userInfo.values {
            if let nestedError = value as? Error,
               containsAlgorithmNegotiationFailure(nestedError) {
                return true
            }
        }

        return false
    }
}

extension SSHClientSession {
    nonisolated static func logPreview(of data: Data, maxBytes: Int = 80) -> String {
        let limited = data.prefix(maxBytes)
        let text = String(decoding: limited, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        if data.count > maxBytes {
            return "\(text)…"
        }
        return text
    }
    nonisolated static func tmuxDictationInsertCommand(for text: String) -> String {
        let encodedText = Data(text.utf8).base64EncodedString()
        let encodedTextLiteral = shellSingleQuoted(encodedText)
        let target = AgenTTYConnection.tmuxSessionName
        let tmuxCommand = AgenTTYHostRuntime.tmuxWrapperShellLiteral
        return """
set -e
\(tmuxCommand) has-session -t \(target)
\(tmuxCommand) if-shell -F -t \(target) '#{pane_in_mode}' 'send-keys -X -t \(target) cancel' ''
printf %s \(encodedTextLiteral) | { base64 --decode 2>/dev/null || base64 -d 2>/dev/null || base64 -D; } | \(tmuxCommand) load-buffer -
\(tmuxCommand) paste-buffer -p -d -t \(target)
"""
    }
    nonisolated static func remoteFileWriteCommand(
        for remotePath: String,
        executable: Bool,
        expectedByteCount: Int,
        expectedSHA256: String? = nil
    ) -> String {
        let safeExpectedByteCount = max(expectedByteCount, 0)
        let chmodCommand = executable ? "chmod 700 \"$tmp_path\"" : "chmod 600 \"$tmp_path\""
        let checksumCommand: String
        if let expectedSHA256 {
            checksumCommand = """
            expected_sha256=\(shellSingleQuoted(expectedSHA256.lowercased()))
            if command -v sha256sum >/dev/null 2>&1; then
              actual_sha256="$(sha256sum "$tmp_path")"
            elif command -v shasum >/dev/null 2>&1; then
              actual_sha256="$(shasum -a 256 "$tmp_path")"
            else
              printf 'No SHA-256 utility is available.\\n' >&2
              exit 1
            fi
            actual_sha256="${actual_sha256%% *}"
            if [ "$actual_sha256" != "$expected_sha256" ]; then
              printf 'SHA-256 mismatch for %s.\\n' "$target_path" >&2
              exit 1
            fi
            """
        } else {
            checksumCommand = ""
        }
        return """
set -e
umask 077
target_path=\(remotePath)
mkdir -p "$(dirname "$target_path")"
tmp_path="${target_path}.part.$$"
cleanup() {
  rm -f "$tmp_path"
}
trap cleanup 0 1 2 15
cat > "$tmp_path"
actual_byte_count="$(wc -c < "$tmp_path" | tr -d '[:space:]')"
if [ "$actual_byte_count" != "\(safeExpectedByteCount)" ]; then
  printf 'Byte-count mismatch for %s: expected %s, received %s.\\n' "$target_path" "\(safeExpectedByteCount)" "$actual_byte_count" >&2
  exit 1
fi
\(checksumCommand)
\(chmodCommand)
mv -f "$tmp_path" "$target_path"
trap - 0 1 2 15
"""
    }
    nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
    nonisolated static func containsPermanentConnectFailure(_ error: Error) -> Bool {
        if error is AgenTTYTrustedHostKeyValidationError ||
            error is AgenTTYSSHAuthenticationError {
            return true
        }

        if AgenTTYSSHTransportFailureClassifier.containsAlgorithmNegotiationFailure(error) {
            return true
        }

        let userInfo = (error as NSError).userInfo
        for value in userInfo.values {
            if let nestedError = value as? Error,
               containsPermanentConnectFailure(nestedError) {
                return true
            }
        }

        return false
    }

    nonisolated static func connectFailureOutcome(
        for error: Error,
        rawReason: String
    ) -> AgenTTYSSHTerminationOutcome {
        if let negotiationOutcome = AgenTTYSSHTransportFailureClassifier.outcome(for: error) {
            return negotiationOutcome
        }

        let shouldReconnect = !containsPermanentConnectFailure(error)
        let category: AgenTTYSSHDisconnectCategory
        let stage: AgenTTYSSHFailureStage?
        var reason = rawReason

        if error is AgenTTYSSHAuthenticationError {
            category = .authFailed
            stage = .sshAuth
        } else if let validationError = error as? AgenTTYTrustedHostKeyValidationError {
            if case .hostKeyMismatch = validationError {
                category = .hostKeyMismatch
            } else {
                category = .other
            }
            stage = .sshAuth
        } else if containsConnectTimeout(error) {
            // `ChannelError.connectTimeout` stringifies as the meaningless
            // "NIOCore.ChannelError error 0", so the string classifier below can
            // never see it: a black-holed path (dead Wi-Fi, wrong network) would
            // read as a generic network error with a raw enum string.
            category = .connectTimeout
            stage = .tcpConnect
            reason = "connection timed out; the host did not answer from this network"
        } else {
            let normalized = rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("timed out") || normalized.contains("timeout") {
                category = .connectTimeout
            } else if normalized.contains("network")
                || normalized.contains("connection refused")
                || normalized.contains("connection reset")
                || normalized.contains("broken pipe")
                || normalized.contains("no route to host")
            {
                category = .networkError
            } else {
                // This outcome is produced only by ClientBootstrap.connect.
                // Authentication and host-key failures are classified above;
                // any remaining unknown channel/POSIX failure is a transient
                // transport failure, not a reason to trip manual recovery.
                category = .networkError
            }
            stage = .tcpConnect
        }

        return AgenTTYSSHTerminationOutcome(
            category: category,
            failureStage: stage,
            rawReason: reason,
            wasReady: false,
            shouldReconnect: shouldReconnect
        )
    }

    nonisolated static func containsConnectTimeout(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return true
        }

        let userInfo = (error as NSError).userInfo
        for value in userInfo.values {
            if let nestedError = value as? Error, containsConnectTimeout(nestedError) {
                return true
            }
        }

        return false
    }

    func runCommandCapturingOutput(_ command: String) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            runTmuxCommand(command) { success, output in
                continuation.resume(returning: (success, output))
            }
        }
    }

    func writeRemoteFile(
        _ data: Data,
        remotePath: String,
        executable: Bool,
        expectedSHA256: String? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            writeRemoteFile(
                data,
                remotePath: remotePath,
                executable: executable,
                expectedSHA256: expectedSHA256
            ) { success in
                continuation.resume(returning: success)
            }
        }
    }

}
