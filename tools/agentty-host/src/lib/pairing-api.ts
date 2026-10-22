import type {
  FetchLike,
  HostPairingSessionStatus,
  JSONResponseLike,
  PairingMetadata,
  PairingSession,
  PairingSessionState,
} from "./types.js";
import { PAIRING_SESSION_STATES } from "./types.js";

type PairingCompletionMetadataPayload = Partial<PairingMetadata> & {
  readonly errorMessage?: string;
};

type PairingCompletionRequestBody = {
  detected_username?: string;
  detected_username_source?: PairingCompletionMetadataPayload["detectedUsernameSource"];
  detected_username_suspicious?: boolean;
  error_message?: string;
  host_candidates?: PairingMetadata["hostCandidates"];
  host_environment_flags?: PairingMetadata["hostEnvironmentFlags"];
  host_token: string;
  hostname_candidates?: readonly string[];
  platform?: PairingCompletionMetadataPayload["platform"];
  port?: number;
  relay_capable?: boolean;
  relay_host_id?: string;
  ssh_host_public_keys?: readonly string[];
  uses_tailscale?: boolean;
};

type HostPairingSessionStatusRequestBody = {
  readonly host_token: string;
};

interface CreatePairingSessionOptions {
  readonly baseUrl: URL;
}

interface FetchHostPairingSessionStatusOptions {
  readonly baseUrl: URL;
  readonly hostToken: string;
  readonly sessionId: string;
}

interface CompletePairingSessionOptions extends FetchHostPairingSessionStatusOptions {
  readonly metadata: PairingCompletionMetadataPayload;
}

export async function createPairingSession(
  { baseUrl }: CreatePairingSessionOptions,
  { fetchImpl = fetch as FetchLike }: { readonly fetchImpl?: FetchLike } = {}
): Promise<PairingSession> {
  const response = await fetchImpl(new URL("/v1/pairing-sessions", baseUrl), {
    method: "POST",
  });
  const data = await parseJsonResponse(response, "Failed to create pairing session.");

  return parsePairingSession(data);
}

export async function fetchHostPairingSessionStatus(
  { baseUrl, hostToken, sessionId }: FetchHostPairingSessionStatusOptions,
  { fetchImpl = fetch as FetchLike }: { readonly fetchImpl?: FetchLike } = {}
): Promise<HostPairingSessionStatus> {
  const response = await fetchImpl(
    new URL(`/v1/pairing-sessions/${sessionId}/host-status`, baseUrl),
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        host_token: hostToken,
      } satisfies HostPairingSessionStatusRequestBody),
    }
  );
  const data = await parseJsonResponse(
    response,
    "Failed to load pairing session status."
  );

  return parseHostPairingSessionStatus(data);
}

export async function completePairingSession(
  { baseUrl, hostToken, metadata, sessionId }: CompletePairingSessionOptions,
  { fetchImpl = fetch as FetchLike }: { readonly fetchImpl?: FetchLike } = {}
): Promise<unknown> {
  const response = await postPairingCompletion(
    {
      baseUrl,
      body: pairingCompletionRequestBody(hostToken, metadata),
      sessionId,
    },
    fetchImpl
  );

  return parseJsonResponse(response, "Failed to complete pairing session.");
}

function pairingCompletionRequestBody(
  hostToken: string,
  metadata: PairingCompletionMetadataPayload
): PairingCompletionRequestBody {
  const body: PairingCompletionRequestBody = {
    host_token: hostToken,
  };

  if (metadata.detectedUsername !== undefined) {
    body.detected_username = metadata.detectedUsername;
  }
  if (metadata.detectedUsernameSource !== undefined) {
    body.detected_username_source = metadata.detectedUsernameSource;
  }
  if (metadata.detectedUsernameSuspicious !== undefined) {
    body.detected_username_suspicious = metadata.detectedUsernameSuspicious;
  }
  if (metadata.hostCandidates !== undefined) {
    body.host_candidates = metadata.hostCandidates;
  }
  if (metadata.hostEnvironmentFlags !== undefined) {
    body.host_environment_flags = metadata.hostEnvironmentFlags;
  }
  if (metadata.hostnameCandidates !== undefined) {
    body.hostname_candidates = metadata.hostnameCandidates;
  }
  if (metadata.usesTailscale !== undefined) {
    body.uses_tailscale = metadata.usesTailscale;
  }
  if (metadata.relayCapable !== undefined) {
    body.relay_capable = metadata.relayCapable;
  }
  if (metadata.relayHostId !== undefined) {
    body.relay_host_id = metadata.relayHostId;
  }
  if (metadata.sshHostPublicKeys !== undefined) {
    body.ssh_host_public_keys = metadata.sshHostPublicKeys;
  }
  if (metadata.port !== undefined) {
    body.port = metadata.port;
  }
  if (metadata.platform !== undefined) {
    body.platform = metadata.platform;
  }
  if (metadata.errorMessage !== undefined) {
    body.error_message = metadata.errorMessage;
  }

  return body;
}

