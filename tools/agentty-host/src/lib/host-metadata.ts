import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type {
  DetectedUsernameSource,
  Environment,
  ExecFileLike,
  HostCandidate,
  HostEnvironmentFlag,
  HostCandidateKind,
  HostCandidateSource,
  HostMetadata,
  SupportedPlatform,
  UnrankedHostCandidate,
} from "./types.js";
import {
  DEFAULT_SSH_PORT,
  DETECTED_USERNAME_SOURCES,
  HOST_ENVIRONMENT_FLAGS,
  HOST_CANDIDATE_KINDS,
  HOST_CANDIDATE_SOURCES,
  SUPPORTED_PLATFORMS,
} from "./types.js";
import {
  isFQDN,
  isLocalDomainHostname,
  isTailscaleMagicDNSHostname,
} from "./hostname-utils.js";

const execFileAsync = promisify(execFile) as ExecFileLike;
const suspiciousEnvUsernames = new Set(["id", "user", "username"]);
const hostCandidateKindPriority: Record<HostCandidateKind, number> = {
  [HOST_CANDIDATE_KINDS.tailscaleShort]: 0,
  [HOST_CANDIDATE_KINDS.tailscaleFQDN]: 1,
  [HOST_CANDIDATE_KINDS.fqdn]: 2,
  [HOST_CANDIDATE_KINDS.localDomain]: 3,
  [HOST_CANDIDATE_KINDS.singleLabel]: 4,
};

interface DetectHostMetadataOptions {
  readonly env?: Environment;
  readonly execFileImpl?: ExecFileLike | undefined;
  readonly hostname?: string | undefined;
  readonly platform?: NodeJS.Platform;
}

interface DetectedUsername {
  readonly source: DetectedUsernameSource;
  readonly suspicious: boolean;
  readonly value: string;
}

interface NormalizedUsernameCandidate {
  readonly discardedSuspiciousValue: boolean;
  readonly value: string | null;
}

interface HostnameCommand {
  readonly args: readonly string[];
  readonly command: string;
  readonly source: HostCandidateSource;
}

export async function detectHostMetadata({
  env = process.env,
  execFileImpl = execFileAsync,
  hostname,
  platform = process.platform,
}: DetectHostMetadataOptions = {}): Promise<HostMetadata> {
  const normalizedPlatform = normalizePlatform(platform);
  const detectedUsername = await detectUsername({ env, execFileImpl, platform: normalizedPlatform });
  const hostCandidates = await detectHostCandidates({
    env,
    execFileImpl,
    hostname,
    platform: normalizedPlatform,
  });
  const hostEnvironmentFlags = detectHostEnvironmentFlags(env, normalizedPlatform);

  return {
    detectedUsername: detectedUsername.value,
    detectedUsernameSource: detectedUsername.source,
    detectedUsernameSuspicious: detectedUsername.suspicious,
    hostCandidates,
    hostEnvironmentFlags,
    hostnameCandidates: hostCandidates.map((candidate) => candidate.value),
    platform: normalizedPlatform,
    port: DEFAULT_SSH_PORT,
  };
}

export function rankHostCandidates(
  candidates: readonly (UnrankedHostCandidate | string | null | undefined)[]
): HostCandidate[] {
  const uniqueCandidates: Array<{
    readonly source: HostCandidateSource | null;
    readonly value: string;
  }> = [];
  const seenValues = new Set<string>();

  for (const candidate of candidates) {
    const normalizedValue = normalizeHostnameCandidate(
      typeof candidate === "string" ? candidate : candidate?.value
    );
    if (!normalizedValue) {
      continue;
    }

    const dedupeKey = normalizedValue.toLowerCase();
    if (seenValues.has(dedupeKey)) {
      continue;
    }

    seenValues.add(dedupeKey);
    uniqueCandidates.push({
      value: normalizedValue,
      source: typeof candidate === "string" ? null : candidate?.source ?? null,
    });
  }

  const shortTailscaleHostnames = new Set(
    uniqueCandidates
      .map((candidate) => candidate.value)
      .filter(isTailscaleMagicDNSHostname)
      .map((candidate) => candidate.split(".", 1)[0]?.trim()?.toLowerCase())
      .filter((candidate): candidate is string => Boolean(candidate))
  );

  return uniqueCandidates
    .map((candidate, index) => ({
      ...candidate,
      index,
      kind: classifyHostCandidate(candidate, shortTailscaleHostnames),
    }))
    .sort((left, right) => {
      const priorityDelta =
        hostCandidateKindPriority[left.kind] - hostCandidateKindPriority[right.kind];
      if (priorityDelta !== 0) {
        return priorityDelta;
      }
      return left.index - right.index;
    })
    .map((candidate, index) => ({
      value: candidate.value,
      kind: candidate.kind,
      source: candidate.source,
      rank: index + 1,
    }));
}

