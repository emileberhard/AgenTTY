import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import type {
  FileSystemLike,
  InstallAuthorizedKeyResult,
} from "./types.js";
import { isCodeError } from "./error-utils.js";

interface InstallAuthorizedKeyOptions {
  readonly fsImpl?: FileSystemLike | undefined;
  readonly homeDirectory?: string | undefined;
}

export async function installAuthorizedKey(
  publicKey: string,
  { fsImpl = fs, homeDirectory = os.homedir() }: InstallAuthorizedKeyOptions = {}
): Promise<InstallAuthorizedKeyResult> {
  const normalizedPublicKey = normalizePublicKey(publicKey);
  const keyBlob = extractKeyBlob(normalizedPublicKey);

  const sshDirectory = path.join(homeDirectory, ".ssh");
  const authorizedKeysPath = path.join(sshDirectory, "authorized_keys");

  await fsImpl.mkdir(sshDirectory, { recursive: true, mode: 0o700 });
  await fsImpl.chmod(sshDirectory, 0o700);

  let existingContents = "";
  try {
    existingContents = await fsImpl.readFile(authorizedKeysPath, "utf8");
  } catch (error) {
    if (!isCodeError(error, "ENOENT")) {
      throw error;
    }
    await fsImpl.writeFile(authorizedKeysPath, "", { mode: 0o600 });
  }

  const alreadyPresent = existingContents
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .some((line) => {
      try {
        return extractKeyBlob(line) === keyBlob;
      } catch {
        return false;
      }
    });

  if (!alreadyPresent) {
    const separator =
      existingContents.length === 0 || existingContents.endsWith("\n") ? "" : "\n";
    await fsImpl.appendFile(
      authorizedKeysPath,
      `${separator}${normalizedPublicKey}\n`,
      "utf8"
    );
  }

  await fsImpl.chmod(authorizedKeysPath, 0o600);

  return {
    authorizedKeysPath,
    alreadyPresent,
  };
}

export function normalizePublicKey(publicKey: string): string {
  const trimmed = publicKey.trim();
  if (!trimmed) {
    throw new Error("Pairing response did not include a public key.");
  }

  const lines = trimmed
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length !== 1) {
    throw new Error("Pairing response contained an invalid public key.");
  }

  const [normalizedLine] = lines;
  if (!normalizedLine) {
    throw new Error("Pairing response contained an invalid public key.");
  }

  extractKeyBlob(normalizedLine);
  return normalizedLine;
}

export function extractKeyBlob(publicKeyLine: string): string {
  const parts = publicKeyLine.trim().split(/\s+/u);
  if (parts.length < 2) {
    throw new Error("Invalid OpenSSH public key.");
  }

  const [type, blob] = parts;
  if (!type || !blob || !isSupportedOpenSshKeyType(type)) {
    throw new Error("Invalid OpenSSH public key.");
  }

  return blob;
}

function isSupportedOpenSshKeyType(type: string): boolean {
  return type.startsWith("ssh-") || type.startsWith("ecdsa-") || type.startsWith("sk-");
}
