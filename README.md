# AgenTTY

AgenTTY is a Ghostty-based SSH terminal for iPhone and iPad, built for working
with coding agents from your phone. It combines a native terminal renderer,
a keyboard with shell shortcuts, persistent tmux sessions, voice dictation,
and notifications when an agent finishes a turn. Requires iOS or iPadOS 26+.

## How it works

The app connects to your computer over SSH using a key stored in the iOS
Keychain. It installs an isolated runtime under `~/.agentty`, including tmux,
agent hooks, and a notification helper. Shells keep running on the host when
the phone disconnects. Direct SSH is preferred; automatically paired hosts can
also use an end-to-end SSH connection carried through the relay.

The custom keyboard supports modifier slide chords and a spacebar shell
switcher. You can use the system keyboard instead, or a hardware keyboard on
iPad. Themes apply to both the terminal and native chrome. Shortcuts can run
commands in the background or open a new shell.

## Connect a host

Choose Hosts in the app. Automatic Setup uses a short-lived QR code or pairing
code from the host:

```bash
npx -y @agentty-app/pair
```

Manual Setup exports your public key for `authorized_keys`. Password Setup
uses a password once to install a key, then saves the host with key authentication.
Host-key changes require your confirmation.

## Self-host

The app, relay, pairing CLI, notifier, and connector sources live here. An
Apple Developer account is needed to sign a device build with push, App Groups,
and CloudKit capabilities. Configure your own service endpoints and Apple
identifiers in the ignored `Config/Local.xcconfig`; example values never grant
access to the official services. See [Self-hosting](docs/self-hosting.md).

The official App Store build includes a five-hour foreground-use trial and a
one-time lifetime unlock. Dev and Exp builds bypass that gate. Developer AI
credentials and automatic bootstrap hosts are optional local inputs, excluded
from App Store builds and from this repository.

## Development

Use an Apple Silicon Mac with Xcode 27.1, Tuist 4.212.0 and Just. Rust helpers use `rust-toolchain.toml`;
the pairing CLI uses Bun 1.3.10. Dependencies are pinned in `Project.swift`,
`Package.resolved`, and the package lockfiles.

```bash
just ios-check             # unsigned simulator app build; no private configuration
just ios-test              # maintained iOS unit tests on the configured simulator
just backend-test          # relay tests
just notify-helper-test
just host-connector-test
just host-shell-test
cd tools/agentty-host && bun install --frozen-lockfile && bun test
```

The ordinary build downloads and verifies the reviewed GhosttyKit release
asset. Explicit vendor rebuilds use the pinned source and toolchain in the
Justfile. The macOS app target is an unvalidated scaffold.

[AGENTS.md](AGENTS.md) records ownership and invariants;
[docs/architecture.md](docs/architecture.md) explains the boundaries.
[Release instructions](docs/agent-guides/ci-pipeline.md) distinguish hosted
checks, TestFlight upload, operator deployment, and App Store submission.

## License, name and icon

AgenTTY-owned code is [PolyForm Shield 1.0.0](LICENSE), a source-available
license. Read, run, modify, self-host and redistribute it subject to its terms,
including its restriction on competing products. This is not an OSI open-source
license. The AgenTTY name and icon are reserved: distributed forks must use
their own branding.

Third-party components retain their own licenses. The full
[acknowledgements](THIRD-PARTY-NOTICES.txt) also ship in Settings and with the
managed host runtime. Ghostty, libxev, SpeechKit and the SSH fork retain their
respective upstream licenses.

## Privacy and security

[PRIVACY.md](PRIVACY.md) describes local storage, relay traffic, analytics,
dictation, notifications, Sentry, and the optional private iCloud library.

Report vulnerabilities privately through
[GitHub security advisories](https://github.com/emileberhard/AgenTTY/security/advisories/new).
Keep credentials, personal terminal content and host details out of public issues.

For help and private support, see [SUPPORT.md](SUPPORT.md).
