# `@agentty-app/pair`

Small bootstrap CLI for pairing a host with AgenTTY.

## Usage

```bash
npx -y @agentty-app/pair
npx -y @agentty-app/pair --recommended
npx -y @agentty-app/pair --direct-only
```

Current commands:

- `pair` - create a pairing session, render a QR + short code, optionally offer the host's Tailscale MagicDNS hostname when Tailscale is installed, wait for AgenTTY to claim it, choose Full AgenTTY Setup or Direct Connection Only before changing the host, authorize the claimed SSH public key for the current user, collect the host SSH public keys from local `sshd`, provision the persistent AgenTTY relay connector only for Full AgenTTY Setup, then finalize the session with host metadata
- `doctor` - placeholder diagnostics entrypoint
- `repair` - placeholder repair entrypoint
- `unpair` - placeholder unpair entrypoint

Pairing options:

- `--recommended` - explicitly use Full AgenTTY Setup with fallback relay access
- `--direct-only` - skip the persistent relay connector and use direct SSH only

## Local development

```bash
bun test
bun run build
bun ./bin/agentty-host.js
```

Release packages download the matching tag's checksum-verified connector from
the AgenTTY GitHub release. Untagged development builds use the mutable runtime
host. `AGENTTY_BACKEND_URL` selects your relay;
`AGENTTY_HOST_RUNTIME_ASSET_BASE_URL` selects an operator's `latest.json` base.
A tagged package requires that manifest's runtime_version to equal its tag.
