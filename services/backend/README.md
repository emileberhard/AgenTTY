# AgenTTY Backend

Minimal self-hosted Rust backend for AgenTTY notifications, pairing control, relay-backed SSH fallback, App Store dictation proxying, analytics, and trusted companion-client APNs brokering, including alert, Live Activity, location, and VoIP pushes.

See `../../docs/backend.md` for deployment contracts and host-runtime publishing notes.

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
