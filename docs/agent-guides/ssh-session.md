# SSH and Tmux Session

Read this when working on SSH connection, tmux bootstrap, PTY sizing, reconnection, host management, key management, or terminal bridge coordination.

## Connection Config

`AgenTTYConnection` keeps static tmux policy:
- Tmux session: `agentty-main`

`AgenTTYSSHBootstrapConfigurationProvider` holds compile-gated bootstrap SSH constants:
- Included only when `AGENTTY_BOOTSTRAP_SEED` is set for the target
- Contains local developer host/username + bootstrap private key seed bytes loaded from ignored local secrets
- `AgenTTY-iOS-Dev` and `AgenTTY-iOS-Exp` compile this payload; `AgenTTY-iOS` (main) does not

Runtime destination comes from `AgenTTYHostStore`:
- Host records (`AgenTTYHost`) persist `label`, `address`, `port`, `username`, an auth mode, and optional relay routing metadata:
  - `.key(keyID)` for normal steady-state SSH
  - `.passwordBootstrap(targetKeyID, credentialID)` for temporary password-only bootstrap
  - `connectionRoutePolicy`: `.directOnly` or `.directThenRelay`
  - `relayHostID`: backend-issued relay host identifier for connector-backed fallback
- Active host selection maps to `AgenTTYConnectionTarget` and is passed into `SSHClientSession`
- Dev/Exp can bootstrap a local developer host into persisted storage on launch if missing
- Main flavor prunes bootstrap host artifacts from main-flavor persisted storage on launch

Runtime SSH keys come from two layers:
- `AgenTTYSSHKeyStore`: key metadata (`name`, `type`, `public key`, `fingerprint`, source). `SSHKeyType` is `ed25519`, `ecdsa-256/384/521`, `rsa`; `SSHKeyType.generatable` is `[.ed25519]`, so everything else is import-only.
- `AgenTTYSSHKeyMaterialStore`: private key material in Keychain (never in UserDefaults). `AgenTTYSSHPrivateKeyParser.parse(_:passphrase:)` accepts `openssh-key-v1`, PKCS#1 `BEGIN RSA PRIVATE KEY`, SEC1 EC, and PKCS#8 containers. RSA privates are stored as PKCS#1 DER (`AgenTTYStoredSSHPrivateKey.Kind.rsa`, discriminator `5`) and rebuilt into `NIOSSHPrivateKey(rsaKey:)` on use; anything below `minimumRSAKeySizeInBits = 2048` is rejected with `rsaKeyTooSmall` regardless of container. Encrypted `openssh-key-v1` files are decrypted at import through `AgenTTYOpenSSHKeyDecryption` + `BcryptPBKDF` and then stored like any other key. Only `ssh-keygen`'s current default (`aes256-ctr` + `bcrypt`, rounds capped at 1024) is supported; any other cipher throws `unsupportedPrivateKeyCipher` with a re-export instruction rather than being guessed at, and cipher support is decided *before* a passphrase is demanded so an unusable key reports the real reason. A missing passphrase is `privateKeyPassphraseRequired`; OpenSSH's paired check integers are the only passphrase verifier, so a wrong one is `privateKeyPassphraseIncorrect`.
- `AgenTTYSSHPasswordStore`: temporary password bootstrap credentials in Keychain; the credential is deleted once key install succeeds and the host converts to `.key(...)`
- Adding a host now starts with a dedicated setup-method chooser:
- `Automatic Setup` (primary): the host runs `npx -y @agentty-app/pair`, renders a QR + short code, optionally offers the host's short Tailscale hostname when Tailscale is installed (falling back to the full MagicDNS name only when needed), the app scans or types that code, retries a rejected pairing claim once after the APNs-independent `/v1/devices/ensure` path reasserts the iPhone's relay device identity, waits for the helper to install the device public key, then attempts to provision the persistent `agentty-host-connector` service from the host-runtime artifact host before opening the normal add-host editor with detected values prefilled so the user confirms before saving
  - `Manual Setup`: user enters the host details directly, chooses a key the host should trust, and can copy/share that key's OpenSSH public key inline from the host form before saving
  - `Password Setup`: authenticates once with plain SSH password auth, installs the selected/generated key before shell attach, then auto-converts the host to `.key(...)`. Only the user-facing label changed here; the enum case is still `HostSetupMethod.oneTimePassword` and the auth mode is still `.passwordBootstrap(...)`.
