import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { extractKeyBlob, installAuthorizedKey } from "./authorized-keys.js";

test("extractKeyBlob reads the key body", () => {
  const blob = extractKeyBlob("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest comment");
  assert.equal(blob, "AAAAC3NzaC1lZDI1NTE5AAAAITest");
});

test("installAuthorizedKey appends once and stays idempotent by key blob", async () => {
  const homeDirectory = await mkdtemp(path.join(os.tmpdir(), "agentty-host-"));
  const firstKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest first";
  const secondKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest second";

  const firstInstall = await installAuthorizedKey(firstKey, { homeDirectory });
  assert.equal(firstInstall.alreadyPresent, false);

  const secondInstall = await installAuthorizedKey(secondKey, { homeDirectory });
  assert.equal(secondInstall.alreadyPresent, true);

  const contents = await readFile(
    path.join(homeDirectory, ".ssh", "authorized_keys"),
    "utf8"
  );
  assert.equal(contents, `${firstKey}\n`);
});
