# AgenTTY

Ghostty-based SSH terminal for iPhone and iPad, iOS 26+. The macOS target is a
scaffold. Read [docs/architecture.md](docs/architecture.md) before changing a
boundary. `CLAUDE.md`, `GEMINI.md` and `LLMS.md` link to this file.

## Ownership

| Path | Owns |
| --- | --- |
| `Common/Ghostty`, `iOS/Terminal*` | Ghostty runtime, SSH-to-renderer bridge, terminal lifecycle and geometry |
| `Common/SSH`, `Common/Config` | SSH transports, saved hosts, Keychain keys/passwords, trust and routing |
| `iOS/Keyboard` | Input encoding, touch/hardware keyboards, dictation and library consent/spool |
| `Common/Notifications` | App-side relay APIs, verified artifact cache and atomic host provisioning |
| `Common/Access`, `Common/Analytics` | StoreKit entitlement/trial policy and production analytics outbox |
| `NotificationsShared`, `NotificationServiceExtension` | Notification parsing and delivery traces |
| `tools/agentty-host` | Pairing CLI, public-key installation and connector bootstrap |
| `tools/agentty-notify`, `tools/agentty-host-connector` | Host hooks/notifications and persistent SSH relay connector |
| `services/backend` | Pairing, device identities, relay, APNs, analytics and paid transcription admission |
| `AgenTTY.xcodeproj`, `Config`, `Justfile`, `scripts` | The committed JSON Xcode project and its package lock, build identity, entitlements, Info.plists, commands and release tooling |
| `AppStore` | Committed App Store text per locale and the reviewed screenshots per placement group, applied by the release |

App source paths above are relative to `AgenTTY/Sources`.

## Invariants

- Swift 6 strict concurrency and memory safety stay enabled. Fix ownership
  instead of suppressing diagnostics. Use Observation, `@State`, `@Bindable`
  and environment injection; no ObservableObject/Published compatibility path.
- Ghostty C API calls run on MainActor, except
  `ghostty_surface_write_pty_output`, which runs on the terminal I/O queue to
  avoid renderer mutex deadlock. Retain C callback userdata before actor hops.
- `TerminalBridge` owns connection generations. Discard stale async results.
  `AgenTTYHostConnectionPhase.allowsHostInteraction` gates host actions.
  Send focus pulses only after `.connected`, never during tmux attachment.
- Host-key validation is strict TOFU with mismatch rejection. Private keys
  stay in Keychain. Password bootstrap ends after installing a public key.
  Relay transport never weakens SSH authentication or trust checks.
- Managed remote files use a unique sibling temporary file, exact length and
  SHA-256 verification, permissions, then atomic replacement. Runtime versions
  alone do not prove payload integrity. Keep the tmux safety patches applied.
- `KeyboardPresentationPolicy` is the one keyboard-surface decision owner.
  Keyboard content never ignores the bottom safe area. Shared theme tokens,
  VisualLayering and sheet components own presentation policy.
- Main flavor contains no bootstrap payload or embedded AI credential and
  never compiles the local main-unlock flag in a release. Dev/Exp secrets are
  optional, ignored local input. Preserve official app identities and storage
  namespaces when changing build configuration.
- The trial counts foreground usage with monotonic time. A verified lifetime
  entitlement cannot be downgraded by an entitlement lookup miss.
- Dictation library sharing defaults off. Account changes never adopt another
  account's captures. Keep unpublished originals durable; insertion success
  and provider-cache cleanup are not permission to delete archival originals.
- The backend owns hosted admission and persistent service budgets, and meters
  dictation audio before forwarding it. llm-router owns the speech provider
  credential and routing; the app never holds a provider or router key. Keep
  notification and dictation credentials scoped separately; SSH trust remains
  app-to-host. Preserve explicit compatibility lanes until their documented
  rollout condition is satisfied. Deploys fence and wait for idle SSH,
  aborting after 120 seconds if busy. Host shutdown allows ten seconds for SSH
  and forty for HTTP within the loaded sixty-second launchd exit limit.
- Analytics are production-only. Never log credentials, SSH private keys,
  audio or terminal contents as diagnostics. Unknown delivery remains unknown;
  do not blindly retry externally visible side effects.
