# CI and release

## Public checks

`ci.yml` uses disposable hosted Linux and Xcode 27 runners. It executes all
three Rust test suites, shell wrapper checks, pairing CLI type checks/tests/
bundling, and unsigned iOS unit tests. It has no secrets or operator files.
Actions are pinned by full SHA; workflows never use pull_request_target.
Dependabot covers Actions, Cargo, Bun and Bundler. Weekly version updates are
grouped and use a one-day cooldown. Swift versions/revisions in
Project.swift and Package.resolved are updated together by a maintainer.

`just ios-check` and `just ios-test` are public entry points. They fetch the
reviewed GhosttyKit artifact, generate the workspace, install the canonical
package lock, and call the repo-owned build script. Headless commands allow
compiler macros from those reviewed, locked package revisions. TestFlight uses Xcode 27.1;
select the matching developer directory explicitly. Never weaken strict
concurrency to make a new toolchain compile. Public simulator tests select the
newest installed iOS runtime with an available iPhone; the maintainer
release preflight keeps its explicit local runtime contract and uses Xcode 27.2 RC
(27B48) on the maintainer Macs.

## Hosted release

An annotated bare MAJOR.MINOR.PATCH tag must point to a commit on main and be newer than
all other version tags and uploaded Apple versions. The first public tag is
2.12.0; read-only preflight observed live App Store 1.0.14 and highest
TestFlight 2.11.3. `check-release-version` reads fresh paginated ASC state and
refuses an equal/lower version before construction. `release.yml` rejects other versions, serializes
releases, runs CI, builds all runtime targets with source fingerprints, archives without signing,
and preserves a complete candidate. Publication extracts only the expected
archive/runtime directories in runner temporary storage before moving them into
the build directory. A separate publication job stages runtime
Sentry dSYMs with the tag as the release name, stages complete runtime assets
in a draft GitHub release, requests Xcode cloud signing/upload, then publishes
that release only after the upload succeeds. The release title is the bare version
and its notes are the annotated tag message verbatim. Its `testflight` environment provides the ASC credential trio:
APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_KEY_P8.
The private key exists only in runner temporary storage during read-only
version preflight and export.

Configure these environment variables explicitly: DEVELOPMENT_TEAM,
AGENTTY_BUNDLE_ID, AGENTTY_APP_GROUP, AGENTTY_CLOUDKIT_CONTAINER,
AGENTTY_KEYCHAIN_NAMESPACE, AGENTTY_UNLOCK_PRODUCT_ID, AGENTTY_RELAY_URL,
AGENTTY_ARTIFACT_URL and optional AGENTTY_SENTRY_DSN. The immutable GitHub
release base is derived from github.repository. The workflow writes ignored
Local.xcconfig from them. Official identifiers must exactly match previously
shipped apps, including their Keychain and iCloud boundaries.

Before enabling publication, configure GitHub's environment deployment rules
to allow only version tags, protect main and release tags, require CI, require
approval for outside contributors, enable secret scanning/push protection and
private vulnerability reporting, and remove repository self-hosted runners.
Workflow ancestry/version checks complement those repository settings.

Cloud-managed signing of the complete app/extension App Group and CloudKit
capability set remains an external acceptance gate until a hosted run succeeds.
Do not claim an unsigned archive proves export or TestFlight processing.
If cloud export cannot use the existing profiles, run the local
`just maintainer-testflight <version> <release-run-id>` fallback on a configured release Mac.
It verifies the run matches HEAD, reuses its already-built runtime candidate,
and uses the existing signing keychain and exact profiles through Fastlane,
then publishes the matching GitHub runtime release with the tag notes. It does not require a
runner attached to the public repository. This Apple/runtime fallback does not
perform npm publishing; that remains an OIDC-only hosted operation to recover
separately after inspecting the failed run.

## Host runtime and deployment boundary

`build-tmux-runtime.yml` runs manually or as a reusable release job and builds
all four Darwin/Linux ARM64/x86_64 tmux targets. The release job builds both
Rust helpers, checks source fingerprints, adds notices and packages a manifest,
per-target binaries, terminfo and SHA256SUMS. The immutable manifest lives at
`https://github.com/<owner>/<repo>/releases/download/<version>/host-runtime-manifest.json`.
New main-flavor apps resolve that tag's manifest; Dev/Exp use the configured
mutable artifact host. Older installed apps retain their previously compiled
URLs, whose existing immutable releases must remain available unchanged.

