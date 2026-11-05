import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  completePairingSession,
  createPairingSession,
  fetchHostPairingSessionStatus,
} from "./pairing-api.js";
import { registerConnector } from "./relay-connector.js";
import type { FetchLike } from "./types.js";

interface RecordedRequest {
  readonly body: unknown;
  readonly method: string;
  readonly url: string;
}

const baseUrl = new URL("https://relay.example.test");

function fixture(path: string): unknown {
  return JSON.parse(
    readFileSync(new URL(`../../../../contract-fixtures/${path}`, import.meta.url), "utf8")
  );
}

function recordingFetch(
  requests: RecordedRequest[],
  status: number,
  body: unknown
): FetchLike {
  return async (url, options = {}) => {
    requests.push({
      url: url.toString(),
      method: options.method ?? "GET",
      body: typeof options.body === "string" ? JSON.parse(options.body) : null,
    });
    return {
      ok: status >= 200 && status < 300,
      status,
      async json() {
        return body;
      },
    };
  };
}

test("createPairingSession parses the backend session", async () => {
  const requests: RecordedRequest[] = [];

  const session = await createPairingSession(
    { baseUrl },
    { fetchImpl: recordingFetch(requests, 200, fixture("pairing-sessions/response/session.json")) }
  );

  assert.deepEqual(session, {
    sessionId: "session-1",
    pairingCode: "ABCD-EFGH",
    qrPayload: "agentty://pair?code=ABCD-EFGH",
    hostToken: "host-token",
    expiresAtEpochSeconds: 1_800_000_000,
  });
  assert.deepEqual(requests, [
    { url: "https://relay.example.test/v1/pairing-sessions", method: "POST", body: null },
  ]);
});

test("fetchHostPairingSessionStatus sends the host token and parses the claimed session", async () => {
  const requests: RecordedRequest[] = [];

  const status = await fetchHostPairingSessionStatus(
    { baseUrl, hostToken: "host-token", sessionId: "session-1" },
    { fetchImpl: recordingFetch(requests, 200, fixture("pairing-host-status/response/claimed.json")) }
  );

  assert.deepEqual(status, {
    completion: null,
    connectorBootstrap: { token: "bootstrap-token", expiresAtEpochSeconds: 1_800_000_000 },
    expiresAtEpochSeconds: 1_800_000_000,
    publicKey: "ssh-ed25519 AAAATEST agentty@fixture",
    sessionId: "session-1",
    status: "claimed",
  });
  assert.deepEqual(requests, [
    {
      url: "https://relay.example.test/v1/pairing-sessions/session-1/host-status",
      method: "POST",
      body: fixture("pairing-host-status/request/host-status.json"),
    },
  ]);
});

test("fetchHostPairingSessionStatus reports the backend detail", async () => {
  await assert.rejects(
    fetchHostPairingSessionStatus(
      { baseUrl, hostToken: "stale-token", sessionId: "session-1" },
      {
        fetchImpl: recordingFetch(
          [],
          401,
          fixture("pairing-host-status/response/invalid-host-token-error.json")
        ),
      }
    ),
    { message: "Invalid host token." }
  );
});

test("registerConnector sends the bootstrap registration", async () => {
  const requests: RecordedRequest[] = [];

  const registration = await registerConnector(
    {
      baseUrl,
      bootstrapToken: "bootstrap-token",
      existingConnector: undefined,
      machineID: "machine-1",
      metadata: {
        detectedUsername: "developer",
        detectedUsernameSource: "account_lookup",
        detectedUsernameSuspicious: false,
        hostCandidates: [],
        hostEnvironmentFlags: [],
        hostnameCandidates: [],
        platform: "linux",
        port: 22,
        sshHostPublicKeys: [],
        usesTailscale: false,
      },
    },
    { fetchImpl: recordingFetch(requests, 200, fixture("connectors-register/response/registered.json")) }
  );

  assert.deepEqual(registration, fixture("connectors-register/response/registered.json"));
  assert.deepEqual(requests, [
    {
      url: "https://relay.example.test/v1/connectors/register",
      method: "POST",
      body: fixture("connectors-register/request/register.json"),
    },
  ]);
});

test("completePairingSession sends the hardened completion payload", async () => {
  const requests: RecordedRequest[] = [];

  await completePairingSession(
    {
      baseUrl,
      hostToken: "host-token",
      metadata: {
        detectedUsername: "developer",
        detectedUsernameSource: "account_lookup",
        detectedUsernameSuspicious: true,
        hostCandidates: [
          {
            value: "agentty.local",
            kind: "local_domain",
            source: "hostname_fqdn",
            rank: 1,
          },
        ],
        hostEnvironmentFlags: ["wsl"],
        hostnameCandidates: ["agentty.local"],
        usesTailscale: false,
        sshHostPublicKeys: ["ssh-ed25519 AAAAHOSTKEY"],
        relayCapable: true,
        relayHostId: "relay-host-1",
        port: 22,
        platform: "linux",
      },
      sessionId: "session-1",
    },
    { fetchImpl: recordingFetch(requests, 200, fixture("pairing-status/response/completed.json")) }
  );

  assert.deepEqual(requests, [
    {
      url: "https://relay.example.test/v1/pairing-sessions/session-1/complete",
      method: "POST",
      body: fixture("pairing-complete/request/complete.json"),
    },
  ]);
});
