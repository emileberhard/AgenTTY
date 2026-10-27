# CI and release

## Public checks

`ci.yml` runs on pushes to `main` and on pull requests, on disposable hosted
runners with no secrets or operator files. It executes the three Rust test
suites and the shell wrapper checks, the pairing CLI type check, tests and
bundle, the release tooling tests in `scripts/tests`, the iOS unit tests, and
an unsigned archive of the Release configuration, so a compile error in
anything the release builds fails CI instead of the release. Apple jobs select
the Xcode that `.xcode-version` names with `scripts/select-xcode` and fail when
the runner lacks it.

Actions are pinned by full SHA, workflows default to a read-only token and
never use `pull_request_target`. Dependabot covers Actions, Cargo and Bun;
weekly version updates are grouped and use a one-day cooldown. Swift package
revisions are updated together in the project and its `Package.resolved` by a
maintainer.

`just ios-check` and `just ios-test` are the local entry points to
`scripts/ios-public`, which fetches the reviewed GhosttyKit artifact and builds
from the committed project and lock only. Headless commands allow compiler
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
   that its annotation has release notes, then waits for the successful push CI
   run of the same commit. It never reruns CI.
2. `tmux` builds the four tmux runtimes, and `npm-candidate` builds the tagged
   pairing package. Neither holds release credentials.
3. `testflight` reserves one build number above every App Store Connect build
   and pending upload, builds the host helpers and the complete runtime,
   archives unsigned with the tag as `MARKETING_VERSION`, ad-hoc signs each
   bundle with its entitlements (`Config/entitlements.json`), uploads the Sentry
   symbols, exports through Xcode cloud signing, checks the exported
   entitlements and uploads. Its build-number output makes the later jobs select
   that exact build, also on retries.
4. `testflight-review` sets What to Test from the tag message. The workflow
   never distributes to beta groups or submits for beta review.
5. `app-store` prepares the App Store version with manual release, short of App
   Review: it applies `AppStore/metadata/<locale>/*.txt` (description, keywords,
   promotional text, support URL, and the app's name, subtitle and privacy URL),
   sets What's New from the tag message from the second release on, places the
   screenshots in `AppStore/screenshots/<placement group>/` when present,
   and attaches the build. A version in review is left pending with a notice.
6. `github-release` attaches the runtime to the release it publishes, titled
   with the bare version, with the annotated tag message verbatim as its notes,
   and marks it Latest only while it is the newest version tag.
7. `npm` publishes the candidate with OIDC and provenance.

Submitting for App Review and releasing on the App Store stay manual. Rerun a
transiently failed job from the tag's own run, only while that tag is still the
newest version; a fix ships as the next patch. Candidate artifacts expire after
three days.

## Environment setup

The `testflight` environment, limited to version tags, holds the variables
`DEVELOPMENT_TEAM`, `AGENTTY_BUNDLE_ID`, `AGENTTY_APP_GROUP`,
`AGENTTY_CLOUDKIT_CONTAINER`, `AGENTTY_KEYCHAIN_NAMESPACE`,
`AGENTTY_UNLOCK_PRODUCT_ID`, `AGENTTY_RELAY_URL`, `AGENTTY_ARTIFACT_URL`,
`SENTRY_ORG` and optionally `AGENTTY_SENTRY_DSN` and `SENTRY_PROJECT`, and the
secrets `APP_STORE_CONNECT_KEY_P8` (the P8 file's contents),
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and
`SENTRY_AUTH_TOKEN`. `scripts/configure-hosted-release` writes the ignored
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

## Host runtime and deployment boundary

`build-tmux-runtime.yml` runs manually or as a reusable release job and builds
all four Darwin/Linux ARM64/x86_64 tmux targets. The `testflight` job builds
both Rust helpers, checks source fingerprints, adds notices and packages a
manifest, per-target binaries, terminfo and SHA256SUMS. The immutable manifest
lives at
`https://github.com/<owner>/<repo>/releases/download/<version>/host-runtime-manifest.json`.
New main-flavor apps resolve that tag's manifest; Dev/Exp use the configured
mutable artifact host. Older installed apps retain their previously compiled
URLs, whose existing immutable releases must remain available unchanged.

The runtime is built and checksummed before the app is exported, and the
release that publishes it follows a successful TestFlight upload; the build
jobs hold read-only repository permissions and only `github-release` can write.
GitHub and App Store Connect cannot publish atomically: if Apple accepts an
upload but a later job fails, inspect both services and rerun that job.

The Dev/Exp mutable-latest publication path remains maintainer-local.
`scripts/publish-host-runtime-artifacts` writes into an operator-owned static
host; public CI has no access to that filesystem or any live relay deployment.
`host-runtime-verify-release` separates missing (exit 3) from invalid (exit 1).
Only missing local releases can be created; mismatches require a new patch.

## App Store text and screenshots

`AppStore/metadata/en-US/*.txt` is the committed text; edit it and the next tag
applies it. Differences from the store are the only writes, and an app info that
is not editable keeps its name, subtitle and privacy URL.

`just screenshots` uses an explicitly configured SSH fixture host and ignored
bootstrap credentials, injects deterministic synthetic terminal/UI data, composes
the marketing slides, validates their dimensions and copies the captured device
sets into `AppStore/screenshots/<placement group>` (`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`,
`IPAD_13_PROFILE`). Visually inspect every exported scene, then commit the
sets. The release replaces only the placement groups present there and
otherwise leaves the version's existing screenshots. Apple bezels, raw captures,
generated exports and frontend dependencies stay ignored.

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
rerun the `npm` job from the newest tag's run (the candidate lives three days),
or publish with the next tag.

Canonical public policy/support URLs are
`https://github.com/emileberhard/AgenTTY/blob/main/PRIVACY.md` and
`https://github.com/emileberhard/AgenTTY/blob/main/SUPPORT.md`. The cutover
agent redirects old Pages routes, updates ASC URLs and later archives the
redundant agentty-docs repository once old store versions no longer use it.
