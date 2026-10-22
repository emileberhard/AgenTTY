import assert from "node:assert/strict";
import test from "node:test";
import {
  completePairingSession,
  fetchHostPairingSessionStatus,
} from "./pairing-api.js";

interface RecordedRequest {
  readonly body: unknown;
  readonly method: string;
  readonly url: string;
}

test("completePairingSession sends the hardened completion payload", async () => {
  const requests: RecordedRequest[] = [];

  await completePairingSession(
    {
      baseUrl: new URL("https://agentty.esmadil.se"),
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
        sshHostPublicKeys: ["ssh-ed25519 AAAATEST"],
        relayCapable: true,
        relayHostId: "relay-host-1",
        port: 22,
        platform: "linux",
      },
      sessionId: "session-1",
    },
    {
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });
        return jsonResponse(200, { status: "completed" });
      },
    }
  );

  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0], {
    url: "https://agentty.esmadil.se/v1/pairing-sessions/session-1/complete",
    method: "POST",
    body: {
      host_token: "host-token",
      detected_username: "developer",
      detected_username_source: "account_lookup",
      detected_username_suspicious: true,
      host_candidates: [
        {
          value: "agentty.local",
          kind: "local_domain",
          source: "hostname_fqdn",
          rank: 1,
        },
      ],
      host_environment_flags: ["wsl"],
      hostname_candidates: ["agentty.local"],
      uses_tailscale: false,
      ssh_host_public_keys: ["ssh-ed25519 AAAATEST"],
      relay_capable: true,
      relay_host_id: "relay-host-1",
      port: 22,
      platform: "linux",
    },
  });
});

test("fetchHostPairingSessionStatus posts the host token in the request body", async () => {
  const requests: RecordedRequest[] = [];

  const status = await fetchHostPairingSessionStatus(
    {
      baseUrl: new URL("https://agentty.esmadil.se"),
      hostToken: "host-token",
      sessionId: "session-1",
    },
    {
      fetchImpl: async (url, options = {}) => {
        requests.push({
          url: url.toString(),
          method: options.method ?? "GET",
          body: parseRequestBody(options.body),
        });
        return jsonResponse(200, {
          session_id: "session-1",
          status: "claimed",
          public_key: "ssh-ed25519 AAAATEST",
          expires_at_epoch_seconds: 123,
        });
      },
    }
  );

  assert.deepEqual(status, {
    completion: null,
    connectorBootstrap: null,
    expiresAtEpochSeconds: 123,
    publicKey: "ssh-ed25519 AAAATEST",
    sessionId: "session-1",
    status: "claimed",
  });
  assert.deepEqual(requests, [
    {
      url: "https://agentty.esmadil.se/v1/pairing-sessions/session-1/host-status",
      method: "POST",
      body: {
        host_token: "host-token",
      },
    },
  ]);
});

function jsonResponse(status: number, body: unknown) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function parseRequestBody(body: unknown): unknown {
  if (typeof body !== "string") {
    return null;
  }

  return JSON.parse(body);
}
