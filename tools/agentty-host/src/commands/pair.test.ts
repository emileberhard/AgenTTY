import assert from "node:assert/strict";
import { Readable, Writable } from "node:stream";
import test from "node:test";
import { runPairCommand } from "./pair.js";

interface RecordedRequest {
  readonly body: unknown;
  readonly method: string;
  readonly url: string;
}

test("runPairCommand creates, renders, installs, and completes a pairing session", async () => {
  const requests: RecordedRequest[] = [];
  const renderedPayloads: string[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  let hostStatusStep = 0;

  const exitCode = await runPairCommand(
    [],
    { stdout, stderr },
    {
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      qrRenderer: async (payload) => {
        renderedPayloads.push(payload);
      },
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          hostStatusStep += 1;
          if (hostStatusStep === 1) {
            return okJson({
              session_id: "session-1",
              status: "pending",
              expires_at_epoch_seconds: 123,
            });
          }
          if (hostStatusStep === 2) {
            return okJson({
              session_id: "session-1",
              status: "claimed",
              public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
              expires_at_epoch_seconds: 123,
            });
          }
          throw new Error("unexpected extra host-status poll");
        }

        return okJson({ status: "completed" });
      },
      fsImpl: {
        async mkdir() {},
        async chmod() {},
        async readFile() {
          throw errorWithCode("missing", "ENOENT");
        },
        async writeFile() {},
        async appendFile() {},
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(renderedPayloads, ["agentty://pair?code=ABCD-EFGH"]);
  assert.equal(requests.length, 4);
  assert.deepEqual(requests[0], {
    url: "https://agentty.esmadil.se/v1/pairing-sessions",
    method: "POST",
    body: null,
  });
  assert.deepEqual(requests[3]?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "env_user",
    detected_username_suspicious: true,
    host_candidates: [
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 1,
      },
      {
        value: "agentty",
        kind: "single_label",
        source: "hostname",
        rank: 2,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: ["agentty.local", "agentty"],
    uses_tailscale: false,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    relay_capable: false,
    port: 22,
    platform: "linux",
  });
  assert.match(stdout.toString(), /Scan this QR code with AgenTTY:/u);
  assert.match(stdout.toString(), /Manual code: ABCD-EFGH/u);
  assert.match(stdout.toString(), /Pairing complete\./u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand records relay metadata when connector provisioning succeeds", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();

  const exitCode = await runPairCommand(
    ["--recommended"],
    { stdout, stderr },
    {
      connectorProvisioner: async () => ({
        relayHostId: "relay-host-123",
      }),
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          return okJson({
            session_id: "session-1",
            status: "claimed",
            public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
            connector_bootstrap: {
              token: "bootstrap-token",
              expires_at_epoch_seconds: 321,
            },
            expires_at_epoch_seconds: 123,
          });
        }

        return okJson({ status: "completed" });
      },
      fsImpl: {
        async mkdir() {},
        async chmod() {},
        async readFile() {
          throw errorWithCode("missing", "ENOENT");
        },
        async writeFile() {},
        async appendFile() {},
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(requests.at(-1)?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "env_user",
    detected_username_suspicious: true,
    host_candidates: [
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 1,
      },
      {
        value: "agentty",
        kind: "single_label",
        source: "hostname",
        rank: 2,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: ["agentty.local", "agentty"],
    uses_tailscale: false,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    relay_capable: true,
    relay_host_id: "relay-host-123",
    port: 22,
    platform: "linux",
  });
  assert.match(stdout.toString(), /Relay host ID: relay-host-123/u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand defaults interactive setup consent to recommended mode", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  const stdin = createTTYInput();
  let connectorCalls = 0;

  const exitCode = await runPairCommand(
    [],
    { stdin, stdout, stderr },
    {
      connectorProvisioner: async () => {
        connectorCalls += 1;
        return { relayHostId: "relay-host-123" };
      },
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      setupModePromptImpl: async () => "recommended",
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: basicExecFile,
      fetchImpl: basicPairingFetch(requests, {
        connector_bootstrap: {
          token: "bootstrap-token",
          expires_at_epoch_seconds: 321,
        },
      }),
      fsImpl: successfulFs(),
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.equal(connectorCalls, 1);
  assert.equal(requests.at(-1)?.body && typeof requests.at(-1)?.body, "object");
  assert.equal((requests.at(-1)?.body as Record<string, unknown>).relay_capable, true);
  assert.equal((requests.at(-1)?.body as Record<string, unknown>).relay_host_id, "relay-host-123");
  assert.equal(stderr.toString(), "");
});

test("runPairCommand can choose Direct Connection Only from interactive consent", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  const stdin = createTTYInput();
  let connectorCalls = 0;

  const exitCode = await runPairCommand(
    [],
    { stdin, stdout, stderr },
    {
      connectorProvisioner: async () => {
        connectorCalls += 1;
        return { relayHostId: "relay-host-123" };
      },
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      setupModePromptImpl: async () => "directOnly",
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: basicExecFile,
      fetchImpl: basicPairingFetch(requests, {
        connector_bootstrap: {
          token: "bootstrap-token",
          expires_at_epoch_seconds: 321,
        },
      }),
      fsImpl: successfulFs(),
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.equal(connectorCalls, 0);
  assert.equal((requests.at(-1)?.body as Record<string, unknown>).relay_capable, false);
  assert.doesNotMatch(stdout.toString(), /Relay host ID/u);
  assert.match(stdout.toString(), /Direct Connection Only selected/u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand cancels before key installation when both setup modes are declined", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  const stdin = createTTYInput();
  let writes = 0;

  const exitCode = await runPairCommand(
    [],
    { stdin, stdout, stderr },
    {
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      setupModePromptImpl: async () => null,
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: basicExecFile,
      fetchImpl: basicPairingFetch(requests),
      fsImpl: {
        async mkdir() {
          writes += 1;
        },
        async chmod() {
          writes += 1;
        },
        async readFile() {
          writes += 1;
          return "";
        },
        async writeFile() {
          writes += 1;
        },
        async appendFile() {
          writes += 1;
        },
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 1);
  assert.equal(writes, 0);
  assert.deepEqual(requests.at(-1)?.body, {
    host_token: "host-token",
    error_message: "Pairing cancelled before changing this host.",
  });
  assert.match(stderr.toString(), /Pairing cancelled before changing this host/u);
});

test("runPairCommand --direct-only skips connector provisioning without prompting", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  let connectorCalls = 0;
  let promptCalls = 0;

  const exitCode = await runPairCommand(
    ["--direct-only"],
    { stdout, stderr },
    {
      connectorProvisioner: async () => {
        connectorCalls += 1;
        return { relayHostId: "relay-host-123" };
      },
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      setupModePromptImpl: async () => {
        promptCalls += 1;
        return "recommended";
      },
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: basicExecFile,
      fetchImpl: basicPairingFetch(requests, {
        connector_bootstrap: {
          token: "bootstrap-token",
          expires_at_epoch_seconds: 321,
        },
      }),
      fsImpl: successfulFs(),
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.equal(promptCalls, 0);
  assert.equal(connectorCalls, 0);
  assert.equal((requests.at(-1)?.body as Record<string, unknown>).relay_capable, false);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand defaults non-interactive no-flag setup to direct only", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  let connectorCalls = 0;
  let promptCalls = 0;

  const exitCode = await runPairCommand(
    [],
    { stdout, stderr },
    {
      connectorProvisioner: async () => {
        connectorCalls += 1;
        return { relayHostId: "relay-host-123" };
      },
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      setupModePromptImpl: async () => {
        promptCalls += 1;
        return "recommended";
      },
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: basicExecFile,
      fetchImpl: basicPairingFetch(requests, {
        connector_bootstrap: {
          token: "bootstrap-token",
          expires_at_epoch_seconds: 321,
        },
      }),
      fsImpl: successfulFs(),
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.equal(promptCalls, 0);
  assert.equal(connectorCalls, 0);
  assert.equal((requests.at(-1)?.body as Record<string, unknown>).relay_capable, false);
  assert.match(stdout.toString(), /No interactive TTY is available/u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand falls back to direct SSH when connector provisioning fails", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();

  const exitCode = await runPairCommand(
    ["--recommended"],
    { stdout, stderr },
    {
      connectorProvisioner: async () => {
        throw new Error("probe failed");
      },
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          return okJson({
            session_id: "session-1",
            status: "claimed",
            public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
            connector_bootstrap: {
              token: "bootstrap-token",
              expires_at_epoch_seconds: 321,
            },
            expires_at_epoch_seconds: 123,
          });
        }

        return okJson({ status: "completed" });
      },
      fsImpl: {
        async mkdir() {},
        async chmod() {},
        async readFile() {
          throw errorWithCode("missing", "ENOENT");
        },
        async writeFile() {},
        async appendFile() {},
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(requests.at(-1)?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "env_user",
    detected_username_suspicious: true,
    host_candidates: [
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 1,
      },
      {
        value: "agentty",
        kind: "single_label",
        source: "hostname",
        rank: 2,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: ["agentty.local", "agentty"],
    uses_tailscale: false,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    relay_capable: false,
    port: 22,
    platform: "linux",
  });
  assert.match(
    stdout.toString(),
    /Remote relay access is unavailable for now\. Direct SSH pairing still succeeded\./u
  );
  assert.match(stdout.toString(), /probe failed/u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand reports install failures upstream", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();

  const exitCode = await runPairCommand(
    [],
    { stdout, stderr },
    {
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => false,
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "id" && args[0] === "-u") {
          throw new Error("missing uid");
        }
        if (command === "id" && args[0] === "-un") {
          return { stdout: "developer\n" };
        }
        if (command === "whoami") {
          throw new Error("missing whoami");
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        return { stdout: "agentty.local\n" };
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          return okJson({
            session_id: "session-1",
            status: "claimed",
            public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
            expires_at_epoch_seconds: 123,
          });
        }

        return okJson({ status: "failed" });
      },
      fsImpl: {
        async mkdir() {
          throw new Error("disk full");
        },
        async chmod() {
          return;
        },
        async readFile() {
          return "";
        },
        async writeFile() {
          return;
        },
        async appendFile() {
          return;
        },
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 1);
  assert.equal(requests.length, 3);
  assert.deepEqual(requests[2]?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "id_command",
    detected_username_suspicious: false,
    host_candidates: [
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 1,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: ["agentty.local"],
    uses_tailscale: false,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    port: 22,
    platform: "linux",
    error_message: "disk full",
  });
  assert.match(stderr.toString(), /disk full/u);
});

test("runPairCommand rejects positional pairing codes", async () => {
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();

  const exitCode = await runPairCommand(["ABCD-EFGH"], { stdout, stderr });

  assert.equal(exitCode, 1);
  assert.match(stderr.toString(), /does not accept argument: ABCD-EFGH/u);
});

test("runPairCommand prefers the short Tailscale hostname when the user opts in", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();

  const exitCode = await runPairCommand(
    [],
    { stdout, stderr },
    {
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => true,
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "tailscale" && args[0] === "status") {
          return {
            stdout: JSON.stringify({
              Self: {
                DNSName: "agentty-host.tail123.ts.net.",
              },
            }),
          };
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          return okJson({
            session_id: "session-1",
            status: "claimed",
            public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
            expires_at_epoch_seconds: 123,
          });
        }

        return okJson({ status: "completed" });
      },
      fsImpl: {
        async mkdir() {},
        async chmod() {},
        async readFile() {
          throw errorWithCode("missing", "ENOENT");
        },
        async writeFile() {},
        async appendFile() {},
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(requests[2]?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "env_user",
    detected_username_suspicious: true,
    host_candidates: [
      {
        value: "agentty-host",
        kind: "tailscale_short",
        source: "tailscale_short",
        rank: 1,
      },
      {
        value: "agentty-host.tail123.ts.net",
        kind: "tailscale_fqdn",
        source: "tailscale_magicdns",
        rank: 2,
      },
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 3,
      },
      {
        value: "agentty",
        kind: "single_label",
        source: "hostname",
        rank: 4,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: [
      "agentty-host",
      "agentty-host.tail123.ts.net",
      "agentty.local",
      "agentty",
    ],
    uses_tailscale: true,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    relay_capable: false,
    port: 22,
    platform: "linux",
  });
  assert.match(stdout.toString(), /Using Tailscale hostname: agentty-host/u);
  assert.equal(stderr.toString(), "");
});

test("runPairCommand falls back when Tailscale is installed but no MagicDNS hostname is available", async () => {
  const requests: RecordedRequest[] = [];
  const stdout = createWritableCapture();
  const stderr = createWritableCapture();
  let promptCalls = 0;

  const exitCode = await runPairCommand(
    [],
    { stdout, stderr },
    {
      env: { USER: "developer" },
      hostname: "agentty.local",
      platform: "linux",
      promptImpl: async () => {
        promptCalls += 1;
        return true;
      },
      qrRenderer: async () => {},
      sleepImpl: async () => {},
      execFileImpl: async (command, args) => {
        if (command === "ssh-keyscan") {
          return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
        }
        if (command === "tailscale" && args[0] === "status") {
          throw errorWithStdout("daemon unavailable", "");
        }
        if (command === "hostname" && args[0] === "-f") {
          return { stdout: "agentty.local\n" };
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });

        if (url.toString().endsWith("/v1/pairing-sessions")) {
          return okJson({
            session_id: "session-1",
            pairing_code: "ABCD-EFGH",
            qr_payload: "agentty://pair?code=ABCD-EFGH",
            host_token: "host-token",
            expires_at_epoch_seconds: 123,
          });
        }

        if (url.toString().includes("/host-status")) {
          return okJson({
            session_id: "session-1",
            status: "claimed",
            public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
            expires_at_epoch_seconds: 123,
          });
        }

        return okJson({ status: "completed" });
      },
      fsImpl: {
        async mkdir() {},
        async chmod() {},
        async readFile() {
          throw errorWithCode("missing", "ENOENT");
        },
        async writeFile() {},
        async appendFile() {},
      },
      homeDirectory: "/tmp/agentty-test-home",
    }
  );

  assert.equal(exitCode, 0);
  assert.equal(promptCalls, 0);
  assert.deepEqual(requests[2]?.body, {
    host_token: "host-token",
    detected_username: "developer",
    detected_username_source: "env_user",
    detected_username_suspicious: true,
    host_candidates: [
      {
        value: "agentty.local",
        kind: "local_domain",
        source: "os_hostname",
        rank: 1,
      },
      {
        value: "agentty",
        kind: "single_label",
        source: "hostname",
        rank: 2,
      },
    ],
    host_environment_flags: [],
    hostname_candidates: ["agentty.local", "agentty"],
    uses_tailscale: false,
    ssh_host_public_keys: ["ssh-ed25519 AAAAHOSTKEY"],
    relay_capable: false,
    port: 22,
    platform: "linux",
  });
  assert.match(
    stdout.toString(),
    /could not determine a usable MagicDNS hostname/i
  );
  assert.equal(stderr.toString(), "");
});

function okJson(body: unknown) {
  return {
    ok: true,
    status: 200,
    async json() {
      return body;
    },
  };
}

function createWritableCapture(): Writable & { toString(): string } {
  let buffer = "";

  return Object.assign(
    new Writable({
      write(chunk, _encoding, callback) {
        buffer += chunk.toString();
        callback();
      },
    }),
    {
      toString() {
        return buffer;
      },
    }
  );
}

function createTTYInput(): Readable & { isTTY: true } {
  const input = new Readable({
    read() {},
  }) as Readable & { isTTY: true };
  input.isTTY = true;
  return input;
}

async function basicExecFile(command: string, args: readonly string[]) {
  if (command === "ssh-keyscan") {
    return { stdout: "[127.0.0.1]:22 ssh-ed25519 AAAAHOSTKEY\n" };
  }
  if (command === "hostname" && args[0] === "-f") {
    return { stdout: "agentty.local\n" };
  }
  if (command === "hostname") {
    return { stdout: "agentty\n" };
  }
  throw new Error("unexpected command");
}

function basicPairingFetch(
  requests: RecordedRequest[],
  claimedOverrides: Record<string, unknown> = {}
) {
  return async (url: URL, options: RequestInit = {}) => {
    requests.push({
      url: url.toString(),
      method: options.method ?? "GET",
      body: parseRequestBody(options.body),
    });

    if (url.toString().endsWith("/v1/pairing-sessions")) {
      return okJson({
        session_id: "session-1",
        pairing_code: "ABCD-EFGH",
        qr_payload: "agentty://pair?code=ABCD-EFGH",
        host_token: "host-token",
        expires_at_epoch_seconds: 123,
      });
    }

    if (url.toString().includes("/host-status")) {
      return okJson({
        session_id: "session-1",
        status: "claimed",
        public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test",
        expires_at_epoch_seconds: 123,
        ...claimedOverrides,
      });
    }

    return okJson({ status: "completed" });
  };
}

function successfulFs() {
  return {
    async mkdir() {},
    async chmod() {},
    async readFile() {
      throw errorWithCode("missing", "ENOENT");
    },
    async writeFile() {},
    async appendFile() {},
  };
}

function parseRequestBody(body: unknown): unknown {
  if (typeof body !== "string") {
    return null;
  }
  return JSON.parse(body);
}

function errorWithCode(message: string, code: string): Error & { readonly code: string } {
  return Object.assign(new Error(message), { code });
}

function errorWithStdout(
  message: string,
  stdout: string
): Error & { readonly stdout: string } {
  return Object.assign(new Error(message), { stdout });
}
