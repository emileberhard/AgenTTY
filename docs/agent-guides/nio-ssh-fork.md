# NIOSSH Fork

Read this when touching SSH transport, key types, negotiation errors, or anything that depends on an API upstream `swift-nio-ssh` does not have. Read `ssh-session.md` for how the app *uses* SSH; this file is only about the dependency itself.

## Why the fork exists

Upstream `swift-nio-ssh` supports Ed25519 and ECDSA only, and it reports every unusable key-exchange cross-product as one opaque error with no readable diagnostics. AgenTTY's users have RSA host keys and RSA private keys, and when a host is refused the app has to explain *why* on a phone with no log file. Neither is reachable from outside the package, so the changes have to live in the library.

## The pin

- **Repo:** `https://github.com/emileberhard/swift-nio-ssh.git`
- **Branch:** `agentty-nio-ssh` (the default branch; upstream history is preserved)
- **Base:** `3ec281496f28a3b6581afd946b759e2642f5cd8d`, upstream tag `0.15.0`
- **Pinned by revision** in `AgenTTY.xcodeproj`, recorded in its `Package.resolved`

Pinning by revision rather than branch is deliberate: `Package.resolved` is the canonical lock for local builds and releases, and a moving branch would let an unreviewed fork commit into a TestFlight archive.

`_CryptoExtras` (from the exact-pinned swift-crypto 4.5.2) is a dependency of all four app targets because the fork and AgenTTY's own transport schemes both need it: `_RSA.Signing` for RSA keys, `AES._CTR` for the CTR schemes and OpenSSH private-key decryption, and `Insecure.ChaCha20CTR` for `chacha20-poly1305@openssh.com`. The fork requires 4.5.2 and uses SwiftASN1 plus the explicit legacy DER initializer to retain bounded 1024-bit host-key parsing.

## The delta

The original ten-commit compatibility series was rebased mechanically onto 0.15.0
before publication. Published revisions are immutable. `FORK.md` in the fork repo is the authoritative per-commit rationale — read it before changing any of this. Summary:

| Commit | Change | Why it can't be upstreamed as-is |
|--------|--------|----------------------------------|
| `0e30a95` | Order-preserving dedupe of the KEXINIT MAC list | Upstream ships two schemes that both report `nil` MAC names, so the broken path is unreachable there. AgenTTY registers two AES-CTR schemes that both name `hmac-sha2-256`. |
| `2a9d85e` | Public `NIOSSHError.diagnostics` + `negotiationFailure` payload (failing component, both algorithm lists), all six throw sites tagged | Upstream's consumers are servers and CLI tools that have logs. |
| `51302f3` | RFC 4253 §7.2 key expansion replacing a truncating single-digest generator | Upstream ships no cipher with a key wider than its narrowest hash; the old code trapped in debug and silently produced a short key in release for a 64-byte cipher. |
| `3738ed4` | RSA public keys and the `ssh-rsa` wire format (RFC 4253 §6.6) | Upstream deliberately does not ship RSA. |
| `5c4e04f` | RSA signatures with the three RFC 8332 flavors | Same. `RSASignatureFlavor` is the single wire-name→hash mapping, load-bearing because `_RSA` **traps** on an unrecognized digest type. |
| `e123689` | Decouple signature algorithm name from key type | Same. Adds `Offer.PrivateKey.signatureAlgorithm`. |
| `8c0002f` | RSA host-key algorithms in `supportedServerHostKeyAlgorithms`, with the negotiated algorithm bound to the verified signature | Same. The binding matters: without it a server could negotiate `rsa-sha2-512` and return a SHA-1 signature that still verifies. |
| `3c2414e` | `FORK.md` + a single macOS `ci.yml` replacing upstream's reusable swift-nio workflows | Fork housekeeping. |
| `70ea92e` | New protocol requirement `decryptFirstBlock(_:sequenceNumber:)` with a defaulting extension | Upstream ships no cipher that encrypts the length field independently, so no upstream conformer needs the number. |
| `e9f48ee` | Defaulted (nil-algorithm) offers sign the algorithm name that goes on the wire | Upstream has no RSA keys, so upstream's `nil` path cannot diverge; here a defaulted RSA offer signed a payload naming `ssh-rsa` while the wire carried `rsa-sha2-512`, which real servers reject. AgenTTY itself always passes an explicit algorithm per ladder rung. |

Two deliberate divergences worth knowing before you "fix" them:

