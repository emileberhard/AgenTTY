import Foundation

nonisolated enum AgenTTYSSHAuthorizedKeysInstaller {
    static func installPublicKeyCommand(publicKey: String) -> String {
        let publicKeyLiteral = SSHClientSession.shellSingleQuoted(publicKey)
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
