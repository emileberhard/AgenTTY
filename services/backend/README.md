# AgenTTY Backend

Minimal self-hosted Rust backend for AgenTTY notifications, pairing control, relay-backed SSH fallback, App Store dictation proxying, analytics, and trusted companion-client APNs brokering, including alert, Live Activity, location, and VoIP pushes.

See `../../docs/backend.md` for deployment contracts and host-runtime publishing notes.

Surface uses the scoped `AGENTTY_BACKEND_SURFACE_TOKEN` caller for typed Live
Activity lifecycle dispatch and APNs channel management. The broker owns only
APNs transport; Surface owns activity state, action policy and channel cleanup.

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