export function normalizePlatform(platform: NodeJS.Platform): SupportedPlatform {
  switch (platform) {
    case "darwin":
      return SUPPORTED_PLATFORMS.macos;
    case "linux":
      return SUPPORTED_PLATFORMS.linux;
    default:
      throw new Error("@agentty-app/pair only supports macOS and Linux.");
  }
}

async function detectUsername({
  env,
  execFileImpl,
  platform,
}: {
  readonly env: Environment;
  readonly execFileImpl: ExecFileLike;
  readonly platform: SupportedPlatform;
}): Promise<DetectedUsername> {
  const uid = await detectUid(execFileImpl);
  const authoritativeUser = uid
    ? await lookupUsernameByUid({ execFileImpl, platform, uid })
    : null;
  const idUser = await runUsernameCommand(execFileImpl, "id", ["-un"]);
  const whoamiUser = await runUsernameCommand(execFileImpl, "whoami", []);
  const envUser = normalizeUsernameCandidate(env.USER);
  const distinctObservedValues = new Set(
    [authoritativeUser, idUser.value, whoamiUser.value, envUser.value]
      .filter((value): value is string => Boolean(value))
      .map((value) => value.toLowerCase())
  );
  let chosenUser: DetectedUsername | null = null;

  if (authoritativeUser) {
    chosenUser = {
      value: authoritativeUser,
      source: DETECTED_USERNAME_SOURCES.accountLookup,
      suspicious: false,
    };
  }

  if (chosenUser == null && idUser.value && whoamiUser.value && idUser.value === whoamiUser.value) {
    chosenUser = {
      value: idUser.value,
      source: DETECTED_USERNAME_SOURCES.idCommand,
      suspicious: false,
    };
  }

  if (chosenUser == null && idUser.value && envUser.value && idUser.value === envUser.value) {
    chosenUser = {
      value: idUser.value,
      source: DETECTED_USERNAME_SOURCES.idCommand,
      suspicious: false,
    };
  }

  if (
    chosenUser == null &&
    whoamiUser.value &&
    envUser.value &&
    whoamiUser.value === envUser.value
  ) {
    chosenUser = {
      value: whoamiUser.value,
      source: DETECTED_USERNAME_SOURCES.whoamiCommand,
      suspicious: false,
    };
  }

  if (chosenUser == null && idUser.value) {
    chosenUser = {
      value: idUser.value,
      source: DETECTED_USERNAME_SOURCES.idCommand,
      suspicious: true,
    };
  }

  if (chosenUser == null && whoamiUser.value) {
    chosenUser = {
      value: whoamiUser.value,
      source: DETECTED_USERNAME_SOURCES.whoamiCommand,
      suspicious: true,
    };
  }

  if (chosenUser == null && envUser.value) {
    chosenUser = {
      value: envUser.value,
      source: DETECTED_USERNAME_SOURCES.envUser,
      suspicious: true,
    };
  }

  if (chosenUser == null) {
    throw new Error("Failed to detect the current username.");
  }

  if (
    distinctObservedValues.size > 1 ||
    idUser.discardedSuspiciousValue ||
    whoamiUser.discardedSuspiciousValue ||
    envUser.discardedSuspiciousValue
  ) {
    return {
      ...chosenUser,
      suspicious: true,
    };
  }

  return chosenUser;
}

async function detectHostCandidates({
  env,
  execFileImpl,
  hostname,
  platform,
}: {
  readonly env: Environment;
  readonly execFileImpl: ExecFileLike;
  readonly hostname?: string | undefined;
  readonly platform: SupportedPlatform;
}): Promise<HostCandidate[]> {
  const candidates: UnrankedHostCandidate[] = [];

  addCandidate(candidates, hostname, HOST_CANDIDATE_SOURCES.osHostname);
  addCandidate(candidates, env.HOSTNAME, HOST_CANDIDATE_SOURCES.envHostname);

  for (const hostnameCommand of hostnameCommands(platform)) {
    try {
      const { stdout } = await execFileImpl(
        hostnameCommand.command,
        hostnameCommand.args
      );
      addCandidate(candidates, stdout, hostnameCommand.source);
    } catch {
      continue;
    }
  }

  return rankHostCandidates(candidates);
}

function hostnameCommands(platform: SupportedPlatform): readonly HostnameCommand[] {
  if (platform === SUPPORTED_PLATFORMS.macos) {
    return [
      {
        command: "scutil",
        args: ["--get", "HostName"],
        source: HOST_CANDIDATE_SOURCES.scutilHostname,
      },
      {
        command: "scutil",
        args: ["--get", "LocalHostName"],
        source: HOST_CANDIDATE_SOURCES.scutilLocalhostname,
      },
      {
        command: "hostname",
        args: ["-f"],
        source: HOST_CANDIDATE_SOURCES.hostnameFQDN,
      },
      {
        command: "hostname",
        args: [],
        source: HOST_CANDIDATE_SOURCES.hostname,
      },
    ];
  }

  return [
    {
      command: "hostname",
      args: ["-f"],
      source: HOST_CANDIDATE_SOURCES.hostnameFQDN,
    },
    {
      command: "hostname",
      args: [],
      source: HOST_CANDIDATE_SOURCES.hostname,
    },
  ];
}

