# Backend

`services/backend/` is the Rust relay backend for AgenTTY notifications, automatic host pairing, relay-backed SSH fallback, main-flavor dictation proxying, analytics, and trusted companion-client APNs brokering.

## Local Development

```bash
just backend-dev
just backend-test
just backend-build
```

The local runner lives at `services/backend/scripts/run-backend`. Production deployment is operator-owned and intentionally not tracked in the public tree.

## Deployment Contract

A production deployment needs:
- a public backend base URL for app and host-helper clients
- APNs signing credentials
- backend storage path for SQLite
- any companion-client bearer tokens
- optional OpenAI configuration for main-flavor dictation proxying
- a separate static artifact host for host-runtime payloads

Repo-tracked deploy entrypoints are intentionally generic:
- `just backend-reload-local` requires `AGENTTY_BACKEND_DEPLOY_SCRIPT`
- `just backend-deploy-local` requires `AGENTTY_BACKEND_DEPLOY_SCRIPT`
- `just host-runtime-deploy-local` requires `AGENTTY_HOST_RUNTIME_DEPLOY_SCRIPT`

Those env vars should point at ignored, operator-owned scripts.

## Host Runtime

AgenTTY no longer bundles host runtime binaries in the app. The app fetches a manifest and platform-specific payload from the configured artifact host, verifies SHA-256, caches the bytes locally, and uploads them to the SSH host under `~/.agentty/`.

Publish commands:
```bash
just notify-helper-rebuild
just host-connector-rebuild
just tmux-runtime-rebuild
just host-runtime-publish-latest
just host-runtime-publish-release <version>
```

`HostRuntimeArtifacts/bin/**` is generated and ignored. Before publishing, `scripts/publish-host-runtime-artifacts` checks that notifier and host-connector artifacts match their source stamps and that tmux/terminfo payloads exist for every supported target. Published manifests also record notifier/connector source fingerprints, so an immutable semver runtime can be reused only by the exact locked source and pinned build-tool contract that produced it; changed helper source requires a new patch version.

## Connector Liveness

The backend owns the persistent control-channel liveness contract. It sends a WebSocket Ping every 30 seconds, logs connector registration duration and disconnect reason, and warns when an SSH relay request is rejected as `connector_offline`. The host connector still sends its own 30-second Ping; new builds also reset reconnect backoff to one second after any control connection that remained established for at least 60 seconds. Together these rules prevent a healthy long-lived session from accumulating the 30-second retry cap and keep older deployed connectors alive across proxy idle limits.

## API Surface

Public app/helper endpoints include:
- `POST /v1/devices/register`
- `POST /v1/relay-sessions`
- `POST /v1/connectors/register`
- `POST /v1/connectors/session-token`
- `GET /v1/connectors/ws`
- `GET /v1/connectors/sessions/{relay_session_id}/ws`
- `POST /v1/ssh-relay-sessions`
- `GET /v1/ssh-relay-sessions/{relay_session_id}/ws`
- `POST /v1/notify`
- `POST /v1/analytics/events`
- `GET /healthz`

Internal companion-client endpoints require env-configured bearer tokens.
They include:

- `POST /v1/internal/alert`
- `POST /v1/internal/live-activity`
- `POST /v1/internal/location`
- `POST /v1/internal/voip`

The location endpoint derives the APNs topic as `<bundle-id>.location-query`,
sets push type `location`, requires an explicit expiration, and reserves `aps`
for the broker-generated empty dictionary. Callers provide only their typed
location-command fields in `custom_data`.

The VoIP endpoint permits only the RemoteCoder companion caller and its allowed
bundle ID. Its strict request is `{device_token, bundle_id, push_environment,
call_id, host_id, expires_at}`; IDs are UUIDs and expiry is Unix seconds.
It derives `<bundle-id>.voip`, uses APNs push type `voip`, priority `10` and
expiration `0` (never store a missed ring), and sends only an empty `aps` plus
`agentCall: {callId, hostId, expiresAt}`. Call briefs, thread content, and caller
names never enter this push payload. APNs acceptance is delivery acceptance,
not evidence of a ring, answer, or connected audio.

