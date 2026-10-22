import type { Environment } from "./types.js";

const DEFAULT_BASE_URL = "https://agentty.esmadil.se";
const BASE_URL_ENVIRONMENT_KEY = "AGENTTY_BACKEND_URL";
// Remove the legacy override key after the renamed backend build is distributed.
const LEGACY_BASE_URL_ENVIRONMENT_KEY = "AGENTTY_NOTIFY_RELAY_URL";

export function resolveBaseUrl(env: Environment = process.env): URL {
  const override =
    env[BASE_URL_ENVIRONMENT_KEY] ?? env[LEGACY_BASE_URL_ENVIRONMENT_KEY];
  if (!override) {
    return new URL(DEFAULT_BASE_URL);
  }

  let parsed: URL;
  try {
    parsed = new URL(override);
  } catch {
    throw new Error(`Invalid ${BASE_URL_ENVIRONMENT_KEY} value.`);
  }

  if (!isAllowedBaseUrl(parsed)) {
    throw new Error(`Invalid ${BASE_URL_ENVIRONMENT_KEY} value.`);
  }

  return parsed;
}

function isAllowedBaseUrl(url: URL): boolean {
  const hostname = url.hostname.toLowerCase();
  if (!hostname) {
    return false;
  }

  if (url.protocol === "https:") {
    return true;
  }

  return (
    url.protocol === "http:" &&
    (hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1")
  );
}

export { BASE_URL_ENVIRONMENT_KEY, DEFAULT_BASE_URL };
