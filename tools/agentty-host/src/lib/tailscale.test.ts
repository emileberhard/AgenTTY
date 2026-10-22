import assert from "node:assert/strict";
import test from "node:test";
import { detectTailscale } from "./tailscale.js";

test("detectTailscale reports missing installation", async () => {
  const tailscale = await detectTailscale({
    execFileImpl: async () => {
      throw errorWithCode("missing", "ENOENT");
    },
    platform: "darwin",
  });

  assert.deepEqual(tailscale, {
    installed: false,
    magicDNSName: null,
    shortHostname: null,
  });
});

test("detectTailscale returns both the full and short Tailscale hostnames when status is available", async () => {
  const tailscale = await detectTailscale({
    execFileImpl: async (command, args) => {
      if (command !== "tailscale") {
        throw new Error("unexpected command");
      }

      if (args[0] === "status" && args[1] === "--json") {
        return {
          stdout: JSON.stringify({
            Self: {
              DNSName: "agentty-host.tail123.ts.net.",
            },
          }),
        };
      }

      throw new Error("unexpected tailscale command");
    },
  });

  assert.deepEqual(tailscale, {
    installed: true,
    magicDNSName: "agentty-host.tail123.ts.net",
    shortHostname: "agentty-host",
  });
});

test("detectTailscale treats installed-but-unavailable status as no MagicDNS hostname", async () => {
  const tailscale = await detectTailscale({
    execFileImpl: async () => {
      throw errorWithStdout("daemon unavailable", "");
    },
  });

  assert.deepEqual(tailscale, {
    installed: true,
    magicDNSName: null,
    shortHostname: null,
  });
});

test("detectTailscale falls back to common macOS install paths when PATH lookup fails", async () => {
  const commands: string[] = [];
  const tailscale = await detectTailscale({
    execFileImpl: async (command, args) => {
      commands.push(command);
      if (args[0] !== "status" || args[1] !== "--json") {
        throw new Error("unexpected args");
      }
      if (command === "tailscale") {
        throw errorWithCode("missing", "ENOENT");
      }
      if (command === "/usr/local/bin/tailscale") {
        return {
          stdout: JSON.stringify({
            Self: {
              DNSName: "agentty-host.tail123.ts.net.",
            },
          }),
        };
      }
      throw errorWithCode("missing", "ENOENT");
    },
    platform: "darwin",
  });

  assert.deepEqual(tailscale, {
    installed: true,
    magicDNSName: "agentty-host.tail123.ts.net",
    shortHostname: "agentty-host",
  });
  assert.deepEqual(commands.slice(0, 2), ["tailscale", "/usr/local/bin/tailscale"]);
});

test("detectTailscale falls back to common Linux install paths when PATH lookup fails", async () => {
  const commands: string[] = [];
  const tailscale = await detectTailscale({
    execFileImpl: async (command, args) => {
      commands.push(command);
      if (args[0] !== "status" || args[1] !== "--json") {
        throw new Error("unexpected args");
      }
      if (command === "tailscale" || command === "/usr/bin/tailscale") {
        throw errorWithCode("missing", "ENOENT");
      }
      if (command === "/usr/local/bin/tailscale") {
        return {
          stdout: JSON.stringify({
            Self: {
              DNSName: "agentty-linux.tail123.ts.net.",
            },
          }),
        };
      }
      throw errorWithCode("missing", "ENOENT");
    },
    platform: "linux",
  });

  assert.deepEqual(tailscale, {
    installed: true,
    magicDNSName: "agentty-linux.tail123.ts.net",
    shortHostname: "agentty-linux",
  });
  assert.deepEqual(commands.slice(0, 3), [
    "tailscale",
    "/usr/bin/tailscale",
    "/usr/local/bin/tailscale",
  ]);
});

function errorWithCode(message: string, code: string): Error & { readonly code: string } {
  return Object.assign(new Error(message), { code });
}

function errorWithStdout(
  message: string,
  stdout: string
): Error & { readonly stdout: string } {
  return Object.assign(new Error(message), { stdout });
}