- **`ssh-rsa` (SHA-1) is advertised, always last.** Negotiation walks the client's preference list and takes the first entry the server also supports, so it is selected only when a host offers nothing better — which is exactly the Dropbear and OpenSSH ≤ 8.7 case it exists for.
- **The fork's host-key floor is 1024 bits, not 2048.** A host key is the remote peer's choice; refusing to represent one just makes the host unreachable. The floor bounds parsing, not policy. AgenTTY's own 2048-bit minimum applies to *imported private keys* and lives in `AgenTTYSSHPrivateKeyParser`, not in the library.
- **No `SSH_MSG_EXT_INFO` / `server-sig-algs`.** Servers send EXT_INFO only when the client advertised `ext-info-c`, which NIOSSH does not; implementing it would be a large permanent delta on the code most likely to conflict with upstream. The cost is at most two extra `USERAUTH_FAILURE` round trips against pre-RFC-8332 servers, which is why `AgenTTYSSHAuthenticationDelegate` walks a ladder instead.

## Fork APIs AgenTTY depends on

Changing or losing any of these breaks the app build, so they are the contract to re-check against a new upstream release:

- `NIOSSHPrivateKey.init(rsaKey: _RSA.Signing.PrivateKey) throws` — `AgenTTYStoredSSHPrivateKey` rebuilds imported RSA keys through it. It is `throws` (unlike the sibling initializers) because it eagerly resolves the public key's primitives.
- `NIOSSHPrivateKey.signatureAlgorithms: [String]` — drives `AgenTTYSSHAuthenticationDelegate.pendingOffers`.
- `NIOSSHUserAuthenticationOffer.Offer.PrivateKey.init(privateKey:signatureAlgorithm:)` — how the ladder picks a rung. `nil` reproduces upstream's bytes exactly.
- `NIOSSHError.negotiationFailure: NegotiationFailure?` with `Component` (`keyExchange`, `hostKey`, `encryption`, `mac`, `transportProtection`, `asymmetricNegotiation`) — read by `AgenTTYSSHTransportFailureClassifier`, which collapses the six components onto four.
- `NIOSSHTransportProtection.decryptFirstBlock(_:sequenceNumber:)` — implemented by `ChaCha20Poly1305TransportProtection`. The default implementation forwards to `decryptFirstBlock(_:)`, so the AES-CTR schemes are unaffected.
- RFC 4253 §7.2 key expansion — not an API, but `ChaCha20Poly1305TransportProtection` silently gets a 32-byte key instead of 64 without it.

## Working on the fork

Not in this repo. Clone `emileberhard/swift-nio-ssh`, work on `agentty-nio-ssh`, keep one concern per commit, and keep `swift test` green on macOS with the Xcode 27 toolchain (Swift 6.4) — the same toolchain AgenTTY builds with. Then bump the revision in `Project.swift`, regenerate, and let `Package.resolved` update. Do not point AgenTTY at a local path or a branch.

To read the fork source without cloning it, the resolved checkout is at
`~/Library/Developer/Xcode/DerivedData/AgenTTY-*/SourcePackages/checkouts/swift-nio-ssh`.

## Upstream audit obligation

On each upstream `swift-nio-ssh` release, re-check whether RSA support has landed upstream and whether any of these commits can be dropped. Commits `0e30a95`, `2a9d85e`, `51302f3`, and `70ea92e` are the plausible standalone upstream contributions; the RSA commits exist only because upstream has made a deliberate choice not to ship RSA. Every commit dropped is delta that stops needing maintenance.

## Security baseline and dependency compatibility

The 0.15.0 base includes the upstream 0.14.1 fix for
[GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc),
an unauthenticated out-of-bounds stack write from an oversized ECDSA signature.
The recovered 0.12.0 fork was affected. Keep this fix when maintaining the delta.

AgenTTY pins swift-nio 2.104.0, above the 2.100.0 fixes for
GHSA-rj37-6j9x-74q6, GHSA-r3rc-9hpw-54v9 and GHSA-cq87-8r7h-962v.
The swift-crypto 4.5.2 pin fixes
[GHSA-8q93-f6xh-4f6f](https://github.com/apple/swift-crypto/security/advisories/GHSA-8q93-f6xh-4f6f),
a double-free when malformed RSA public keys fail to decode. SwiftASN1 serializes
SSH modulus/exponent values as PKCS#1 DER for the explicit legacy initializer.
This preserves the 1024–16384-bit host-key bounds while private imports retain
their separate minimum. OpenSSH private imports check the modulus before the
component initializer so weak keys retain the actionable size error.
The focused RSA suite includes a 1024-bit round trip.

## Simulator build verification

With Xcode 27.1, swift-nio 2.104.0 compiles for the iOS simulator from clean
DerivedData. If `SocketChannel.swift` reports `IOError.Error` or `IOError.error`
as private while `NIOCore/IO.swift` declares them `package`, repeat the maintained
test scheme with a fresh, task-owned `-derivedDataPath` before changing pins.
An incremental pass does not prove the dependency sources were recompiled.