function addCandidate(
  candidates: UnrankedHostCandidate[],
  value: string | undefined,
  source: HostCandidateSource
): void {
  const normalized = normalizeHostnameCandidate(value);
  if (!normalized) {
    return;
  }

  candidates.push({
    value: normalized,
    source,
  });
}

function normalizeHostnameCandidate(value: string | undefined): string | null {
  const normalized = value?.trim();
  return normalized || null;
}

function normalizeUsernameCandidate(
  value: string | undefined
): NormalizedUsernameCandidate {
  const normalized = value?.trim();
  if (!normalized) {
    return {
      discardedSuspiciousValue: false,
      value: null,
    };
  }

  if (suspiciousEnvUsernames.has(normalized.toLowerCase())) {
    return {
      discardedSuspiciousValue: true,
      value: null,
    };
  }

  return {
    discardedSuspiciousValue: false,
    value: normalized,
  };
}

function detectHostEnvironmentFlags(
  env: Environment,
  platform: SupportedPlatform
): HostEnvironmentFlag[] {
  const flags: HostEnvironmentFlag[] = [];

  if (
    platform === SUPPORTED_PLATFORMS.linux &&
    (typeof env.WSL_DISTRO_NAME === "string" ||
      typeof env.WSL_INTEROP === "string")
  ) {
    flags.push(HOST_ENVIRONMENT_FLAGS.wsl);
  }

  if (typeof env.CONTAINER === "string" || typeof env.container === "string") {
    flags.push(HOST_ENVIRONMENT_FLAGS.container);
  }

  return flags;
}

async function detectUid(
  execFileImpl: ExecFileLike
): Promise<string | null> {
  try {
    const { stdout } = await execFileImpl("id", ["-u"]);
    const normalized = stdout.trim();
    return normalized || null;
  } catch {
    return null;
  }
}

async function lookupUsernameByUid({
  execFileImpl,
  platform,
  uid,
}: {
  readonly execFileImpl: ExecFileLike;
  readonly platform: SupportedPlatform;
  readonly uid: string;
}): Promise<string | null> {
  try {
    if (platform === SUPPORTED_PLATFORMS.linux) {
      const { stdout } = await execFileImpl("getent", ["passwd", uid]);
      return parseAccountLookupUsername(stdout);
    }

    const { stdout } = await execFileImpl("dscl", [
      ".",
      "-search",
      "/Users",
      "UniqueID",
      uid,
    ]);
    return parseAccountLookupUsername(stdout);
  } catch {
    return null;
  }
}

function parseAccountLookupUsername(stdout: string): string | null {
  const firstLine = stdout
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  if (!firstLine) {
    return null;
  }

  if (firstLine.includes(":")) {
    const [username] = firstLine.split(":", 1);
    return username?.trim() || null;
  }

  const [username] = firstLine.split(/\s+/u, 1);
  return username?.trim() || null;
}

async function runUsernameCommand(
  execFileImpl: ExecFileLike,
  command: string,
  args: readonly string[]
): Promise<NormalizedUsernameCandidate> {
  try {
    const { stdout } = await execFileImpl(command, args);
    return normalizeUsernameCandidate(stdout);
  } catch {
    return {
      discardedSuspiciousValue: false,
      value: null,
    };
  }
}

function classifyHostCandidate(
  candidate: {
    readonly source: HostCandidateSource | null;
    readonly value: string;
  },
  shortTailscaleHostnames: ReadonlySet<string>
): HostCandidateKind {
  const lowerValue = candidate.value.toLowerCase();
  const source = candidate.source;

  if (
    source === HOST_CANDIDATE_SOURCES.tailscaleShort ||
    shortTailscaleHostnames.has(lowerValue)
  ) {
    return HOST_CANDIDATE_KINDS.tailscaleShort;
  }

  if (
    source === HOST_CANDIDATE_SOURCES.tailscaleMagicDNS ||
    isTailscaleMagicDNSHostname(candidate.value)
  ) {
    return HOST_CANDIDATE_KINDS.tailscaleFQDN;
  }

  if (isLocalDomainHostname(lowerValue)) {
    return HOST_CANDIDATE_KINDS.localDomain;
  }

  if (isFQDN(candidate.value)) {
    return HOST_CANDIDATE_KINDS.fqdn;
  }

  return HOST_CANDIDATE_KINDS.singleLabel;
}