Tests, runtime construction and app compilation all pass before any release
assets are staged. The build job has read-only repository permissions; only the
separate publication job can write releases. The build job uses the ASC key
read-only for its version preflight, then removes the temporary key. A failure
before TestFlight upload removes only the draft this run created. GitHub and
App Store Connect cannot publish atomically: if Apple accepts an upload but a
later network call fails, inspect both services before retrying or tagging.
The workflow never automatically distributes to beta groups or submits review.

The Dev/Exp mutable-latest publication path remains maintainer-local.
`scripts/publish-host-runtime-artifacts` writes into an operator-owned static
host; public CI has no access to that filesystem or any live relay deployment.
`host-runtime-verify-release` separates missing (exit 3) from invalid (exit 1).
Only missing local releases can be created; mismatches require a new patch.

## App Store metadata and screenshots

The tag is MARKETING_VERSION, the TestFlight version and the App Store record's
version. `metadata.yml` is manual, runs on a version tag on main, takes no
separate version input, and uploads text only. Its preflight requires that tag
to be the newest uploaded TestFlight version and no lower than existing store
versions. Metadata may reuse that version's existing App Store record; building
or uploading an app still requires a version above every store and beta version.
No workflow submits for review.
Generated screenshots are ignored, and Fastlane refuses an explicitly requested
screenshot upload when no reviewed PNGs exist. Existing store screenshots are
preserved by default.

`just screenshots` uses an explicitly configured SSH fixture host and ignored
bootstrap credentials, then injects deterministic synthetic terminal/UI data.
Apple bezels, raw captures, generated exports and frontend dependencies stay
ignored. Visually inspect every exported scene before uploading it.

## Verification

Use `just --list`, `actionlint`, Ruby syntax checks, shell syntax checks and the
app/test compile appropriate to the change. Do not execute hosted macOS jobs
on a private staging repository merely to prove syntax. After publication,
prove anonymous checkout/dependency download, hosted CI, signed export,
TestFlight processing and device behavior as separate facts.

## npm pairing package

Only `@agentty-app/pair` is current; the app and docs use that name. Deprecate
`@agentty-app/host` at cutover with a pointer to pair; do not publish another
host package. The checked-in 0.0.0 is an inert placeholder. Release runs
`npm version "$VERSION" --no-git-tag-version`, builds/packs the exact checkout
before app publication, uses that same tag's immutable runtime manifest for
connector bootstrap, then publishes that tarball after the app/runtime
release with provenance and OIDC. No npm token is configured.

In npm package settings, configure GitHub trusted publisher user
`emileberhard`, repository `AgenTTY`, workflow `release.yml`, environment
`testflight`, allowing direct `npm publish`. Repository metadata must match the
public GitHub repository for provenance. Publishing cannot be proven before
that trust is configured and the repository is public. The current workflow
uses Node 24 and npm 11.6.2, which supports OIDC. Registry publication, Apple
upload and GitHub publication are separate service boundaries: inspect all
three after an uncertain failure rather than overwriting a version.

To recover npm after local signing or an npm outage, dispatch `release.yml` on
the same version tag with `release_run_id` set to the original run. This runs
only npm publication. It requires a published GitHub release and verifies the
candidate run's workflow, tag and commit before restoring its existing tarball;
it never rebuilds the package or repeats an Apple upload. Candidate artifacts
expire after three days, so recover before then.

## First public release checks

Create annotated tag 2.12.0 on the final main commit only after anonymous
checkout and hosted PR CI pass. Confirm the testflight environment permits
only version tags and contains all listed identity variables, SENTRY_ORG,
SENTRY_PROJECT, the ASC key trio and SENTRY_AUTH_TOKEN. No self-hosted runner
may be attached. Configure npm trust before pushing the tag.

Verify the run's unsigned archive, cloud-signing export for app and extension,
TestFlight processing at 2.12.0 with Apple's build number, complete GitHub
runtime assets/checksums/notices and exact tag notes, anonymous manifest and
payload downloads, npm pair@2.12.0 provenance/version, and Sentry 2.12.0 symbols.
Install the resulting TestFlight build and open a new SSH session to prove
runtime provisioning. Cloud signing and OIDC remain acceptance gates until
this first public run; none were exercised in the private staging repository.

Canonical public policy/support URLs are
`https://github.com/emileberhard/AgenTTY/blob/main/PRIVACY.md` and
`https://github.com/emileberhard/AgenTTY/blob/main/SUPPORT.md`. The cutover
agent redirects old Pages routes, updates ASC URLs and later archives the
redundant agentty-docs repository once old store versions no longer use it.