async function postPairingCompletion(
  {
    baseUrl,
    body,
    sessionId,
  }: {
    readonly baseUrl: URL;
    readonly body: PairingCompletionRequestBody;
    readonly sessionId: string;
  },
  fetchImpl: FetchLike
): Promise<JSONResponseLike> {
  return fetchImpl(new URL(`/v1/pairing-sessions/${sessionId}/complete`, baseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

async function parseJsonResponse(
  response: JSONResponseLike,
  fallbackMessage: string
): Promise<unknown> {
  let data: unknown = null;
  try {
    data = await response.json();
  } catch {
    data = null;
  }

  if (response.ok) {
    return data;
  }

  const detail = errorMessageFromResponse(data);
  throw new Error(detail ?? fallbackMessage);
}

function parsePairingSession(data: unknown): PairingSession {
  const object = expectObject(data, "Failed to create pairing session.");

  return {
    sessionId: expectString(object.session_id, "Pairing session did not include a session ID."),
    pairingCode: expectString(
      object.pairing_code,
      "Pairing session did not include a pairing code."
    ),
    qrPayload: expectString(
      object.qr_payload,
      "Pairing session did not include a QR payload."
    ),
    hostToken: expectString(object.host_token, "Pairing session did not include a host token."),
    expiresAtEpochSeconds: expectNumber(
      object.expires_at_epoch_seconds,
      "Pairing session did not include a valid expiration time."
    ),
  };
}

function parseHostPairingSessionStatus(data: unknown): HostPairingSessionStatus {
  const object = expectObject(data, "Failed to load pairing session status.");

  return {
    sessionId: expectString(
      object.session_id,
      "Pairing session status did not include a session ID."
    ),
    status: parsePairingSessionState(object.status),
    publicKey: optionalString(object.public_key),
    completion: parseCompletion(object.completion),
    connectorBootstrap: parseConnectorBootstrap(object.connector_bootstrap),
    expiresAtEpochSeconds: expectNumber(
      object.expires_at_epoch_seconds,
      "Pairing session status did not include a valid expiration time."
    ),
  };
}

function parseCompletion(
  value: unknown
): HostPairingSessionStatus["completion"] {
  if (value === null || value === undefined) {
    return null;
  }

  const object = expectObject(value, "Pairing session completion payload was invalid.");
  return {
    errorMessage: optionalString(object.error_message),
  };
}

function parseConnectorBootstrap(
  value: unknown
): HostPairingSessionStatus["connectorBootstrap"] {
  if (value === null || value === undefined) {
    return null;
  }

  const object = expectObject(value, "Pairing session connector bootstrap was invalid.");
  return {
    token: expectString(
      object.token,
      "Pairing session connector bootstrap did not include a token."
    ),
    expiresAtEpochSeconds: expectNumber(
      object.expires_at_epoch_seconds,
      "Pairing session connector bootstrap did not include a valid expiration time."
    ),
  };
}

function parsePairingSessionState(value: unknown): PairingSessionState {
  const state = expectString(value, "Pairing session status was invalid.");
  switch (state) {
    case PAIRING_SESSION_STATES.pending:
    case PAIRING_SESSION_STATES.claimed:
    case PAIRING_SESSION_STATES.completed:
    case PAIRING_SESSION_STATES.failed:
    case PAIRING_SESSION_STATES.expired:
      return state;
    default:
      throw new Error(`Unexpected pairing session status: ${state}`);
  }
}

function errorMessageFromResponse(value: unknown): string | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }

  if ("detail" in value && typeof value.detail === "string") {
    return value.detail;
  }
  if ("error" in value && typeof value.error === "string") {
    return value.error;
  }
  if ("message" in value && typeof value.message === "string") {
    return value.message;
  }
  return null;
}

function expectObject(
  value: unknown,
  errorMessage: string
): Record<string, unknown> {
  if (typeof value !== "object" || value === null) {
    throw new Error(errorMessage);
  }
  return value as Record<string, unknown>;
}

function expectString(value: unknown, errorMessage: string): string {
  if (typeof value !== "string" || !value) {
    throw new Error(errorMessage);
  }
  return value;
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}

function expectNumber(value: unknown, errorMessage: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(errorMessage);
  }
  return value;
}
