# AgenTTY

Ghostty-based SSH terminal for iPhone and iPad, iOS 26+. Read
[docs/architecture.md](docs/architecture.md), its goals, decisions and what is
expensive to change, before changing a boundary. `CLAUDE.md` links to this file.

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
| `iOS/Capture.swift`, `AppStore` | Debug capture catalog and fixtures, the simulator capture driver, the slide composer and the App Store text per locale |

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
  aborting after 120 seconds if busy. Shutdown allows ten seconds for SSH and
  forty for HTTP within the container's sixty-second stop grace period.
- Analytics are production-only. Never log credentials, SSH private keys,
  audio or terminal contents as diagnostics. Unknown delivery remains unknown;
  do not blindly retry externally visible side effects.
- `THIRD-PARTY-NOTICES.txt` is the authoritative combined notice file. Its
  resource symlink feeds Settings and remote runtime installation; the npm
  build copies it into its package. Refresh it when redistributed inputs change.

## Commands and verification

Use the Justfile (`just` lists it); do not invoke xcodebuild directly. Load the
local `swift-development` skill if available before Swift/build/install work.

| Command | Checks or produces |
| --- | --- |
| `just build` | Unsigned Dev simulator build without private configuration |
| `just test [Suite...]` | iOS unit tests (Swift Testing) on the newest installed simulator runtime |
| `just ui-previews [--device ipad] [--appearance light] [screen...]` | `.local/ui-previews/sheet.jpg` of every `CaptureScreen`; read it after each UI change |
| `just screenshots` | The App Store slides in `.local/screenshots`, captured on fresh simulators as the release does |
| `just test-backend`, `just test-notify-helper`, `just test-host-connector`, `just test-host-shell` | Backend, host helper and shell wrapper checks |
| `cd tools/agentty-host && bun install --frozen-lockfile && bun run test` | Pairing CLI checks |
| `python3 -m unittest discover -s scripts/tests` | Release tooling checks |
| `ARCHIVE_PATH=<new path> scripts/ios-public archive` | The unsigned Release archive that CI and the release build |
| `just install-dev [UDID]`, `just build-dev` | Maintainers: the signed Dev app on the paired iPhone, or a retained checkpoint without a phone; `just delivery=mdm …` forces SimpleMDM |

Maintainers install output-affecting app changes with `just install-dev`;
`install-exp` and `install-main` are explicit choices. Paired-device work runs
on the connected host. Builds, captures and the host runtime write to the
checkout's ignored `.local/`, and `scripts/prepare-local-inputs` copies missing
ignored inputs from the main checkout into a worktree. Docs-only changes skip
app installation. Compilation, test execution, installation, launch and
real-world acceptance are separate evidence.

GhosttyKit is an ignored, checksum-pinned release download.
`scripts/ghostty-xcframework ensure` fetches and verifies it before app commands; ordinary CI never rebuilds Ghostty or
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
every pushed tag and rejects anything but that tag; `admit` then waits for
`main`'s CI on the same commit. `backend` deploys first. `runtime` and
`npm-candidate` build without release credentials, `numbers` reserves the build
number and `archive` builds unsigned and ad-hoc signs embedded frameworks
deepest first, then app bundles. `testflight` waits until the backend's
`/healthz` reports the tag or newer, exports once through Xcode cloud signing,
checks that export's entitlements and framework signatures, and uploads exactly
it with `altool` behind a step-history fence. `screenshots` captures the
slides without credentials alongside `archive`. `testflight-notes` sets What to
Test, `app-store` applies `AppStore/` and those slides to the prepared version
and submits it for App Review, `github-release` publishes the tag message
verbatim with the runtime assets, and `npm` publishes the pairing package with
OIDC and provenance. App Store release stays manual. Rerun failed
jobs from the tag's own run while it is still the newest version; a fix ships
as the next patch. See the [CI guide](docs/agent-guides/ci-pipeline.md).

Work in a locked worktree and preserve other agents' work. The task brief sets
integration authority; do not merge, deploy or publish when assigned a
review-only or implementation-only scope. Keep these instructions and affected
guides accurate in the same change.

## Backend deployment and host moves

The backend runs as a single writer on Linux. Its state is under
`/srv/services/agentty-backend`, with SQLite snapshots in the host service-state
backup using the SQLite backup API. Stage its policy and hook with
`services/backend/deploy/install-backup ABSOLUTE_STAGING_DIRECTORY`, then
install them under the host backup lock. Secrets are provisioned separately as
service-user-only files.
The public repository never runs on a self-hosted runner: its tag job joins
the tailnet using its dedicated federated identity and invokes the forced SSH
gateway with only a version. The gateway fetches and verifies the annotated
tag and main ancestry itself, then runs the checked-out deployment. When manually
bootstrapping the rootless container as the service user, first change directory
to `/var/lib/agentty-runtime` so Docker Compose can access its working directory.
The SSH account uses `services/backend/deploy/systemd/sshd-agentty.conf` and a
root-owned authorized-keys file with a restricted forced-command key. Before
switching images, deployment checks an isolated SQLite copy and drains live
sessions; rollback never replaces accepted state with an old snapshot.

To move hosts, restore the state directory, provision the same secrets and
service configuration, then deploy the verified version tag. Move the dedicated
tunnel and federated SSH target only after the restored service is healthy.