## Storage

SQLite stores devices, relay sessions, relay hosts, connector credentials, SSH relay sessions, analytics users/events, and validation-failure diagnostics. Analytics validation diagnostics intentionally avoid raw hostnames, usernames, candidate addresses, and raw error text.

## Surface Live Activity Transport

Set `AGENTTY_BACKEND_SURFACE_TOKEN` in the operator-owned deployment and give the
same secret only to the Surface publisher. This caller can send only Live
Activities for `emileberhard.Surface` and copies whose bundle ID appends one or
more ASCII digits, such as `emileberhard.Surface2`; it cannot send alerts,
location or VoIP pushes. Other suffixes are rejected. Signing credentials stay
in this backend. The APNs key must authorize each bundle ID. Broadcast capability
is a separate prerequisite for channels.

The existing `/v1/internal/live-activity` endpoint retains its update/end request
and response. New typed lifecycle operations use:

- `POST /v1/internal/live-activity/dispatch`
- `POST /v1/internal/live-activity/channels`

All request types reject unknown fields. Dispatch bodies are bounded at 16 KiB;
channel management bodies at 4 KiB. These are broker admission policies.
Invalid JSON, invalid lifecycle fields or failed admission return HTTP 400;
missing authentication returns 401 and unauthorized bundle/push type returns
403. No APNs request occurs in these cases.

A start uses this shape:

```json
{
  "bundle_id": "emileberhard.Surface",
  "push_environment": "development",
  "priority": 10,
  "expiration": 0,
  "message": {
    "event": "start",
    "device_token": "<hex push-to-start token>",
    "timestamp": 1791979000,
    "content_state": {"<full Surface state>": "..."},
    "attributes_type": "SurfaceAttributes",
    "attributes": {"activityID": "<exact logical identity>"},
    "alert": {"title": "Work session", "body": "Started"},
    "update_route": {"kind": "token"}
  }
}
```

A channel start replaces `update_route` with
`{"kind":"channel","channel_id":"<APNs channel ID>"}`. The channel must already
exist in that environment. The broker emits `input-push-token: 1` or
`input-push-channel`, never both. Start requires attributes and an alert;
dismissal is permitted only on end.

Update and end messages contain `event`, `timestamp`, `content_state` and
`target`, where target is `{"kind":"device","device_token":"<hex activity
update token>"}` or `{"kind":"channel","channel_id":"<APNs channel ID>"}`.
Both accept optional positive `stale_date` and optional `alert` with title/body
and optional subtitle. End also accepts optional positive `dismissal_date`.
Every push carries the full content state. `priority` is required and must be
5 or 10; `expiration` is required and must be zero or positive Unix seconds.

The broker measures the encoded state plus start attributes against its 4,096
byte admission policy, and the complete uncompressed APNs body against 4,096
bytes for device-token delivery or 5,120 bytes for broadcast. Apple’s actual
ActivityKit combined-data measurement still requires device validation.
Device tokens must contain hexadecimal byte pairs, at most 2,048 bytes. Channel IDs must be
standard base64, nonempty and at most 1,024 bytes; the broker does not assume a
particular APNs-generated identifier length.

Channel requests contain `bundle_id`, `push_environment` and `operation`:

```json
{"kind":"create","message_storage_policy":1}
```

or `{"kind":"delete","channel_id":"<APNs channel ID>"}`. Storage policy 0
means No Message Storage and requires expiration 0 when publishing. Policy 1
means Most Recent Message Stored, with lower publishing budget and retention
of up to eight hours. A successful creation returns the new channel ID. The
broker does not persist it, attach devices or choose when to delete it.
Deletion does not prove that stored messages stopped delivering.

