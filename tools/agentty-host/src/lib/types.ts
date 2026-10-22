import type { Writable } from "node:stream";

export const PACKAGE_NAME = "@agentty-app/pair";
const resolvedBuildVersion = process.env.AGENTTY_BUILD_VERSION?.trim();
const resolvedGitSha = process.env.AGENTTY_GIT_SHA?.trim();
const resolvedGitTag = process.env.AGENTTY_GIT_TAG?.trim();

export const BUILD_VERSION = resolvedBuildVersion || resolvedGitSha || "dev";
export const BUILD_GIT_SHA = resolvedGitSha || BUILD_VERSION;
export const BUILD_GIT_TAG = resolvedGitTag || null;
export const DEFAULT_SSH_PORT = 22;

export const SUPPORTED_PLATFORMS = {
  linux: "linux",
  macos: "macos",
} as const;

export type SupportedPlatform =
  (typeof SUPPORTED_PLATFORMS)[keyof typeof SUPPORTED_PLATFORMS];

export const DETECTED_USERNAME_SOURCES = {
  accountLookup: "account_lookup",
  envUser: "env_user",
  idCommand: "id_command",
  whoamiCommand: "whoami_command",
} as const;

export type DetectedUsernameSource =
  (typeof DETECTED_USERNAME_SOURCES)[keyof typeof DETECTED_USERNAME_SOURCES];

export const HOST_ENVIRONMENT_FLAGS = {
  container: "container",
  wsl: "wsl",
} as const;

export type HostEnvironmentFlag =
  (typeof HOST_ENVIRONMENT_FLAGS)[keyof typeof HOST_ENVIRONMENT_FLAGS];

export const HOST_CANDIDATE_KINDS = {
  fqdn: "fqdn",
  localDomain: "local_domain",
  singleLabel: "single_label",
  tailscaleFQDN: "tailscale_fqdn",
  tailscaleShort: "tailscale_short",
} as const;

export type HostCandidateKind =
  (typeof HOST_CANDIDATE_KINDS)[keyof typeof HOST_CANDIDATE_KINDS];

export const HOST_CANDIDATE_SOURCES = {
  envHostname: "env_hostname",
  hostname: "hostname",
  hostnameFQDN: "hostname_fqdn",
  legacyHostnameCandidates: "legacy_hostname_candidates",
  osHostname: "os_hostname",
  scutilHostname: "scutil_hostname",
  scutilLocalhostname: "scutil_localhostname",
  tailscaleMagicDNS: "tailscale_magicdns",
  tailscaleShort: "tailscale_short",
} as const;

export type HostCandidateSource =
  (typeof HOST_CANDIDATE_SOURCES)[keyof typeof HOST_CANDIDATE_SOURCES];

export interface HostCandidate {
  readonly kind: HostCandidateKind;
  readonly rank: number;
  readonly source: HostCandidateSource | null;
  readonly value: string;
}

export interface UnrankedHostCandidate {
  readonly source?: HostCandidateSource | null;
  readonly value: string;
}

export interface HostMetadata {
  readonly detectedUsername: string;
  readonly detectedUsernameSource: DetectedUsernameSource;
  readonly detectedUsernameSuspicious: boolean;
  readonly hostCandidates: HostCandidate[];
  readonly hostEnvironmentFlags: HostEnvironmentFlag[];
  readonly hostnameCandidates: string[];
  readonly platform: SupportedPlatform;
  readonly port: number;
}

export interface PairingMetadata extends HostMetadata {
  readonly errorMessage?: string;
  readonly relayCapable?: boolean;
  readonly relayHostId?: string;
  readonly sshHostPublicKeys: readonly string[];
  readonly usesTailscale: boolean;
}

export const PAIRING_SESSION_STATES = {
  claimed: "claimed",
  completed: "completed",
  expired: "expired",
  failed: "failed",
  pending: "pending",
} as const;

export type PairingSessionState =
  (typeof PAIRING_SESSION_STATES)[keyof typeof PAIRING_SESSION_STATES];

export interface PairingSession {
  readonly expiresAtEpochSeconds: number;
  readonly hostToken: string;
  readonly pairingCode: string;
  readonly qrPayload: string;
  readonly sessionId: string;
}

export interface PairingCompletion {
  readonly errorMessage: string | null;
}

export interface ConnectorBootstrap {
  readonly expiresAtEpochSeconds: number;
  readonly token: string;
}

export interface HostPairingSessionStatus {
  readonly completion: PairingCompletion | null;
  readonly connectorBootstrap: ConnectorBootstrap | null;
  readonly expiresAtEpochSeconds: number;
  readonly publicKey: string | null;
  readonly sessionId: string;
  readonly status: PairingSessionState;
}

export interface TailscaleStatus {
  readonly installed: boolean;
  readonly magicDNSName: string | null;
  readonly shortHostname: string | null;
}

export interface InstallAuthorizedKeyResult {
  readonly alreadyPresent: boolean;
  readonly authorizedKeysPath: string;
}

export type Environment = NodeJS.ProcessEnv;

export interface ExecFileResult {
  readonly stderr?: string;
  readonly stdout: string;
}

export type ExecFileLike = (
  file: string,
  args: readonly string[]
) => Promise<ExecFileResult>;

export interface FileSystemLike {
  appendFile(path: string, data: string, options?: BufferEncoding): Promise<void>;
  chmod(path: string, mode: number): Promise<void>;
  mkdir(
    path: string,
    options?: {
      mode?: number;
      recursive?: boolean;
    }
  ): Promise<void | string | undefined>;
  readFile(path: string, encoding: BufferEncoding): Promise<string>;
  writeFile(
    path: string,
    data: string,
    options?: {
      mode?: number;
    }
  ): Promise<void>;
}

export interface CommandIO {
  readonly stderr: Writable;
  readonly stdin?: NodeJS.ReadableStream & {
    readonly isTTY?: boolean;
  };
  readonly stdout: Writable;
}

export interface JSONResponseLike {
  readonly ok: boolean;
  readonly status: number;
  json(): Promise<unknown>;
}

export type FetchLike = (
  input: URL,
  init?: RequestInit
) => Promise<JSONResponseLike>;

export interface TailscalePromptOptions {
  readonly io: CommandIO;
  readonly preferredHostname: string;
}

export type TailscalePrompt = (
  options: TailscalePromptOptions
) => Promise<boolean>;
