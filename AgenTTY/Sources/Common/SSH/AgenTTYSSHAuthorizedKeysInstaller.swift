import Foundation

nonisolated enum AgenTTYAuthorizedKeyLine {
    static let maximumCommentLength = 80

    static func make(publicKey: String, keyName: String) -> String {
        let keyFields = publicKey.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        return "\(keyFields) \(comment(forKeyName: keyName))"
    }

    static func comment(forKeyName keyName: String) -> String {
        let printableName = String(String.UnicodeScalarView(keyName.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        let name = printableName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let comment: String
        if name.isEmpty {
            comment = "AgenTTY"
        } else if name.lowercased().hasPrefix("agentty") {
            comment = name
        } else {
            comment = "AgenTTY: \(name)"
        }
        return String(comment.prefix(maximumCommentLength))
    }
}

nonisolated struct AgenTTYSSHKeyInstallError: LocalizedError {
    let failure: SSHCommandFailure

    var errorDescription: String? {
        guard let hostMessage = failure.hostMessage else {
            return "Failed to install the AgenTTY SSH key on the host: \(failure.localizedDescription)"
        }
        return "Failed to install the AgenTTY SSH key on the host: \(hostMessage)"
    }
}

nonisolated enum AgenTTYSSHAuthorizedKeysInstaller {
    static func install(authorizedKeyLine: String, using ssh: SSHClientSession) async throws {
        if case .failure(let failure) = await ssh.runCommand(installPublicKeyCommand(authorizedKeyLine: authorizedKeyLine)) {
            throw AgenTTYSSHKeyInstallError(failure: failure)
        }
    }

    static func installPublicKeyCommand(authorizedKeyLine: String) -> String {
        let publicKeyLiteral = SSHClientSession.shellSingleQuoted(authorizedKeyLine)
        return """
set -eu
public_key=\(publicKeyLiteral)
ssh_dir="$HOME/.ssh"
authorized_keys_path="$ssh_dir/authorized_keys"

mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$authorized_keys_path"
chmod 600 "$authorized_keys_path"

key_blob="$(printf '%s\\n' "$public_key" | awk '{print $2}')"
if [ -z "$key_blob" ]; then
  echo "invalid public key" >&2
  exit 1
fi

if awk -v key_blob="$key_blob" 'NF >= 2 && $2 == key_blob { found = 1 } END { exit(found ? 0 : 1) }' "$authorized_keys_path"; then
  exit 0
fi

printf '%s\\n' "$public_key" >> "$authorized_keys_path"
"""
    }
}