Once an authenticated request is admitted, HTTP 200 carries a transport outcome:

- `{"outcome":"accepted","apns_id":"...","channel_id":"..."}`;
  `channel_id` appears only after channel creation, and IDs may otherwise be absent.
- `{"outcome":"rejected","apns_status":400,"apns_reason":"...","failure_class":"..."}`;
  the APNs ID and reason are optional when absent from the response. A valid
  APNs `Retry-After` header adds `retry_after_seconds`, a nonnegative integer.
  Delta seconds and HTTP dates are supported; missing or malformed headers
  omit the field. APNs does not promise this header. The caller owns retry
  timing and may apply a longer delay.
- `{"outcome":"unknown","reason":"transport_failed_after_dispatch"}`.
- `{"outcome":"not_sent","reason":"provider_authentication_failed","failure_class":"authorization"}`.

Failures are classified by APNs reason as `content`, `authorization`, `route`,
`throttled`, `transient` or `unknown`. HTTP status alone never invalidates a token
or channel. Requests that may have reached APNs are unknown after a network
failure; only failures before request execution are not sent. Successful channel
creation without a valid returned ID is unknown and may have leaked a channel.
APNs acceptance is not evidence of device display.

The new transport disables HTTP-library retries and redirects, dispatches once,
and bounds APNs error bodies. It never automatically retries ambiguous starts or
channel creation. Surface owns bounded retries, current-revision ordering,
observation, leases, tombstones and channel cleanup. Existing companion sender
behavior stays unchanged.

