import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ExecFileLike, TailscaleStatus } from "./types.js";
import { isCodeError, stdoutFromError } from "./error-utils.js";
import {
  normalizeMagicDNSName,
  preferredMagicDNSHostname,
} from "./hostname-utils.js";

const execFileAsync = promisify(execFile) as ExecFileLike;

interface DetectTailscaleOptions {
  readonly execFileImpl?: ExecFileLike | undefined;
  readonly platform?: NodeJS.Platform | undefined;
}

interface TailscaleStatusResponse {
  readonly Self?: {
    readonly DNSName?: string;
  };
}

export async function detectTailscale(
  { execFileImpl = execFileAsync, platform = process.platform }: DetectTailscaleOptions = {}
): Promise<TailscaleStatus> {
  for (const executablePath of tailscaleExecutableCandidates(platform)) {
    try {
      const { stdout } = await execFileImpl(executablePath, ["status", "--json"]);
      return statusFromRawValue(stdout, true);
    } catch (error) {
      if (isCodeError(error, "ENOENT")) {
        continue;
      }

      return statusFromRawValue(stdoutFromError(error), true);
    }
  }

  return {
    installed: false,
    magicDNSName: null,
    shortHostname: null,
  };
}

function statusFromRawValue(rawValue: string, installed: boolean): TailscaleStatus {
  const status = parseStatusJson(rawValue);
  const magicDNSName = normalizeMagicDNSName(status?.Self?.DNSName);
  return {
    installed,
    magicDNSName,
    shortHostname: preferredMagicDNSHostname(magicDNSName),
  };
}

function parseStatusJson(rawValue: string): TailscaleStatusResponse | null {
  const normalized = rawValue.trim();
  if (!normalized) {
    return null;
  }

  try {
    const parsed = JSON.parse(normalized);
    return isTailscaleStatusResponse(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function isTailscaleStatusResponse(value: unknown): value is TailscaleStatusResponse {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  if (!("Self" in value) || value.Self === undefined) {
    return true;
  }

  const self = value.Self;
  if (typeof self !== "object" || self === null) {
    return false;
  }

  return !("DNSName" in self) || typeof self.DNSName === "string";
}

function tailscaleExecutableCandidates(
  platform: NodeJS.Platform
): readonly string[] {
  const candidates = ["tailscale"];

  if (platform === "darwin") {
    candidates.push(
      "/usr/local/bin/tailscale",
      "/opt/homebrew/bin/tailscale",
      "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    );
  } else if (platform === "linux") {
    candidates.push(
      "/usr/bin/tailscale",
      "/usr/local/bin/tailscale",
      "/snap/bin/tailscale"
    );
  }

  return Array.from(new Set(candidates));
}