- `Automatic Setup` reuses or creates the default device key (`AgenTTY on <device name>`) automatically; it does not expose a key picker in the happy path.
- The global `Keys` sheet now also exposes copy/share actions for the full public key when viewing an existing key, so manual host setup does not require leaving the app.
- Host addresses are normalized through `AgenTTYHostAddressNormalizer` before matching, verification, and persistence: surrounding whitespace/invisible padding is trimmed, common Unicode dash/minus characters become ASCII `-`, and user-facing casing is otherwise preserved.
- New hosts now always run a short TCP reachability probe on the iPhone before persisting, and edited hosts rerun that probe when the address or port changes. If the probe fails, the sheet shows a warning with `Edit Host` and `Save Anyway` choices instead of silently saving an unreachable destination. DNS failures use subtype `.dns`, say the hostname does not resolve from this iPhone, and suggest IP address, full Tailscale/MagicDNS hostname, `.local`, or rerunning Automatic Setup.
- The key picker still exposes an `Add New Key...` option, and successful key creation dismisses back to the host form and auto-selects the new usable key.

Host-key trust is managed by `AgenTTYTrustedHostKeyStore` (TOFU).

## SSH Session (`SSHClientSession`)

Uses Swift-NIO + NIOSSH. `nonisolated final class @unchecked Sendable`, thread-safe via internal `DispatchQueue`.

NIOSSH comes from AgenTTY's fork (`emileberhard/swift-nio-ssh`, branch `agentty-nio-ssh`), pinned by revision in `Project.swift`. See `nio-ssh-fork.md` for what it changes and why; the app-visible additions are RSA keys, `NIOSSHError.negotiationFailure` diagnostics, RFC 4253 §7.2 key expansion, per-offer signature algorithms, and `decryptFirstBlock(_:sequenceNumber:)`.

**Connection flow:**
1. `ClientBootstrap` with `NIOSSHHandler` pipeline, 5s connect timeout, `TCP_NODELAY`, TCP keepalive (15s idle / 5s interval / 3 probes), and the interactive `NET_SERVICE_TYPE_RD` socket service class
2. Uses `AgenTTYSSHAuthenticationDelegate` with either a host-selected private key or a temporary password bootstrap credential
3. Uses `TOFUHostKeysDelegate` with per-host trust validation/persistence
4. If the host is in `.passwordBootstrap(...)`, installs the target public key into `~/.ssh/authorized_keys`, converts the saved host auth to `.key(...)`, and deletes the stored password credential
5. Runs the pre-shell host-runtime provisioner on the connected root SSH transport
6. Creates the shell child channel with `ShellChannelHandler` for PTY I/O only after the host runtime is ready
7. Sends `PseudoTerminalRequest` (using latest known window size) then `ExecRequest` with the app-bundled tmux bootstrap script
8. On success: calls `readyHandler()`, flushes any queued outbound data

**Key invariant**: `latestWindowSize` is stored even before the shell channel exists. PTY request uses this value, not hardcoded dimensions. Size is reapplied when shell becomes ready.

**One-off exec channels**: `runOneOffExecCapturingOutput` creates fresh SSH channels per command. Used for tmux navigation, dictation insertion, clipboard image/file upload, shell-title host-state reads, and ordinary-shell pane capture. Captured stdout/stderr keeps a rolling tail capped at 1 MB. Generic file uploads stream local temp files to the exec channel in fixed chunks so larger pasted files do not have to be materialized as one in-memory `Data` buffer.
`runTmuxCommand` carries a response timeout (default 20s) implemented on the root channel's event loop; the timeout covers both channel creation and command completion so a silently dead transport produces a failed command instead of a hang. `TerminalBridge` passes a 5s timeout (`interactiveTmuxCommandTimeout`) for interactive commands — shell polls, swipes, window select/create — while provisioning-class callers keep the 20s default. `runLivenessProbe` runs a no-op command with a 6s timeout as a cheap end-to-end transport health check. Streamed file uploads remain untimed.

## Transport Algorithms and Authentication Ladder

`AgenTTYSSHTransportProtectionSchemes.clientSchemes()` is the single place the cipher list is built, and it is passed into `NIOSSHHandler` from the channel initializer. Order is NIOSSH's bundled AEAD schemes (`aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`) followed by `chacha20-poly1305@openssh.com`, `aes256-ctr`, and `aes128-ctr`. NIOSSH negotiates client-order-first, so existing hosts keep negotiating exactly what they did before and the appended schemes are purely a compatibility tail for Dropbear-class servers. It is a function, not a stored value, because `[NIOSSHTransportProtection.Type]` is an existential-metatype array and building it inside the `@Sendable` initializer avoids capturing a global; the appends are individual statements because an array literal of differing metatypes infers `[Any]`.

