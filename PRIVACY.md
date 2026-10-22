# AgenTTY Privacy Policy

Last updated: 2026-10-22

This policy describes the official AgenTTY app and its operated services.
Self-hosted or modified builds can use different operators and providers;
check their configuration and policies. The controller for the official service
is Emil Eberhard, Sweden. Privacy and deletion requests can be sent to
[eberhard.emil@gmail.com](mailto:eberhard.emil@gmail.com).

## On your device and SSH hosts

AgenTTY stores saved host names, addresses, usernames, selected keys, trusted
host-key fingerprints, terminal preferences and connection state on your
device. Private SSH keys and temporary setup passwords are stored in the iOS
Keychain. Password Setup uses a password to install the selected public key,
then switches the saved host to key authentication. Keychain data can survive
an app reinstall.

Terminal sessions run on the SSH hosts you select. The managed `~/.agentty`
runtime stores tmux state, bounded agent-turn context for shell titles,
notification credentials, diagnostics and logs on those hosts. Commands you
run and files you upload are handled by your chosen host and its operator.
Removing the iOS app does not delete those remote files or terminate tmux.

## Relay, pairing and infrastructure

Automatic pairing, optional SSH relay transport, notifications, production
analytics and official enhanced dictation use the AgenTTY backend. It keeps
install/device identifiers, authentication records, APNs device tokens,
pairing records, connector identities, host connection metadata and usage
records needed to provide these features. Credentials are not published.
Pairing exchanges the public SSH key and connection candidates, which can
include your host's addresses and username. The CLI installs the public key
only after the pairing flow is completed.

New app versions send Apple's signed app transaction to verify eligibility for
hosted features. The backend verifies it, retains an environment-specific hash
of its app transaction identifier, and does not store the signed transaction.
Usage and bandwidth ledgers enforce service limits across devices and retries.

Direct connections go to your chosen SSH host. Relay connections carry the
SSH protocol over an authenticated relay connection; SSH encryption,
authentication and host-key checks remain between the app and the host.
The relay handles network addresses, timing and routing metadata, and does
not receive the SSH private key or decrypt the SSH terminal stream.

The official HTTPS endpoints use Cloudflare infrastructure. Apple provides
App Store, APNs and optional iCloud services. These providers process network
and service metadata under their own policies. Host-runtime and app dependency
download hosts also receive ordinary download request metadata.

## Usage analytics and purchases

The official production app sends app-session durations, access/trial state,
purchase/restore/paywall events, host-setup steps, SSH-session outcomes,
normalized failure categories, and coarse device information such as iOS
version, model, locale and preferred languages. Local host UUIDs are hashed.
The app obtains its app transaction identifier through StoreKit; the backend
hashes that identifier to link installs associated with the same App Store
user. This is pseudonymous data, not anonymous data. It is not an Apple ID,
email address or payment-card number. Apple handles payments.

Host-setup diagnostics can temporarily include detected usernames, selected
and candidate host addresses, disconnect reasons and error details. The
backend redacts these raw diagnostic fields after 14 days during startup or
subsequent ingestion. Hashed references and general usage records remain;
there is currently no automatic age-based deletion policy for general
analytics. Validation diagnostics store field/rule information and a redacted
payload shape; they are limited to 10,000 records and 14 days, with pruning
at startup and after ingestion. Dev/Exp builds and side-loaded builds without a verified App
Store app transaction do not emit production analytics.

## Dictation and AI

Enhanced dictation sends microphone audio and transcription instructions to a
speech provider. Instructions can include up to 400 recent lines of terminal
context to improve recognition of commands and paths. The official App Store
build uses the AgenTTY relay's OpenAI transcription proxy; audio and any
included transcription context pass through the relay to OpenAI. The relay
records quota/usage metadata, not an archival audio library. Provider data
handling and retention are governed by the provider's terms and account
settings; this policy does not promise zero provider retention.

Developer builds can use an operator-configured router to reach OpenAI,
ElevenLabs, Google Gemini, AssemblyAI or Azure transcription models. Depending
on the selected model and enabled context features, transcription instructions
can include vocabulary, shared dictionary entries and terminal-related context.
Developer shell-title generation can send bounded agent prompts/responses or
shell scrollback context to Gemini through the configured router. Shell-title
AI is disabled in the official production flavor. Do not enable a remote AI
feature for material you cannot share with its configured provider.

Provider recordings and temporary transcription files can exist locally while
capturing, retrying or recovering a result. Text inserted into a terminal is
sent to that SSH host, just like typed text.

## Optional private iCloud dictation library

WisprClone Library is off by default. If enabled, AgenTTY uses SpeechKit's
DictationLibrary to read your shared dictionary/profile and save original
recordings and independent result records into your private CloudKit database.
The official build uses the WisprClone container. This includes audio,
transcribed text, model/source metadata, timing and capture outcomes. These
records belong to your iCloud account; they are not published to other users.

AgenTTY keeps a bounded 512 MiB local producer spool and retains pending or
held originals when publication fails or account ownership is uncertain.
Changing iCloud accounts never assigns another account's captures to the new
account. Recording Recovery lets you confirm ownership of unverified captures.
The explicit Free Uploaded Local Audio action releases acknowledged local
originals; it does not delete the iCloud originals. Successful insertion into
the terminal does not by itself delete archival audio.

## Crash and operational diagnostics

The official app uses Sentry for crashes, hangs and selected operational
failures, with app/device/version data and connection/recovery breadcrumbs.
Production diagnostics can be linked to the hashed analytics identity.
Automatic screenshot and view-hierarchy attachments are disabled. Error
messages can include operational context; avoid putting secrets into host
labels or diagnostic reports. Self-hosted builds can omit the Sentry DSN.
Sentry retention follows the operator's configured Sentry project policy.

## Notifications

With notification permission, the app registers its APNs token with the relay.
Agent hooks can send a title, message and routing metadata through the
notification helper, AgenTTY backend and Apple APNs. Notification text may
contain agent responses or prompt-derived summaries and may appear on your
Lock Screen according to iOS settings. The Notification Service Extension
records delivery diagnostics. You can disable alerts in iOS Settings.

## Your choices and deletion

You can remove saved hosts and keys, turn off enhanced dictation or library
sharing, revoke notification permission, and use your own builds and services.
Turning a feature off stops future use of it; it does not erase earlier
provider, host, iCloud or server records. Contact the official operator for
server-data access or deletion, and provide enough information to identify
your installation without posting credentials publicly. For self-hosted
services, contact that service's operator. Manage private library data through
the library's controls and your iCloud account.

AgenTTY does not sell personal information or use advertising trackers.
Processing is for requested terminal/relay/AI features, purchase verification,
usage limits, support, reliability and abuse prevention. Data can be processed
outside your country by the listed infrastructure and AI providers.
