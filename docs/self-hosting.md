# Self-hosting

You need an Apple Silicon Mac with Xcode 27.1, Tuist 4.212.0, Just, an Apple Developer account,
and a reachable SSH host. Start with `just ios-check`; this unsigned simulator
build needs no private files. The simulator cannot establish device delivery,
push or cloud-signing behavior.

## App identity

Copy `Config/Local.xcconfig.example` to ignored `Config/Local.xcconfig`. Choose
your own team, reverse-DNS bundle ID, App Group, CloudKit container, Keychain
namespace and StoreKit product ID. The Dev/Exp/notification-extension suffixes
are derived from the base bundle ID. URLs in xcconfig use `https:/$()/host`
because `//` starts an xcconfig comment. Configure an optional Sentry DSN or
leave it empty. The signing commands reject example identities.

Register the app/extension IDs, App Group, APNs capability and CloudKit
container in your Apple account. Only containing apps receive CloudKit
entitlements; notification extensions do not. Select the appropriate profiles
in Xcode. Default signing is automatic; the `AGENTTY_*_SIGN_STYLE` and profile
settings support locally installed manual profiles. The optional library stays
off unless enabled in Settings. The official app's identifiers are not a
self-hoster's credentials or entitlement grants.

Generate the workspace with `tuist generate --no-open`, then
`./scripts/install-release-package-lock --install`. Open the workspace and run
`AgenTTY-iOS-Dev` on your signed device. Maintainer delivery recipes that use
private signing/install helpers are separate conveniences; they are not
prerequisites for `ios-check`, `ios-test`, or building in Xcode.

## Relay and artifacts

Use your own HTTPS backend and artifact endpoint in `AGENTTY_RELAY_URL` and
`AGENTTY_ARTIFACT_URL`. Set `AGENTTY_RELEASE_ARTIFACT_URL` to your GitHub
repository releases/download base for new main-flavor releases. Build/run the Rust backend with `just backend-dev`;
[backend.md](backend.md) documents configuration, APNs and API boundaries.
Provide your own APNs key, allowed app topics, server identity and optional
paid transcription provider credentials. Protect state and ingress, apply
resource limits, and publish your own privacy policy. Internal companion-app
broker scopes are not required for SSH use.

For a custom bundle ID, change `models::MAIN_BUNDLE_ID` in
`services/backend/src/models.rs` to match `AGENTTY_BUNDLE_ID` in your local app
configuration. Set `AGENTTY_BACKEND_APP_APPLE_ID` to your app's numeric App Store
ID for signed AppTransaction verification. The backend currently compiles its
accepted base bundle ID into the binary, so rebuild it after that change.

For main releases, use the tag-driven release workflow in your own public
repository. It builds all four runtime targets, packages checksums/notices and
attaches them to the same GitHub release as the app. Configure
`AGENTTY_RELEASE_ARTIFACT_URL` to that repository's releases/download base.
For Dev/Exp, build the pinned tmux and Rust helpers, set
`AGENTTY_HOST_RUNTIME_PUBLIC_ROOT` and `AGENTTY_HOST_RUNTIME_BASE_URL` to your
static host, then run `just host-runtime-publish-latest`. Existing immutable
static-host releases belong to older installed apps and must remain unchanged.
The app verifies every payload before installing it on an SSH host.

The pairing CLI accepts its own service configuration; run
`npx -y @agentty-app/pair --help` or build `tools/agentty-host` for your operator.
Normal direct SSH does not need a persistent relay connector, but interactive
shell setup still downloads the managed runtime from your configured host.

## Optional developer AI and bootstrap hosts

No AI key or SSH seed is needed to compile. Dev/Exp can read ignored
`AgenTTY/Resources/AgenTTYLocalSecrets.json` with optional `llmRouter` and
`sshBootstrap` objects. The router object supplies `origin` and `keyBase64`;
the bootstrap object supplies `host`, `label`, `username` and
`privateKeyRawBase64`, plus an optional `secondaryHost`. Use only credentials
you own and do not distribute these development builds publicly. Main builds
exclude that resource and both compile flags.

For the maintainer's existing router, `scripts/sync-local-llm-router-key` copies
a local key if present and otherwise leaves the secrets file unchanged. A local
key without `llmRouter.origin` fails the build instead of shipping without AI.
A worktree without its own secrets file first copies the main checkout's.
Generated screenshots and Apple device bezels are ignored; review synthetic
artwork locally before any explicit App Store upload.