The three app-side schemes live in `Common/SSH/Transport/`:
- `AgenTTYAES256CTRTransportProtection` / `AgenTTYAES128CTRTransportProtection` are thin wrappers over `AgenTTYAESCTRTransportProtectionCore`, which implements RFC 4253 encrypt-and-MAC (AES-CTR for confidentiality plus a separate HMAC-SHA2-256 over the plaintext packet). `ivSize` is 16 because RFC 4344 §4 makes the *initial counter block* the IV; NIOSSH truncates the derived IV to `keySizes.ivSize`.
- `ChaCha20Poly1305TransportProtection` implements OpenSSH's `chacha20-poly1305@openssh.com` with a local `Poly1305`. It needs two things upstream NIOSSH could not provide: a 64-byte session key (the fork's RFC 4253 §7.2 expansion) and the packet sequence number at length-decryption time (the fork's `decryptFirstBlock(_:sequenceNumber:)`), since the length field is encrypted under a separate key with the sequence number as nonce.

`AgenTTYSSHAuthenticationDelegate` builds `pendingOffers` once at init and pops one per `nextAuthenticationType` call. For a private key that means one offer per entry in the fork's `NIOSSHPrivateKey.signatureAlgorithms`: an RSA key produces `rsa-sha2-512`, `rsa-sha2-256`, then `ssh-rsa`, because RFC 8332 lets one `ssh-rsa` key blob sign under three algorithm names and only `SSH_MSG_USERAUTH_FAILURE` reveals which the server accepts. Every non-RSA key type yields exactly one entry, so their wire behavior is byte-identical to before. When the list empties, the delegate fails with `publicKeyAuthenticationRejected(attemptedAlgorithms:)`, whose message and log line name every algorithm that was tried.

## Host Runtime and Tmux Bootstrap

Before the shell channel opens, AgenTTY provisions a private host runtime under `~/.agentty/`:
- `bin/` public wrappers (`tmux`, `agentty-bootstrap`, `agentty-shell`, `agentty-log`, `agentty-manifest`, `agentty-notify`, `claude`, `codex`)
- `libexec/` private host-runtime binaries (`tmux`, `agentty-notify`)
- `share/terminfo/` managed terminfo entries used by tmux attach and pane shells
- `config/` runtime config (`tmux-session-name`, `notify.json`, `claude-settings.json`, shell rc files)
- `state/` derived facts (`host-platform`, `shell-realpath`, `claude-realpath`, `codex-realpath`, optional `codex-original-notify.json`, tmux socket dir)
- `logs/` host-side logs

The SSH startup always runs `AgenTTYConnection.tmuxBootstrapCommand` via `/bin/sh -lc`. The bootstrap script:
1. Validates that the tmux wrapper and session-name config exist
2. Forces UTF-8 env defaults (`LANG`, `LC_CTYPE`) and exports `TERMINFO_DIRS` with `~/.agentty/share/terminfo` first
3. Clears stale Claude runtime vars from the tmux global env (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_OAUTH_TOKEN`)
4. Uses the AgenTTY tmux wrapper at `~/.agentty/bin/tmux`, which always targets the dedicated socket `~/.agentty/state/tmux/socket`
5. Ensures the `agentty-main` session exists on that socket
6. Sets global/session `PATH`, `TERMINFO_DIRS`, `default-command`, and `default-terminal=tmux-256color` so the initial window and all new panes launch through `~/.agentty/bin/agentty-shell` with AgenTTY-managed terminfo
7. Applies session/window options (`mouse on`, `focus-events on`, `status off`, cursor style, copy-mode wheel bindings)
8. Installs shell-manifest hooks (`window-linked`, `window-unlinked`, `client-attached`, `client-detached`, `session-window-changed` → `run-shell -b ~/.agentty/bin/agentty-manifest`) that keep `~/.agentty/state/shell-manifest.tsv` current, and writes an initial dump
9. Attaches with loop guards

When step 5 finds no session (fresh server — first use or a server death), the bootstrap first archives any existing shell manifest into `~/.agentty/logs/shell-manifest-<timestamp>.tsv` (newest 20 kept) and appends a `server-start` line to `~/.agentty/logs/tmux-server.log` naming the archive, so the shells that were open at server death remain restorable. The restoration procedure lives in `docs/agent-guides/observability-and-debugging.md`.

There is no system package-manager tmux install path, no runtime `git clone`, and no `tmux-resurrect` restore/save flow in the current design.

**Reconnect fast path:** `prepareBaseRuntime` first runs one combined gather script (single exec round trip) that returns installed static/binary versions, host platform, presence checks for every managed runtime file and terminfo entry, and command realpaths, and performs the idempotent housekeeping inline (tmux session-name contract write, legacy file cleanup). When the gathered facts confirm everything is current, no further pre-shell round trips run. Incomplete or drifted facts fall back to the original step-by-step sync/upload path, which remains the source of truth for first connects and drift repair. Main-flavor builds verify the binary payload against `expectedHostRuntimeVersionHint`; dev/exp (hint-less `latest` channel) still resolve artifacts and run one extra presence probe.

## Terminal Bridge (`TerminalBridge`)

`@MainActor final class`. Central coordinator between SSH and Ghostty.

**Inbound (SSH → Ghostty):** NIO shell output calls a nonisolated, lock-protected `TerminalBridge` inbound router. The router drops stale connection generations, verifies that terminal input is currently accepted and the Ghostty surface pointer is still valid, then schedules `ghostty_surface_write_pty_output` directly on the background serial queue (`dev.tuist.agentty.terminal-io`) without hopping through the MainActor. It dispatches back to main only when a tmux shell swipe is waiting for a data-update signal.

**Outbound (keyboard → SSH):** `sendRawBytes` → `SSHClientSession.send()`. Direct path, no Ghostty input pipeline.

**Focus-refresh repaint path:** Lifecycle/theme layers send synthetic focus refresh pulses (`ESC[O` then `ESC[I`) through `TerminalBridge`; for `didBecomeActive` and `theme-change`, bridge also sends a same-size PTY window refresh plus a coalesced two-pass targeted nudge (immediate + ~80ms follow-up). `emitSyntheticFocusPulse` is the single choke point and refuses to send unless `hostConnectionPhase == .connected`: `SSHClientSession` queues outbound bytes while connecting and flushes them the moment the tmux bootstrap exec starts, and tmux's `tty_keys_next` (3.6a through current master) calls `window_update_focus(c->session->curw->window)` for focus events with no null check on `c->session`, so a focus byte reaching the server tty before the attaching client binds its session segfaults the entire tmux server (observed live 2026-08-14; crash report `tty_keys_next` + KERN_INVALID_ADDRESS at 0xd8). The managed runtime tmux is also built with `scripts/patches/tmux-3.6a-focus-null-session.patch` so the server survives that byte timing from any source; the app-side gate protects hosts whose long-running server still executes an older unpatched binary.

**Copy-mode refresh crash:** tmux 3.6a has a second server-killing bug (observed live 2026-08-14; SIGBUS in `grid_line_length` at a wild unallocated address via `cmdq_next`): the copy-mode `refresh-from-pane` command — bound to `r` in both default copy-mode key tables — re-clones the backing screen from the pane's current screen without clamping `data->oy`. A pane that entered copy mode on the normal screen, scrolled up, and then switched to the alternate screen (a TUI agent) re-clones with `hsize` 0, `py = hsize + cy - oy` underflows as `u_int`, and the wild `linedata[py]` read kills the server and every shell. `scripts/patches/tmux-3.6a-copy-mode-refresh-oy-clamp.patch` clamps `oy` after the re-clone (mirroring upstream's later fix) and bounds-guards `grid_line_length`; because servers outlive binary upgrades, `agentty-bootstrap.sh` additionally unbinds `r` → `refresh-from-pane` in both copy-mode tables on every connect so a stray key cannot trigger it on a pre-patch server. For `theme-change`, each pass performs `window refresh + render` before the post-pass focus pulse so terminal prompt/input tint that re-samples on `FocusGained` does not lag one theme behind.

**Connection preflight:** Before opening SSH, bridge resolves either selected host key material or a temporary bootstrap password from Keychain. Missing/invalid configuration blocks connect and disables reconnect retries until config is fixed.

**Route resolution:** `TerminalBridge` resolves the selected host through `AgenTTYConnectionRouteResolver` on every connect attempt. `.directOnly` hosts always use the saved `address:port`. `.directThenRelay` hosts first run a short direct TCP probe; if that fails, the bridge requests a short-lived relay websocket session, starts an `NWListener` bound to loopback, and points `SSHClientSession` at `127.0.0.1:<ephemeral-port>` while preserving the saved logical host/port for TOFU host-key validation. The resolver also keeps per-host route memory: a connection that reached ready over the direct route records a 10-minute direct-route success, and subsequent resolves skip the probe and connect directly (the SSH connect timeout acts as the probe). A pre-ready network-class failure on the direct route clears that memory and re-arms the 15s probe-failure cache so the next attempt falls back to relay. If relay resolution also fails, the resolver clears that short direct-failure cache so the next backoff attempt probes direct again rather than remaining pinned to a dead relay. Network path changes invalidate all route memory via `AgenTTYConnectionRouteResolver.invalidateRouteMemory()`. Relay session issuance uses a dedicated URLSession with a 10s request timeout, and `AgenTTYRelayBridge` runs its websocket on a `.responsiveData` URLSession, pings every 20s, and forwards bytes in both directions off the MainActor through a lock-guarded pump so terminal latency never queues behind UI work. `AgenTTYRelayBridge.start()` also awaits the websocket open handshake through a task-level `URLSessionWebSocketDelegate`, bounded by a 10s timeout that throws `AgenTTYSSHRelayError.websocketOpenTimedOut` (classified transient in `TerminalBridge.isTransientPreflightError`). Without that bound, partial connectivity — a wedged VPN where warm pooled HTTPS connections still work but new sockets die — let relay session issuance succeed while the never-opening websocket kept each attempt alive for minutes, so the app cycled "connecting" without ever surfacing a failure.

**Relay resource limits:** The app advertises typed resource-error support when issuing SSH relay sessions. A `429` response becomes `AgenTTYSSHRelayError.resourceLimit` with the backend detail and is a permanent preflight failure, so it presents recovery without automatic retries. An exhausted bandwidth pool denies new tunnels until reset; direct SSH still works. Pairing can adopt an existing host only with an existing device grant or the locally stored connector credential. Registration sends the verified StoreKit AppTransaction when available; operator-configured trusted credentials and the bounded compatibility lane cover local and older builds. See `docs/backend.md` for the admission switch, limits and removal condition.

**Reconnection:** For transient disconnects, bounded exponential backoff (1s → 2s → 4s → 8s cap). For permanent errors (for example host-key mismatch), reconnect is intentionally disabled. Algorithm-negotiation failure is the other permanent class: `AgenTTYSSHTransportFailureClassifier.outcome(for:)` recognizes `NIOSSHError.keyExchangeNegotiationFailure` (unwrapping nested `NSError.userInfo` values), reads the fork's `negotiationFailure` payload, and returns `.algorithmNegotiationFailed` with `shouldReconnect: false`. The fork's six components collapse onto four user-meaningful ones — `transportProtection` (an agreed cipher/MAC pair with no registered scheme) and `asymmetricNegotiation` (per-direction disagreement) both fold into `.encryption`. `AgenTTYSSHRecoveryGuidance` then shows one of four cards (host key / key exchange / MAC / encryption), each listing what AgenTTY supports plus `This host offers: …` from the remote list; a relay-wrapped or legacy error with no payload falls back to the encryption card, since that is the most likely cause. The category maps to analytics `.other` on purpose: the relay validates a strict snake_case enum, so a real `algorithm_negotiation_failed` value needs a paired app release and backend deploy or the event would be rejected with HTTP 400 and dropped permanently. Transient preflight failures (reachability probe, relay HTTP/URL errors) schedule the same backoff retry instead of permanently blocking with "connection blocked"; only configuration-class preflight failures (bad key material, missing relay setup, rejected device identity) stop the loop. `ChannelError.connectTimeout` is matched by type in `containsConnectTimeout`, not by message, because it stringifies as the meaningless `NIOCore.ChannelError error 0`; without that branch a black-holed path (dead Wi-Fi, wrong network) would read as a generic network error carrying a raw enum string. Other unknown channel/POSIX failures returned by `ClientBootstrap.connect` are classified as `.networkError` after explicit authentication, host-key, and negotiation cases are ruled out, so an opaque NIO transport error cannot count toward manual recovery. The pre-ready failure circuit breaker (3 failures / 60s → recovery UI) only counts non-transient disconnect categories — `connectTimeout`, `networkError`, and `transportClosed` are exempt so roaming cannot trip it. `AgenTTYNetworkPathObserver` (NWPathMonitor) feeds `TerminalBridge`: on a path change it invalidates route memory, fires any pending reconnect backoff timer immediately with a reset attempt counter, and runs a liveness probe when the bridge believes it is connected.

**Connection diagnostics:** Every SSH generation has a monotonic `OSSignposter` Points of Interest interval with a route-resolved event plus privacy-safe OSLog and Sentry breadcrumbs for start, route, ready, and disconnect. The breadcrumb payload is limited to generation, route, elapsed milliseconds, normalized disconnect category, failure stage, and whether the session was ready. A handled Sentry event is emitted only when the app actually presents manual recovery. Direct-route hostname classification no longer blocks SSH startup: the bridge sets the immediate address-based method, starts the session, and refines the label in parallel.

**Liveness:** `TerminalBridge.verifyTransportLiveness(reason:)` runs `SSHClientSession.runLivenessProbe` (no-op exec, 6s timeout) and forces an immediate reconnect when it fails. It triggers on app foregrounding while a transport looks alive (`AgenTTYConnectionLifecyclePolicy` returns `.verifyTransportLiveness`), on network path changes while connected, and whenever a tmux shell poll or interactive tmux command (swipe, window select/create) fails. This catches sockets that died silently during Wi-Fi/cellular transitions, which otherwise look connected until TCP gives up.

**Host switching:** `setActiveHost(_:)` updates runtime destination. Changing host reconnects immediately; clearing host disconnects and stops reconnect scheduling.

**Status line injection:** Before SSH connects, bridge injects UTF-8 status text directly into Ghostty via `write_pty_output`. These `[agentty] ...` lines use the terminal's default foreground/background colors rather than custom status-banner styling, and they print as ordinary consecutive terminal lines with a single trailing newline per message. While the in-terminal reconnect screen is presenting, `emitStatusLine` drops them to the log instead, because a status line would scroll the centered block apart.

**Connection phase and reconnect screen:** `TerminalBridge` publishes `AgenTTYHostConnectionPhase` (`.disconnected` / `.connecting` / `.connected`) through `hostConnectionPhaseDidChange`; `allowsHostInteraction` is the single gate UI uses for host-dependent affordances. Setting the phase, arming a backoff deadline, changing the recovery request, or changing app-active state all call `refreshReconnectScreen()`, which recomputes `reconnectScreenPhase` and hands it to `TerminalReconnectScreenPresenter`. The screen is shown only while the phase is `.connecting`, a host is selected, hosts exist, no manual `connectionRecoveryRequest` is pending, and screenshot mode is off — manual recovery and permanently blocked states keep the recovery alert plus ordinary status lines. See `ios-surface-and-touch.md` ("Disconnected State") for the rendering, activation-delay, and tick behavior.

**Notification provisioning:** After SSH becomes ready, `TerminalBridge` registers the current device token with the notify relay backend, requests a renewable relay token, resolves the remote host platform, uploads versioned notification assets into `~/.agentty/`, and writes runtime config directly from Swift. There is no remote installer script anymore. The host-side `tmux` and `agentty-notify` binaries are no longer bundled in the iOS app; instead the app fetches a small manifest plus the correct per-platform runtime payload from its configured artifact host, verifies SHA-256 with `CryptoKit`, caches the results in the shared app-group caches directory, uploads `tmux` and `agentty-notify` to `~/.agentty/libexec/`, uploads managed terminfo files to `~/.agentty/share/terminfo/`, and keeps the canonical public entrypoint at `~/.agentty/bin/agentty-notify`. Each managed file is streamed to a unique sibling temporary path and must pass both an exact byte-count check and a remote SHA-256 check before permissions are applied and the file is atomically renamed over the live path. A completed payload writes `state/host-runtime.sha256`; reconnects verify that manifest against the live binaries and terminfo, so a truncated or otherwise drifted file is repaired even if `state/host-runtime-version` still matches. `AgenTTY-iOS` uses the immutable GitHub release manifest at `/releases/download/<version>/host-runtime-manifest.json`, while `AgenTTY-iOS-Dev` and `AgenTTY-iOS-Exp` use the maintainer-configured mutable `/host-runtime/latest.json`. Provisioning also prunes known installer-era leftovers like the old root-level `notify.env` and `agentty-install-notifications`. When AgenTTY preserves a pre-existing Codex `notify` command into `state/codex-original-notify.json`, it only keeps commands that are safe to replay from AgenTTY's host-runtime process tree; it intentionally drops OpenAI Computer Use's `SkyComputerUseClient turn-ended` helper because replaying that helper outside Codex's own launch chain triggers macOS launch-constraint crash popups while the real `SkyComputerUseClient mcp` process continues to serve Computer Use normally. The relay still marks visible alert pushes with `mutable-content=1`, and the iOS app bundle embeds a Notification Service Extension per flavor so background/locked deliveries emit the same `attempt_id`-keyed trace fields as the app foreground path. Successful provisioning is log-only; visible terminal status lines remain reserved for unavailable/failure states. Reconnects reuse versioned static assets and skip binary downloads entirely only after the installed runtime version and checksum manifest both verify. If APNs registration finishes later, `TerminalBridge` listens for the token-change notification and retries provisioning for the still-active SSH generation so the user does not need to reconnect. While the bridge stays connected, it also refreshes relay tokens before expiry.

**Relay connector maintenance:** After a direct main-flavor SSH session is ready, the bridge best-effort verifies an already-installed `~/.agentty/libexec/agentty-host-connector` against the immutable release manifest. A stale connector is downloaded through the same SHA-256-verified artifact store, uploaded to a unique candidate path, exercised with `probe-control` against the existing config, atomically moved into place, and activated by terminating only the exact managed process command so its supervisor restarts it. The maintenance task never runs over a relay-backed session and skips missing connectors. Dev/exp skip it because their mutable `latest` channel must not make a shared host oscillate against the main app's immutable release artifact.
**Production analytics:** `TerminalBridge` also emits production-only SSH session completion events through `AgenTTYAnalyticsClient`. These use the same install-scoped device credentials as the notify/pairing relay path, but the real-user key is the verified `AppTransaction.appTransactionID` resolved elsewhere in the app. The bridge never sends raw hostnames, addresses, usernames, or raw network-error strings; it reports only a hashed host identifier derived from the local host UUID, total session duration, whether the session reached ready state, whether the session saw terminal input, the input-event count, the auth mode (`key` vs `password_bootstrap`), and a normalized disconnect category (`shell_closed`, `connect_timeout`, `network_error`, `auth_failed`, `host_key_mismatch`, `local_close`, `other`). Dev/exp and side-loaded `main` installs that lack a verified app transaction do not emit analytics.

**Host-side notification state:** Important notification/runtime files are `bin/agentty-log`, `bin/agentty-shell`, `bin/agentty-notify`, `bin/claude`, `bin/codex`, `config/notify.json`, `config/tmux-session-name`, `config/claude-settings.json`, `state/host-platform`, `state/host-runtime-version`, `state/host-runtime.sha256`, `state/shell-realpath`, `state/claude-realpath`, `state/codex-realpath`, optional `state/codex-original-notify.json`, `libexec/agentty-notify`, `libexec/tmux`, `share/terminfo/**`, and `state/tmux/socket`. `state/codex-original-notify.json` is only used for safe passthrough notify commands; AgenTTY deliberately excludes OpenAI Computer Use's `SkyComputerUseClient turn-ended` helper from that passthrough list. For Codex legacy notify payloads, `agentty-notify` treats JSON `null` assistant-message fields as absent and falls back to the latest input prompt before finally falling back to `"done"`, which keeps plan-mode proposal notifications readable even though Codex's legacy hook payload does not include the separate `plan` item text. High-signal remote logs live in `~/.agentty/logs/notify.log` and `~/.agentty/logs/wrappers.log`; each real notification attempt now carries an `attempt_id` through host helper logs, relay logs, APNs payload metadata, the iOS app’s `notifications` OSLog category, and the bundled Notification Service Extension’s `push_extension_*` logs.

## Tmux Shell Navigation

`navigateTmuxShell(_ direction:)` queues swipe commands and drains them sequentially (one tmux command in flight). Each swipe runs an atomic tmux command via one-off SSH exec and returns canonical state.

Window ordering uses `@<window_id>` targeting (not `window_index`) so ordering stays stable across creates/deletes.
Both explicit shell creation and the forward-swipe-at-end auto-create path use the same tmux create-window helper. By default that helper reuses the rightmost shell's `pane_current_path` in UI order (highest tmux `window_id` / newest shell). Settings can disable the reuse behavior and fall back to HOME, and invalid/missing reused paths also fall back to HOME.

## Tmux Polling

`startShellPolling()` runs recursive `DispatchWorkItem` polling at 1.0s cadence while the app is active and 15s while backgrounded (background polls double as keepalive traffic). Each poll runs `tmux list-windows` via one-off exec (5s response timeout) and updates `ShellIndicatorState`. Extended metadata polls run every fourth cycle and include scrollback history, alternate-screen state, tmux `session_created`, and the helper's provider/session/turn/revision user options. A failed or timed-out poll escalates to `verifyTransportLiveness`, which reconnects if the probe also fails.

Immediate polls trigger after swipe navigation and `Ctrl+D` to reflect window closure quickly. `tmux list-windows` includes `pane_current_path` so per-window working-directory context for quick-switcher fallback labels piggybacks on the same polling flow.

## Active Shell Context (Folder + Branch)

`TerminalBridge` publishes every window's working directory from tmux (`pane_current_path`) on the normal shell-state polling path so the quick switcher can label shells even when AI titles are absent. It separately publishes active-shell context through `activeShellContextDidChange(windowID, workingDirectoryPath, branchName)`. Branch state is resolved with throttled git lookups and cached per directory.

## Shell Titles

The base host runtime installs Claude `UserPromptSubmit`/`Stop` hooks and the existing Codex `notify` integration even when APNs is unavailable. `agentty-notify` records a bounded five-turn context atomically under `~/.agentty/state/shell-title/<session_created>/window-<id>.json`, deduplicates provider event IDs under a per-window file lock, and then publishes provider/session/completed-turn/revision tmux user options with revision last. Notification delivery is a separate best-effort step after this state write.

For agent windows, bridge generates after completed turns 1, 2, 3, 4, 5, 10, 20, 30, and so on. It reads the typed host-state JSON only when a new milestone is eligible and passes the existing title into `AgenTTYLLMClient.generateShellTitle`; the model preserves an accurate current title verbatim and replaces it only after a meaningful task shift or when a clearly more accurate or narrower title is available. Bridge accepts the result only if host/tmux/provider identity, helper revision, and SSH connection generation are still current. A failed generation does not consume the milestone and retries with 30-second exponential backoff capped at five minutes. Titles persist in `UserDefaults` under a v2 identity containing host UUID, tmux `session_created`, window ID, and provider session.

Ordinary shells retain the earlier milestone strategy but count tmux scrollback history only. The visible pane height is not treated as conversation progress. Alternate-screen windows without agent metadata skip this fallback because tmux capture exposes only their current viewport, not the full conversation.

Shell-title AI is independently toggleable via `AGENTTY_ENABLE_SHELL_TITLE_AI` (legacy `AGENTTY_ENABLE_SHELL_TITLE_AI` still accepted). When disabled, title text is suppressed in UI consumers.

On SSH reconnect, a title is reused only when the full v2 identity matches. The old window-ID-only v1 cache is discarded because tmux IDs collide across hosts and server lifetimes.

## Key Files

| File | Responsibility |
|------|---------------|
| `AgenTTYConnection.swift` | Tmux bootstrap command + session policy |
| `AgenTTYHostRuntime.swift` | Canonical remote runtime paths and wrapper/binary contracts |
| `AgenTTYBuildFlavor.swift` | Flavor routing + compile-gated bootstrap policy/constants |
| `AgenTTYHost.swift` | Host model + runtime `AgenTTYConnectionTarget` mapping |
| `AgenTTYHostStore.swift` | Persisted host list + active host selection + bootstrap migration/pruning |
| `AgenTTYSSHKeyStore.swift` | Persisted key metadata + generate/import + bootstrap key reseed/pruning |
| `AgenTTYSSHKeyMaterialStore.swift` | Keychain private key storage + import parsing (Ed25519/ECDSA/RSA, PKCS#1/PKCS#8/SEC1/openssh-key-v1) + bootstrap key decode |
| `AgenTTYOpenSSHKeyDecryption.swift` | Decrypts passphrase-protected `openssh-key-v1` private sections (`aes256-ctr` + `bcrypt` only) |
| `BcryptPBKDF.swift` | `bcrypt_pbkdf` key derivation used by OpenSSH private-key decryption |
| `AgenTTYSSHPasswordStore.swift` | Keychain storage for temporary password bootstrap credentials |
| `AgenTTYTrustedHostKeyStore.swift` | TOFU trusted host-key persistence/reset |
| `NewShellWorkingDirectorySetting.swift` | Persisted toggle for reusing the rightmost shell working directory when creating new shells |
| `AgenTTYSSHRelayClient.swift` | Requests short-lived relay-backed SSH session URLs from the backend (10s request timeout) |
| `AgenTTYConnectionRouting.swift` | Direct-vs-relay route resolution, loopback target construction, and per-host route memory |
| `AgenTTYRelayBridge.swift` | Loopback-only local TCP bridge backed by the relay session websocket; off-main byte pump + periodic pings |
| `AgenTTYNetworkPathObserver.swift` | NWPathMonitor wrapper feeding path-change-driven reconnect/liveness into the bridge |
| `SSHClientSession.swift` | NIO SSH transport, PTY, channel lifecycle, and shell channel ownership |
| `SSHClientSessionSupport.swift` | SSH command builders and reconnect/error classification helpers, including negotiation-failure and connect-timeout classification |
| `SSHChannelHandlers.swift` | NIO channel handlers for shell I/O and exec output capture |
| `SSHAuthenticationDelegates.swift` | Mode-aware SSH auth (RFC 8332 signature-algorithm ladder) + TOFU host-key validation delegates |
| `AgenTTYSSHSessionOutcome.swift` | Disconnect categories, failure stages, and the negotiation-failure detail carried to recovery UI + analytics |
| `AgenTTYSSHRecoveryGuidance.swift` | User-facing recovery copy, including the four component-specific negotiation-failure cards |
| `SSH/Transport/AgenTTYSSHTransportProtectionSchemes.swift` | The advertised cipher list, in client preference order |
| `SSH/Transport/AgenTTYAESCTRTransportProtection*.swift` | `aes256-ctr` / `aes128-ctr` with HMAC-SHA2-256 (RFC 4253 encrypt-and-MAC) |
| `SSH/Transport/ChaCha20Poly1305TransportProtection.swift` | `chacha20-poly1305@openssh.com`, with local `Poly1305.swift` |
| `Ghostty/TerminalReconnectScreen.swift` | In-terminal reconnect screen renderer + presenter driven by `TerminalBridge` |
| `TerminalBridge.swift` | SSH↔Ghostty coordination, generation-aware inbound byte routing, reconnect policy, tmux polling, and shell-title orchestration |
| `TerminalBridgeSupport.swift` | Tmux parsing/command builders, shell-title persistence types, and bridge helper models |
| `AgenTTYHostRuntimeProvisioning.swift` | Base host runtime + notification runtime provisioning |
