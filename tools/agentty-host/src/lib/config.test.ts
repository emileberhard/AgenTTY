import assert from "node:assert/strict";
import test from "node:test";
import { resolveBaseUrl } from "./config.js";

test("resolveBaseUrl uses the default relay URL", () => {
  assert.equal(resolveBaseUrl({}).toString(), "https://agentty.esmadil.se/");
});

test("resolveBaseUrl accepts a valid override", () => {
  assert.equal(
    resolveBaseUrl({ AGENTTY_BACKEND_URL: "http://127.0.0.1:5012" }).toString(),
    "http://127.0.0.1:5012/"
  );
});

test("resolveBaseUrl accepts the legacy override", () => {
  assert.equal(
    resolveBaseUrl({ AGENTTY_NOTIFY_RELAY_URL: "http://127.0.0.1:5012" }).toString(),
    "http://127.0.0.1:5012/"
  );
});

test("resolveBaseUrl rejects non-local http overrides", () => {
  assert.throws(
    () => resolveBaseUrl({ AGENTTY_BACKEND_URL: "http://example.com" }),
    /Invalid AGENTTY_BACKEND_URL value\./u
  );
});

test("resolveBaseUrl rejects invalid overrides", () => {
  assert.throws(
    () => resolveBaseUrl({ AGENTTY_BACKEND_URL: "ftp://example.com" }),
    /Invalid AGENTTY_BACKEND_URL value\./u
  );
});
