# CI and release

## Public checks

`ci.yml` runs on pushes to `main` and on pull requests, on disposable hosted
runners with no secrets or operator files. It executes the three Rust test
suites and the shell wrapper checks, builds the deployed backend image without
pushing it, runs the pairing CLI type check, tests and bundle, the release
tooling tests in `scripts/tests` and the iOS unit tests, compiles the live LLM
integration tests without running them, and archives the Release configuration
unsigned, so a compile error in anything the release builds fails CI instead of
the release. When `AppStore/`, `Capture.swift`, `.xcode-version` or `ci.yml`
change, `capture` also runs the release's screenshot capture on fresh
simulators. Apple jobs select
the Xcode that `.xcode-version` names with `scripts/select-xcode` and fail when
the runner lacks it.

Actions are pinned by full SHA, workflows default to a read-only token and
never use `pull_request_target`. Dependabot covers Actions, Cargo, Bun and the
backend image;
weekly version updates are grouped and use a one-day cooldown. Swift package
revisions are updated together in the project and its `Package.resolved` by a
maintainer.

`just build` and `just test` are the local entry points to
`scripts/ios-public`, which fetches the reviewed GhosttyKit artifact and builds
from the committed project and lock only, in the checkout's
`.local/DerivedData`. It resolves packages again whenever `Package.resolved`
changes. Headless commands allow compiler
macros from those reviewed, locked package revisions. Never weaken strict
concurrency to make a new toolchain compile. Public simulator tests select the
newest installed iOS runtime with an available iPhone.

## Tag release

An annotated bare MAJOR.MINOR.PATCH tag on `main`, newer than every other
version tag, is the version everywhere: app, TestFlight, App Store version,
GitHub release, host runtime, npm pairing package, Rust build identity and
Sentry release. Manifest versions of 0.0.0 are inert placeholders. Tag the
commit a push to `main` ended on, after its CI passed.

`release.yml` runs on every tag push and fails visibly on a wrong one:

1. `admit` checks the tag, that it is the newest version and on `main`, and
   that its annotation is a Markdown list of release notes, then waits for the successful push CI
   run of the same commit. It never reruns CI.
2. `backend` deploys the tag to the Linux host over the tailnet (see
   [backend deployment](../backend.md)). The app, the GitHub release and the
   npm package all need it, so no client ships before its server.
3. `runtime` calls `build-host-runtime.yml`: its `tmux` jobs build the four tmux
   targets, then its packaging job builds both Rust helpers, verifies source
   fingerprints and checksums the complete runtime. It has no release environment
   or credentials. `npm-candidate` builds the tagged pairing package alongside it.
4. `numbers` refuses a version that is already released or below a released App
   Store or uploaded TestFlight version, then reserves one build number above
   every App Store Connect build and pending upload. A rerun of the same tag
   passes and keeps the reservation.
5. `archive` archives unsigned with the tag as `MARKETING_VERSION` and the
   reserved build number, and ad-hoc signs embedded frameworks from the inside
   out and then each app bundle with its entitlements (`Config/entitlements.json`).
   It holds no App Store Connect key. A tar artifact preserves the archive's
   permissions, signatures and symlinks.
6. `testflight` joins the build jobs and the backend. GitHub's step history
   fences any earlier attempt that started `Upload to TestFlight`: such a rerun
   reuses that build, or waits up to 15 minutes for Apple to list it, and never
   uploads again. Otherwise it restores the same-run archive, waits until the
   public `/healthz` reports this version or newer, uploads the Sentry symbols,
   exports once through Xcode cloud signing, checks that export's entitlements,
   versions and every embedded framework's Apple Distribution signature, and
   uploads exactly that IPA with `altool`. Its build-number output makes the
   later jobs select that exact build.
7. `testflight-notes` sets What to Test from the tag message. The workflow
   never distributes to beta groups or submits for beta review.