These mechanics follow Apple’s current [ActivityKit push contract](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications),
[channel management contract](https://developer.apple.com/documentation/usernotifications/sending-channel-management-requests-to-apns),
[broadcast request contract](https://developer.apple.com/documentation/usernotifications/sending-broadcast-push-notification-requests-to-apns)
and [APNs error reasons](https://developer.apple.com/documentation/usernotifications/handling-error-responses-from-apns).

## Public Relay Admission and Resource Ownership

The relay owns admission, quotas, durable state and hosted bandwidth. SSH authentication and host-key verification remain end to end between the app and sshd. A relay grant never replaces an SSH key.

New apps send StoreKit's signed `AppTransaction` with device registration and use `POST /v1/dictation/sessions` with `{device_id, device_secret, signed_app_transaction}`. Verification requires ES256, a strict X.509 chain anchored only to Apple's bundled Root CA G3, Apple's leaf/intermediate signing extensions, the main bundle ID, and a matching App Store numeric ID. Production receipts require that ID; Sandbox receipts may omit it. Only Production and Sandbox are admitted. Certificate validity is evaluated at the signed receipt creation time, following Apple's offline-verification design; there is no online OCSP check. The relay stores an environment-fenced hash of the verified `appTransactionId`, never the JWS. This proves an App Store installation, not purchase of the lifetime unlock.

`AGENTTY_BACKEND_APP_APPLE_ID` configures the numeric App Store ID. `AGENTTY_BACKEND_TRUSTED_DEVICE_CREDENTIALS` is an ignored operator setting containing comma-separated `device_id:sha256(device_secret)` entries. Matching uses the registered credential hash and constant-time comparison. This supports the operator's Dev/Exp and locally installed main builds without trusting a client-claimed build flavor. Never publish these entries or print them in diagnostics.

Compatibility remains enabled by default: current App Store/TestFlight clients cannot send a JWS, so new registrations, pairing, notifications, dictation and relay access still work within shared legacy limits. `AGENTTY_BACKEND_REQUIRE_VERIFIED_DEVICES=true` closes this lane for registrations and hosted operations, while verified and explicitly trusted devices remain admitted. There is no calendar sunset. Enable enforcement only after a JWS-sending App Store release has been live long enough for existing users and new installations to upgrade; App Store submission remains an operator decision.

New notification requests use `scope: "notify"` at `/v1/relay-sessions`. These tokens cannot transcribe. Dictation tokens cannot notify and expire after one hour. Missing scope and existing tokens are explicitly legacy credentials, subject to the shared compatibility budget. A host may still hold a legacy token until a new app refreshes `notify.json`; the bounded legacy pool covers that rollout.

Dictation accepts complete PCM WAV files, with one format chunk followed by one data chunk. Encoding, sample rate, channel count, sample width, byte rate, frame alignment, RIFF size and chunk boundaries must agree. Unknown, duplicate and truncated chunks are rejected. Charging rounds validated sample-frame duration up to seconds. Audio is limited to 25,000,000 bytes; JSON transport adds base64 overhead without accepting an arbitrary 40 MiB body. Metadata and provider responses are bounded, and upstream requests have a 120-second timeout.

| Operator setting | Default |
| --- | --- |
| `AGENTTY_BACKEND_DICTATION_DAILY_SECONDS` | 3,600 seconds across all requests |
| `AGENTTY_BACKEND_DICTATION_WEEKLY_SECONDS` | 14,400 seconds across all requests |
| `AGENTTY_BACKEND_DICTATION_LEGACY_WEEKLY_SECONDS` | 3,600 seconds shared by all legacy clients |
| `AGENTTY_BACKEND_DICTATION_CONCURRENCY` | 2 requests, including upload parsing |
| `AGENTTY_BACKEND_RELAY_DAILY_BYTES` | 1 GiB across both traffic directions |
| `AGENTTY_BACKEND_RELAY_DEVICE_DAILY_BYTES` | 128 MiB per verified identity or unverified device |
| `AGENTTY_BACKEND_RELAY_LEGACY_DAILY_BYTES` | 128 MiB shared by unverified, untrusted devices |

Each dictation identity has a 1,800-second weekly allowance shared by its devices. Legacy devices retain that individual allowance in addition to their shared pool. SQLite immediate transactions reserve identity and operator allowances together. Operator reservations remain charged on provider failure, cancellation and ambiguous outcomes, so retries and restarts cannot reset spending ceilings; only the individual's allowance is refunded after an explicit provider failure. Existing weekly usage seeds the operator ledger during migration. Weeks reset Monday at 00:00 UTC; daily spend and bandwidth reset at 00:00 UTC. The ledgers persist across process restarts.

The HTTP owner caps public traffic at 600 requests/minute and provisioning at 60/minute, with 32 requests in flight and 120 authenticated requests/minute per device. Only requests bearing a valid companion credential bypass the public request pool. Most JSON bodies are limited to 256 KiB; the typed companion Live Activity endpoints keep their smaller limits. WebSockets are capped at 128, with 64 KiB SSH messages/frames; control sockets accept only heartbeat/close messages and cap frames at 125 bytes. Heartbeats are limited to 64 per socket per minute, probes to 15 seconds, and empty/unsupported data messages close the socket. Relay sessions are capped at 32 total and four per host, and each queued direction remains limited to 256 KiB. Bandwidth is reserved before forwarding each binary message, with a 256-byte minimum charge per message to bound tiny-frame processing as well as bulk transfer. A ceiling closes the affected tunnel with `relay_bandwidth_limit` and prevents new issuance until reset. New apps advertise `x-agentty-resource-errors: 1`, receive typed `429` errors and stop automatic reconnect on resource-limit failures. Older clients receive an authentication rejection for an exhausted relay pool; their existing single identity-repair attempt then stops reconnect, instead of polling a permanent limit every eight seconds. Direct SSH remains available.

Anonymous QR creation is necessary before an app claims the code. It cannot authorize hosted traffic by itself. Pairing rows expire after ten minutes, remain inspectable for 24 hours and are capped at 4,096. Hosts are capped at 4,096 and grants at 32 per device. Devices are capped at 10,000 and relay credentials at 512 per device. With `AGENTTY_BACKEND_REQUIRE_HOST_ADOPTION_PROOF=true`, existing-host adoption requires either the device's existing grant or proof of the connector ID and secret already installed on that host; guessing `machine_id` and username cannot replace credentials. This switch defaults off during the backend-first cutover because installed pairing helpers cannot send proof. Turn it on immediately after the 2.12.0 tag has published the matching helper. The interim compatibility policy still relies on the random, private machine ID. The pairing helper reads proof only from its local connector config and sends it only to that config's relay origin.

Analytics authenticates before validating or writing durable diagnostics. Failure records retain at most 10,000 rows for 14 days, with bounded diagnostic fields. Normal analytics and existing device/grant data are preserved. The SQLite owner enforces a 512 MiB file cap and reports capacity failures for operator action; a database already exceeding that cap fails startup rather than silently growing. There were no historical traffic-byte counters to size bandwidth from. The initial dictation ceilings were checked against production aggregate weekly usage; no credentials or audio were exported.

The internal RemoteCoder/Surface APNs contracts, topics and payloads are unchanged. Their configured tokens must be at least 32 characters, are compared in constant time, and remain in the operator credential store. Public requests cannot select provider upstream URLs. Internal failures return generic errors without stack traces or credentials.

### Deployment and Remaining Acceptance

Build/test on an isolated checkout, hydrate the App Store ID and trusted-device hashes in ignored operator configuration, and deploy through `just backend-deploy-local`. The backend exposes `GET /status`, `POST /fence` and `POST /resume` only on a mode-0600 Unix socket under a mode-0700 directory; `AGENTTY_BACKEND_CONTROL_SOCKET_PATH` defaults to `~/.agentty/backend-control/socket`. Status includes the owning PID and live SSH-session count. Fencing and relay attachment share the broker lock, so pending connections cannot turn an idle fenced broker active. Existing sessions continue forwarding and pair creation/claims pause. The operator updater fences, waits up to 120 seconds for zero live sessions and reopens admission on an abort. It then backs up SQLite, swaps the executable, verifies health and restores the prior binary automatically if health fails; accepted database writes are never rolled back. SIGTERM has a separate ten-second SSH grace followed by at most forty seconds of HTTP drain. The fifty-second maximum leaves cleanup headroom within macOS GUI launchd's observed sixty-second exit limit; a larger plist value is clamped by launchd.

For the first deployment only, the running binary lacks this control. The updater reconstructs connector control sockets from the current process startup onward and compares them with its established backend TCP sockets. Any unclassified connection prevents deployment. Two idle observations are required, then the exact old PID is suspended to fence admission and the evidence is checked again before replacement. If the current process log is incomplete, counts disagree or idle cannot be established within 120 seconds, the updater aborts. Database rows alone are never accepted as proof of idleness. The old PID is resumed on an aborted cutover. The added tables/columns preserve compatibility for binary rollback.

After lead approval, deploy the backend first with host-adoption proof enforcement off. The 2.12.0 tag publishes the matching `@agentty-app/pair` helper; do not publish it independently. Then enable `AGENTTY_BACKEND_REQUIRE_HOST_ADOPTION_PROOF=true` through the guarded operator deploy path and verify health and rejected forged requests read-only. The next app release carries JWS admission, notification scoping and typed limit recovery; the rebuilt Rust helpers ship with the next host-runtime release. Production Apple JWS acceptance, the combined iOS build/install and the guarded live deployment still require their respective acceptance checks. Linear rejected issue creation at the workspace's free issue cap, so this section records the decision and removal condition until tracking capacity is restored.

Verification references: [Apple's signed-data verifier](https://github.com/apple/app-store-server-library-python/blob/main/appstoreserverlibrary/signed_data_verifier.py), [AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction), [Apple Root CA G3](https://www.apple.com/certificateauthority/AppleRootCA-G3.cer).