- `THIRD-PARTY-NOTICES.txt` is the authoritative combined notice file. Its
  resource symlink feeds Settings and remote runtime installation; the npm
  build copies it into its package. Refresh it when redistributed inputs change.

## Commands and verification

Use the Justfile; do not invoke xcodebuild directly. Load the local
`swift-development` skill if available before Swift/build/install work.

- `just ios-check`: public unsigned simulator build.
- `just ios-test`: maintained unit tests on the configured iOS simulator.
- `ARCHIVE_PATH=<new path> scripts/ios-public archive`: the unsigned Release
  archive of the shipping app, the compile CI and the release run.
- `python3 -m unittest discover -s scripts/tests`: release tooling checks.
- `just backend-test`, `just notify-helper-test`, `just host-connector-test`,
  `just host-shell-test`: checks for their respective components.
- `cd tools/agentty-host && bun install --frozen-lockfile && bun run test`:
  pairing CLI checks.
- Maintainers: `just ios-build-install-dev` for output-affecting app changes;
  use `just ios-build-dev` if the phone is unreachable. Main/Exp installs are
  explicit choices. Paired-device work runs on the connected host.
- Docs-only changes skip app installation. Compilation, test execution,
  installation, launch and real-world acceptance are separate evidence.

GhosttyKit is an ignored, checksum-pinned release download. `_ensure-xcframework`
fetches/verifies it before app commands; ordinary CI never rebuilds Ghostty or
fetches LFS. Preserve `scripts/ghostty-artifact.json` and
`docs/licenses/GhosttyKit-NOTICES.txt`. Copy the complete Ghostty notices into
the authoritative combined notice file whenever that asset changes.

The committed project is the source of truth: edit `project.xcproj` as JSON or
in Xcode, and keep the app's `Package.resolved` in
`AgenTTY.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. Builds read only
that lock, so an upgrade is a reviewed change to it and to the pins in the
project. `.xcode-version` names the Xcode that CI and the release build with.
Build outputs, operator files and local configuration remain ignored. Do not
add code comments except required notices.

## Guides

Read the relevant guide before tracing or changing that subsystem. Keyboard,
touch, overlay and theme work needs both keyboard and surface guides.

- [Ghostty integration](docs/agent-guides/ghostty-integration.md)
- [SSH and tmux](docs/agent-guides/ssh-session.md)
- [Keyboard and dictation](docs/agent-guides/keyboard-architecture.md)
- [Surface, touch and lifecycle](docs/agent-guides/ios-surface-and-touch.md)
- [SSH fork](docs/agent-guides/nio-ssh-fork.md)
- [CI and release](docs/agent-guides/ci-pipeline.md)
- [Diagnostics](docs/agent-guides/observability-and-debugging.md)
- [Backend contract](docs/backend.md)

## Release boundaries

`main` is canonical; the Dev app flavor does not imply a staging branch.
Public PR CI has no secrets and runs on disposable GitHub-hosted runners.
Never attach a personal/self-hosted runner to the public repository.

A bare annotated MAJOR.MINOR.PATCH tag on main, newer than every other version
and every uploaded App Store/TestFlight version, is the version everywhere:
app, TestFlight, App Store metadata, GitHub release, host runtime, npm pairing
package, Rust build identity and Sentry release. Manifest versions of 0.0.0 are
inert development placeholders, never manually bumped. `release.yml` runs on
every pushed tag and rejects anything but that tag; `admit` then waits for `main`'s
CI on the same commit. `testflight` builds the complete runtime and the unsigned
archive, ad-hoc signs each bundle, exports through Xcode cloud signing with the
`testflight` environment's ASC key, checks the entitlements and uploads with a
build number reserved from App Store Connect. `testflight-review` sets What to
Test, `app-store` applies `AppStore/` to the prepared version, `github-release`
publishes the tag message verbatim with the runtime assets, and `npm` publishes
the pairing package with OIDC and provenance. App Review stays manual.
Rerun a transiently failed job from the tag's own run while it is still the
newest version; a fix ships as the next patch. See the CI guide for setup.

Work in a locked worktree and preserve other agents' work. The task brief sets
integration authority; do not merge, deploy or publish when assigned a
review-only or implementation-only scope. Keep these instructions and affected
guides accurate in the same change.