8. `app-store` captures fresh screenshots (`AppStore/capture app-store`) and
   prepares the App Store version with manual release: it applies
   `AppStore/metadata/<locale>/*.txt` (description, keywords, promotional text,
   support URL, and the app's name, subtitle and privacy URL), sets What's New
   from the tag message from the second release on, replaces the screenshots of
   every captured placement group and attaches the build, then, once the app
   has a release, submits it for App Review, withdrawing an older version still
   in review.
9. `github-release` attaches the complete runtime in its `gh release create`
   call, which stages the assets before publication. The release uses the bare
   version, the annotated tag message verbatim as its notes, and Latest only
   while it is the newest version tag. Published assets are immutable. A retry
   skips a published release with the same title and notes, and fails on a
   mismatch without editing it.
10. `npm` publishes the candidate with OIDC and provenance.

The workflow-wide `testflight` concurrency group covers build-number reservation,
archive handoff and upload, with cancellation disabled. Splitting jobs therefore
does not admit overlapping release uploads. Every checkout uses the triggering
commit; downloads stay in the same run. Release credentials remain in the jobs
that reserve numbers, sign or publish; the archive and runtime builds receive
only the read-only Actions token.

The first App Review submission and every App Store release stay manual. Rerun
the failed jobs of the tag's own run, only while that tag is still the newest
version; the upload fence makes that safe after an upload. A fix ships as the
next patch. Candidate artifacts expire after 30 days.

## Environment setup

The `testflight` environment, limited to version tags, holds the variables
`DEVELOPMENT_TEAM`, `AGENTTY_BUNDLE_ID`, `AGENTTY_APP_GROUP`,
`AGENTTY_CLOUDKIT_CONTAINER`, `AGENTTY_KEYCHAIN_NAMESPACE`,
`AGENTTY_UNLOCK_PRODUCT_ID`, `AGENTTY_RELAY_URL`, `AGENTTY_ARTIFACT_URL`,
`SENTRY_ORG` and optionally `AGENTTY_SENTRY_DSN` and `SENTRY_PROJECT`, and the
secrets `APP_STORE_CONNECT_KEY_P8` (the P8 file's contents),
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and
`SENTRY_AUTH_TOKEN`. The `agentty-backend-production` environment, also limited
to version tags, holds `AGENTTY_DEPLOY_SSH_KEY`; the repository variables
`AGENTTY_DEPLOY_TARGET`, `AGENTTY_DEPLOY_HOST_KEY`, `AGENTTY_TS_CLIENT_ID` and
`AGENTTY_TS_AUDIENCE` name the forced-command SSH account, its host key and the
tailnet identity. `scripts/configure-hosted-release` writes the ignored
`Config/Local.xcconfig` from the variables. Official identifiers must exactly
match previously shipped apps, including their Keychain and iCloud boundaries.
The App Group and capabilities must be registered on the portal for the app and
extension App IDs.

`repo-baseline` owns the repository settings: rulesets that let only the owner
create immutable tags, a protected default branch, SHA-pinned actions, a
read-only default token, secret scanning, outside-contributor approval and
private vulnerability reporting. No self-hosted runner is ever attached to this
public repository. The private key exists only in runner temporary storage
during the jobs that call App Store Connect.

Registry publication, Apple upload and GitHub publication are separate service
boundaries: after an uncertain failure inspect all three before retrying.

## Host runtime

`build-tmux-runtime.yml` runs manually or as a reusable release job and builds
all four Darwin/Linux ARM64/x86_64 tmux targets. The `runtime` job builds
both Rust helpers, checks source fingerprints, adds notices and packages a
manifest, per-target binaries, terminfo and SHA256SUMS. The immutable manifest
lives at
`https://github.com/<owner>/<repo>/releases/download/<version>/host-runtime-manifest.json`.
New main-flavor apps resolve that tag's manifest; Dev/Exp use the configured
mutable artifact host. Older installed apps retain their previously compiled
URLs, whose existing immutable releases must remain available unchanged.

Changes to the three release workflows also exercise the complete reusable
host-runtime build on pull requests with version `0.0.0`, alongside ordinary
unsigned iOS CI. That path has no release credentials and publishes no release.

The runtime is built and checksummed before the app is exported, and the
release that publishes it follows a successful TestFlight upload; the build
jobs hold read-only repository permissions and only `github-release` can write.
GitHub and App Store Connect cannot publish atomically: if Apple accepts an
upload but a later job fails, inspect both services and rerun that job.

Dev, Exp and development pairing CLIs read the mutable latest channel on R2.
`just publish-host-runtime` builds the platform artifacts on the Mac and
publishes to the bucket configured by `~/.config/agentty-r2/rclone.conf`; a
missing config fails publication. The bucket token is scoped to that bucket and
readable only by the publisher. Self-hosters set
`AGENTTY_HOST_RUNTIME_PUBLIC_ROOT` to publish to their own static host instead.
The publisher serializes publication, checks existing release bytes, uploads and
verifies every payload before its manifest, and replaces `latest.json` last.
`latest.json` uses no-cache and release objects are immutable. The latest
channel retains its current and 16 previous releases, and publication reports
an error if the bucket exceeds 20 GiB. It no longer writes versioned releases;
the existing semver objects stay for the installed apps that compiled their
URLs.

The publisher updates a public index of retained releases. A Linux timer pulls
its manifests and checksum-verified payloads and replaces the mirror under the
service backup lock, and the `agentty-assets` selective backup verifies and
saves the mirrored manifest-referenced files.

## App Store text and screenshots

`AppStore/metadata/en-US/*.txt` is the committed text; edit it and the next tag
applies it. Differences from the store are the only writes, and an app info that
is not editable keeps its name, subtitle and privacy URL.

The `app-store` job captures the screenshots fresh with
`AppStore/capture app-store`: on new simulators deleted afterwards, the app
renders the dark `terminal`, `themes`, `hosts`, `switch-hosts` and `keys`
`CaptureScreen`s from its Debug fixture, and `AppStore/compose.swift` frames
them with the marketing copy into the `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`
(iPhone 18 Pro Max) and `IPAD_13_PROFILE` placement groups. The composer fails
on a wrong size, a transparent pixel or two identical slides. The release
replaces only the captured placement groups. `just screenshots` runs the same
capture into `.local/screenshots`; look at the slides before tagging a change
to them.

## Verification

Use `just --list`, `actionlint`, shell syntax checks, `python3 -m unittest
discover -s scripts/tests` and the app/test compile appropriate to the change.
Do not execute hosted macOS jobs on a private staging repository merely to prove
syntax. After a release, read back separately: the TestFlight build version,
build number and entitlements, the prepared App Store version, the GitHub
release with its runtime assets, the npm package and the Sentry release.

## npm pairing package

Only `@agentty-app/pair` is current; the app and docs use that name. Deprecate
`@agentty-app/host` at cutover with a pointer to pair; do not publish another
host package. Release runs `npm version "$VERSION" --no-git-tag-version`,
builds and packs the exact checkout before app publication, and uses that same
tag's immutable runtime manifest for connector bootstrap. The `npm` job then
publishes that tarball after the GitHub release with provenance and OIDC. No
npm token is configured.

In npm package settings, configure the GitHub trusted publisher: user
`emileberhard`, repository `AgenTTY`, workflow `release.yml`, environment
`testflight`, allowing direct `npm publish`. Until that trust exists the `npm`
job fails with ENEEDAUTH and everything else still ships. After setting it up,
rerun the `npm` job from the newest tag's run (the candidate lives 30 days),
or publish with the next tag.

Canonical public policy/support URLs are
`https://github.com/emileberhard/AgenTTY/blob/main/PRIVACY.md` and
`https://github.com/emileberhard/AgenTTY/blob/main/SUPPORT.md`. The cutover
agent redirects old Pages routes, updates ASC URLs and later archives the
redundant agentty-docs repository once old store versions no longer use it.
