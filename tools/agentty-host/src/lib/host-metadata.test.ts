import assert from "node:assert/strict";
import test from "node:test";
import {
  detectHostMetadata,
  normalizePlatform,
  rankHostCandidates,
} from "./host-metadata.js";
import {
  HOST_CANDIDATE_SOURCES,
  HOST_ENVIRONMENT_FLAGS,
} from "./types.js";

test("normalizePlatform maps supported platforms", () => {
  assert.equal(normalizePlatform("darwin"), "macos");
  assert.equal(normalizePlatform("linux"), "linux");
});

test("normalizePlatform rejects unsupported platforms", () => {
  assert.throws(
    () => normalizePlatform("win32"),
    /@agentty-app\/pair only supports macOS and Linux\./u
  );
});

test("detectHostMetadata deduplicates hostname candidates", async () => {
  const metadata = await detectHostMetadata({
    env: { USER: "developer", HOSTNAME: "agentty.local" },
    hostname: "agentty.local",
    platform: "linux",
    execFileImpl: async (command, args) => {
      if (command === "id" && args[0] === "-u") {
        return { stdout: "501\n" };
      }
      if (command === "getent" && args[0] === "passwd") {
        return { stdout: "developer:x:501:20::/home/developer:/bin/zsh\n" };
      }
      if (command === "hostname" && args[0] === "-f") {
        return { stdout: "agentty.local\n" };
      }
      if (command === "hostname") {
        return { stdout: "agentty\n" };
      }
      throw new Error("unexpected command");
    },
  });

  assert.deepEqual(metadata, {
    detectedUsername: "developer",
    detectedUsernameSource: "account_lookup",
    detectedUsernameSuspicious: false,
    hostCandidates: [
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
    hostEnvironmentFlags: [],
    hostnameCandidates: ["agentty.local", "agentty"],
    platform: "linux",
    port: 22,
  });
});

test("detectHostMetadata falls back to env USER only when id lookup fails", async () => {
  const metadata = await detectHostMetadata({
    env: { USER: "developer" },
    hostname: "agentty",
    platform: "linux",
    execFileImpl: async (command, args) => {
      if (command === "id" && args[0] === "-u") {
        throw new Error("missing uid");
      }
      if (command === "id" && args[0] === "-un") {
        throw new Error("missing id");
      }
      if (command === "whoami") {
        throw new Error("missing whoami");
      }
      if (command === "hostname" && args[0] === "-f") {
        throw new Error("missing fqdn");
      }
      if (command === "hostname") {
        return { stdout: "agentty\n" };
      }
      throw new Error("unexpected command");
    },
  });

  assert.equal(metadata.detectedUsername, "developer");
  assert.equal(metadata.detectedUsernameSource, "env_user");
  assert.equal(metadata.detectedUsernameSuspicious, true);
});

test("detectHostMetadata falls back to whoami when id -un returns the command name", async () => {
  const metadata = await detectHostMetadata({
    env: { USER: "developer" },
    hostname: "agentty",
    platform: "linux",
    execFileImpl: async (command, args) => {
      if (command === "id" && args[0] === "-u") {
        return { stdout: "501\n" };
      }
      if (command === "getent" && args[0] === "passwd") {
        throw new Error("missing passwd entry");
      }
      if (command === "id" && args[0] === "-un") {
        return { stdout: "id\n" };
      }
      if (command === "whoami") {
        return { stdout: "developer\n" };
      }
      if (command === "hostname" && args[0] === "-f") {
        throw new Error("missing fqdn");
      }
      if (command === "hostname") {
        return { stdout: "agentty\n" };
      }
      throw new Error("unexpected command");
    },
  });

  assert.equal(metadata.detectedUsername, "developer");
  assert.equal(metadata.detectedUsernameSource, "whoami_command");
  assert.equal(metadata.detectedUsernameSuspicious, true);
});

test("detectHostMetadata fails when every username source is unavailable", async () => {
  await assert.rejects(
    detectHostMetadata({
      env: {},
      hostname: "agentty",
      platform: "linux",
      execFileImpl: async (command, args) => {
        if (command === "id") {
          throw new Error("missing id");
        }
        if (command === "whoami") {
          throw new Error("missing whoami");
        }
        if (command === "hostname") {
          return { stdout: "agentty\n" };
        }
        throw new Error("unexpected command");
      },
    }),
    /Failed to detect the current username\./u
  );
});

test("detectHostMetadata records host environment flags for WSL-like env", async () => {
  const metadata = await detectHostMetadata({
    env: {
      USER: "developer",
      WSL_DISTRO_NAME: "Ubuntu",
      WSL_INTEROP: "/run/WSL/1_interop",
    },
    hostname: "fss-wsl",
    platform: "linux",
    execFileImpl: async (command, args) => {
      if (command === "id" && args[0] === "-u") {
        return { stdout: "1000\n" };
      }
      if (command === "getent" && args[0] === "passwd") {
        return { stdout: "developer:x:1000:1000::/home/developer:/bin/bash\n" };
      }
      if (command === "id" && args[0] === "-un") {
        return { stdout: "developer\n" };
      }
      if (command === "hostname" && args[0] === "-f") {
        return { stdout: "fss-wsl.localdomain\n" };
      }
      if (command === "hostname") {
        return { stdout: "fss-wsl\n" };
      }
      throw new Error("unexpected command");
    },
  });

  assert.deepEqual(metadata.hostEnvironmentFlags, [HOST_ENVIRONMENT_FLAGS.wsl]);
});

test("rankHostCandidates prefers tailscale and fqdn candidates over weaker hostnames", () => {
  const ranked = rankHostCandidates([
    { value: "agentty", source: HOST_CANDIDATE_SOURCES.hostname },
    {
      value: "agentty-host.tail123.ts.net",
      source: HOST_CANDIDATE_SOURCES.tailscaleMagicDNS,
    },
    { value: "agentty-host", source: HOST_CANDIDATE_SOURCES.tailscaleShort },
    {
      value: "agentty.localdomain",
      source: HOST_CANDIDATE_SOURCES.hostnameFQDN,
    },
    {
      value: "agentty.example.com",
      source: HOST_CANDIDATE_SOURCES.hostnameFQDN,
    },
  ]);

  assert.deepEqual(ranked, [
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
      value: "agentty.example.com",
      kind: "fqdn",
      source: "hostname_fqdn",
      rank: 3,
    },
    {
      value: "agentty.localdomain",
      kind: "local_domain",
      source: "hostname_fqdn",
      rank: 4,
    },
    {
      value: "agentty",
      kind: "single_label",
      source: "hostname",
      rank: 5,
    },
  ]);
});
