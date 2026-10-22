import { execFile as nodeExecFile } from "node:child_process";
import { promisify } from "node:util";
import type { ExecFileLike } from "./types.js";

const execFile = promisify(nodeExecFile);

const DEFAULT_SCAN_TIMEOUT_SECONDS = 5;
const DEFAULT_KEY_TYPES = "rsa,ecdsa,ed25519";

export async function collectLocalSSHHostPublicKeys(
  port: number,
  execFileImpl: ExecFileLike = defaultExecFile
): Promise<string[]> {
  const result = await execFileImpl("ssh-keyscan", [
    "-T",
    String(DEFAULT_SCAN_TIMEOUT_SECONDS),
    "-p",
    String(port),
    "-t",
    DEFAULT_KEY_TYPES,
    "127.0.0.1",
  ]);

  const publicKeys = result.stdout
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"))
    .map((line) => {
      const parts = line.split(/\s+/u);
      return parts.length >= 3 ? `${parts[1]} ${parts[2]}` : null;
    })
    .filter((value): value is string => value !== null);

  const deduplicatedPublicKeys = Array.from(new Set(publicKeys));
  if (deduplicatedPublicKeys.length === 0) {
    throw new Error("Failed to collect the host SSH public keys from local sshd.");
  }

  return deduplicatedPublicKeys;
}

async function defaultExecFile(
  file: string,
  args: readonly string[]
): Promise<{ stdout: string; stderr?: string }> {
  const result = await execFile(file, args);
  return {
    stdout: result.stdout,
    stderr: result.stderr,
  };
}
