# backend

Small Rust backend service for AgenTTY notifications, main-flavor dictation proxying, pairing control, relay-backed SSH fallback, and the production-only AgenTTY user database. It keeps AgenTTY's public device registration + relay-session flow, acts as the APNs broker for trusted companion clients (alert, Live Activity, and location push types), sends App Store dictation to llm-router with its own router key, enforces weekly quotas for App Store dictation, and ingests production analytics batches keyed by hashed `AppTransaction.appTransactionID`. Keep it intentionally small and avoid introducing extra infrastructure or abstractions unless the existing shape becomes a real constraint.

Device IDs are canonicalized to lowercase at the relay boundary and in storage. `Database::open` enables SQLite foreign-key enforcement, normalizes legacy mixed-case device IDs across `devices`, `relay_sessions`, `pairing_sessions`, `dictation_usage_weekly`, `analytics_device_user_links`, and `analytics_events`, and fails fast if legacy rows would collapse onto the same canonical device ID or if any orphaned device references remain.

## Run

```bash
./scripts/run-backend
```

## Test

```bash
cargo test
```

## Build

```bash
cargo build --release --locked
```

## Deploy

Deployment is operator-owned and configured outside git. Build the binary with
`cargo build --release --locked`, provide the environment below through a private
env file or service manager, then health-check the service before routing
traffic to it.

## Environment

- `AGENTTY_BACKEND_DATABASE_PATH`
- `AGENTTY_BACKEND_APNS_KEY_PATH`
- `AGENTTY_BACKEND_APNS_KEY_ID`
- `AGENTTY_BACKEND_APNS_TEAM_ID`
- `AGENTTY_BACKEND_OPENAI_BASE_URL` (llm-router origin + `/v1`)
- `AGENTTY_BACKEND_OPENAI_API_KEY` (llm-router key, principal `agentty`)
- `AGENTTY_BACKEND_REMOTECODER_TOKEN`
- `AGENTTY_BACKEND_PINGBOOKS_TOKEN`
- `AGENTTY_BACKEND_ESMALIB_TOKEN`
- `AGENTTY_BACKEND_SURFACE_TOKEN`
