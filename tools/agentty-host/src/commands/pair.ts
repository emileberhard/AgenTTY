import { createInterface } from "node:readline/promises";
import qrcode from "qrcode-terminal";
import { installAuthorizedKey } from "../lib/authorized-keys.js";
import { resolveBaseUrl } from "../lib/config.js";
import { detectHostMetadata, rankHostCandidates } from "../lib/host-metadata.js";
import {
  completePairingSession,
  createPairingSession,
  fetchHostPairingSessionStatus,
} from "../lib/pairing-api.js";
import {
  provisionRelayConnector,
  type RelayConnectorProvisionRequest,
  type RelayConnectorProvisionResult,
} from "../lib/relay-connector.js";
import { collectLocalSSHHostPublicKeys } from "../lib/ssh-host-keys.js";
import { detectTailscale } from "../lib/tailscale.js";
import {
  HOST_CANDIDATE_SOURCES,
  PAIRING_SESSION_STATES,
  type CommandIO,
  type Environment,
  type ExecFileLike,
  type FetchLike,
  type FileSystemLike,
  type PairingMetadata,
  type TailscalePrompt,
  type TailscaleStatus,
} from "../lib/types.js";

const SETUP_MODES = {
  directOnly: "directOnly",
  recommended: "recommended",
} as const;

type SetupMode = (typeof SETUP_MODES)[keyof typeof SETUP_MODES];

type SetupModePrompt = (options: {
  readonly io: CommandIO;
}) => Promise<SetupMode | null>;

interface PairCommandDependencies {
  readonly connectorProvisioner?:
    | ((
        request: RelayConnectorProvisionRequest
      ) => Promise<RelayConnectorProvisionResult>)
    | undefined;
  readonly env?: Environment;
  readonly execFileImpl?: ExecFileLike | undefined;
  readonly fetchImpl?: FetchLike | undefined;
  readonly fsImpl?: FileSystemLike | undefined;
  readonly homeDirectory?: string | undefined;
  readonly hostname?: string | undefined;
  readonly platform?: NodeJS.Platform;
  readonly promptImpl?: TailscalePrompt | undefined;
  readonly qrRenderer?: typeof renderQrCode | undefined;
  readonly setupModePromptImpl?: SetupModePrompt | undefined;
  readonly sleepImpl?: typeof sleep | undefined;
}

interface FinalizeFailedPairingContext {
  readonly baseUrl: URL;
  readonly hostToken: string;
  readonly metadata?: PairingMetadata | undefined;
  readonly sessionId: string;
}

export async function runPairCommand(
  args: readonly string[],
  io: CommandIO,
  dependencies: PairCommandDependencies = {}
): Promise<number> {
  const {
    connectorProvisioner = provisionRelayConnector,
    fetchImpl = fetch as FetchLike,
    promptImpl = promptForTailscalePreference,
    qrRenderer = renderQrCode,
    setupModePromptImpl = promptForSetupMode,
    sleepImpl = sleep,
  } = dependencies;

  try {
    const explicitSetupMode = parsePairArgs(args);

    const baseUrl = resolveBaseUrl(dependencies.env ?? process.env);
    const hostMetadataPromise = detectHostMetadata({
      env: dependencies.env ?? process.env,
      execFileImpl: dependencies.execFileImpl,
      hostname: dependencies.hostname,
      platform: dependencies.platform ?? process.platform,
    });
    hostMetadataPromise.catch(() => {});

    const tailscalePromise = detectTailscale({
      execFileImpl: dependencies.execFileImpl,
    });
    tailscalePromise.catch(() => {});

    io.stdout.write(`Creating pairing session via ${baseUrl.origin}...\n`);
    const session = await createPairingSession(
      {
        baseUrl,
      },
      { fetchImpl }
    );

    io.stdout.write("\nScan this QR code with AgenTTY:\n\n");
    await qrRenderer(session.qrPayload, io.stdout);
    io.stdout.write(`\nManual code: ${session.pairingCode}\n`);
    io.stdout.write("Waiting for AgenTTY to claim this host...\n");

    await sleepImpl(1000);
    while (true) {
      const status = await fetchHostPairingSessionStatus(
        {
          baseUrl,
          hostToken: session.hostToken,
          sessionId: session.sessionId,
        },
        { fetchImpl }
      );

      switch (status.status) {
        case PAIRING_SESSION_STATES.pending:
          await sleepImpl(1000);
          continue;
        case PAIRING_SESSION_STATES.claimed: {
          if (!status.publicKey) {
            throw new Error("Pairing session was claimed without a public key.");
          }

          let pairingMetadata: PairingMetadata | undefined;
          try {
            const setupMode = await resolveSetupMode({
              explicitSetupMode,
              io,
              promptImpl: setupModePromptImpl,
            });
            if (!setupMode) {
              throw new Error("Pairing cancelled before changing this host.");
            }

            const pairingMetadataPromise = resolvePairingMetadata({
              io,
              metadata: await hostMetadataPromise,
              promptImpl,
              tailscale: await tailscalePromise,
            });
            const hostPublicKeysPromise = hostMetadataPromise.then((resolvedMetadata) =>
              collectLocalSSHHostPublicKeys(
                resolvedMetadata.port,
                dependencies.execFileImpl
              )
            );

            pairingMetadata = await pairingMetadataPromise;
            pairingMetadata = {
              ...pairingMetadata,
              sshHostPublicKeys: await hostPublicKeysPromise,
            };
            const installResult = await installAuthorizedKey(status.publicKey, {
              fsImpl: dependencies.fsImpl,
              homeDirectory: dependencies.homeDirectory,
            });

            io.stdout.write(
              installResult.alreadyPresent
                ? "Public key was already authorized for this user.\n"
                : "Authorized the AgenTTY public key for this user.\n"
            );

            if (setupMode === SETUP_MODES.recommended && status.connectorBootstrap) {
              try {
                const relayConnector = await connectorProvisioner({
                  baseUrl,
                  bootstrapToken: status.connectorBootstrap.token,
                  homeDirectory: dependencies.homeDirectory,
                  io,
                  metadata: pairingMetadata,
                  platform: dependencies.platform ?? process.platform,
                });
                pairingMetadata = {
                  ...pairingMetadata,
                  relayCapable: true,
                  relayHostId: relayConnector.relayHostId,
                };
              } catch (error) {
                pairingMetadata = {
                  ...pairingMetadata,
                  relayCapable: false,
                };
                io.stdout.write(
                  [
                    "Remote relay access is unavailable for now. Direct SSH pairing still succeeded.",
                    error instanceof Error ? error.message : String(error),
                  ].join("\n") + "\n"
                );
              }
            } else {
              pairingMetadata = {
                ...pairingMetadata,
                relayCapable: false,
              };
              if (setupMode === SETUP_MODES.directOnly) {
                io.stdout.write(
                  "Direct Connection Only selected. Skipping the persistent relay connector.\n"
                );
              }
            }

            await completePairingSession(
              {
                baseUrl,
                hostToken: session.hostToken,
                metadata: pairingMetadata,
                sessionId: session.sessionId,
              },
              { fetchImpl }
            );

            io.stdout.write(
              [
                "Pairing complete.",
                `Detected user: ${pairingMetadata.detectedUsername}`,
                `Hostname candidates: ${pairingMetadata.hostnameCandidates.join(", ") || "none"}`,
                `Platform: ${pairingMetadata.platform}`,
                pairingMetadata.relayCapable && pairingMetadata.relayHostId
                  ? `Relay host ID: ${pairingMetadata.relayHostId}`
                  : "Relay access: direct SSH only",
              ].join("\n") + "\n"
            );
            return 0;
          } catch (error) {
            await finalizeFailedPairing(
              {
                baseUrl,
                hostToken: session.hostToken,
                metadata: pairingMetadata,
                sessionId: session.sessionId,
              },
              fetchImpl,
              error instanceof Error ? error.message : String(error)
            );
            throw error;
          }
        }
        case PAIRING_SESSION_STATES.completed:
          throw new Error(
            "Pairing session completed before the host finished setup locally."
          );
        case PAIRING_SESSION_STATES.failed:
          throw new Error(status.completion?.errorMessage ?? "Pairing failed.");
        case PAIRING_SESSION_STATES.expired:
          throw new Error("Pairing code expired.");
      }
    }
  } catch (error) {
    io.stderr.write(
      `${error instanceof Error ? error.message : String(error)}\n`
    );
    return 1;
  }
}

function parsePairArgs(args: readonly string[]): SetupMode | null {
  let setupMode: SetupMode | null = null;

  for (const arg of args) {
    if (arg === "--direct-only") {
      if (setupMode) {
        throw new Error("Choose only one setup mode flag.");
      }
      setupMode = SETUP_MODES.directOnly;
      continue;
    }

    if (arg === "--recommended") {
      if (setupMode) {
        throw new Error("Choose only one setup mode flag.");
      }
      setupMode = SETUP_MODES.recommended;
      continue;
    }

    throw new Error(`@agentty-app/pair does not accept argument: ${arg}`);
  }

  return setupMode;
}

async function resolveSetupMode({
  explicitSetupMode,
  io,
  promptImpl,
}: {
  readonly explicitSetupMode: SetupMode | null;
  readonly io: CommandIO;
  readonly promptImpl: SetupModePrompt;
}): Promise<SetupMode | null> {
  if (explicitSetupMode) {
    return explicitSetupMode;
  }

  if (!io.stdin?.isTTY) {
    io.stdout.write(
      [
        "No interactive TTY is available for setup consent.",
        "Continuing with Direct Connection Only. The persistent relay connector was skipped.",
        "Run npx -y @agentty-app/pair --recommended from an interactive shell to enable fallback relay access.",
      ].join("\n") + "\n"
    );
    return SETUP_MODES.directOnly;
  }

  return promptImpl({ io });
}

async function finalizeFailedPairing(
  claimContext: FinalizeFailedPairingContext,
  fetchImpl: FetchLike,
  errorMessage: string
): Promise<void> {
  try {
    await completePairingSession(
      {
        baseUrl: claimContext.baseUrl,
        hostToken: claimContext.hostToken,
        metadata: {
          ...claimContext.metadata,
          errorMessage,
        },
        sessionId: claimContext.sessionId,
      },
      { fetchImpl }
    );
  } catch {
    return;
  }
}

function renderQrCode(
  payload: string,
  stream: CommandIO["stdout"]
): Promise<void> {
  return new Promise((resolve) => {
    qrcode.generate(payload, { small: true }, (output: string) => {
      stream.write(`${output}\n`);
      resolve();
    });
  });
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

async function resolvePairingMetadata({
  io,
  metadata,
  promptImpl,
  tailscale,
}: {
  readonly io: CommandIO;
  readonly metadata: Awaited<ReturnType<typeof detectHostMetadata>>;
  readonly promptImpl: TailscalePrompt;
  readonly tailscale: TailscaleStatus;
}): Promise<PairingMetadata> {
  const preferredTailscaleHostname = tailscale.shortHostname ?? tailscale.magicDNSName;

  if (!tailscale.installed) {
    return {
      ...metadata,
      sshHostPublicKeys: [],
      usesTailscale: false,
    };
  }

  if (!tailscale.magicDNSName || !preferredTailscaleHostname) {
    io.stdout.write(
      [
        "Tailscale is installed, but AgenTTY could not determine a usable MagicDNS hostname right now.",
        "Continuing with the host's normal hostname candidates.",
        "If you want to pair over Tailscale, connect this host to Tailscale and run the pair command again.",
      ].join("\n") + "\n"
    );
    return {
      ...metadata,
      sshHostPublicKeys: [],
      usesTailscale: false,
    };
  }

  const wantsTailscale = await promptImpl({
    io,
    preferredHostname: preferredTailscaleHostname,
  });
  if (!wantsTailscale) {
    return {
      ...metadata,
      sshHostPublicKeys: [],
      usesTailscale: false,
    };
  }

  io.stdout.write(
    [
      `Using Tailscale hostname: ${preferredTailscaleHostname}`,
      "Make sure Tailscale is installed and connected on the iPhone running AgenTTY, or the SSH connection will not work.",
    ].join("\n") + "\n"
  );

  const hostCandidates = rankHostCandidates([
    {
      value: preferredTailscaleHostname,
      source: HOST_CANDIDATE_SOURCES.tailscaleShort,
    },
    {
      value: tailscale.magicDNSName,
      source: HOST_CANDIDATE_SOURCES.tailscaleMagicDNS,
    },
    ...metadata.hostCandidates,
  ]);

  return {
    ...metadata,
    hostCandidates,
    hostnameCandidates: hostCandidates.map((candidate) => candidate.value),
    sshHostPublicKeys: [],
    usesTailscale: true,
  };
}

async function promptForTailscalePreference({
  io,
  preferredHostname,
}: {
  readonly io: CommandIO;
  readonly preferredHostname: string;
}): Promise<boolean> {
  const input = io.stdin;
  const output = io.stdout;

  if (!input?.isTTY) {
    output.write(
      "Tailscale is installed, but this session is not interactive. Continuing without Tailscale.\n"
    );
    return false;
  }

  const promptLines = [
    "Detected Tailscale on this host.",
    "AgenTTY works especially well over Tailscale because it gives your devices a simple, secure, and reliable way to reach this host.",
    `Detected Tailscale hostname: ${preferredHostname}`,
    "Use Tailscale for this pairing? [Y/n] ",
  ];

  const readline = createInterface({
    input,
    output,
  });

  try {
    const answer = await readline.question(promptLines.join("\n"));
    return !/^(n|no)$/iu.test(answer.trim());
  } finally {
    readline.close();
  }
}

async function promptForSetupMode({
  io,
}: {
  readonly io: CommandIO;
}): Promise<SetupMode | null> {
  const input = io.stdin;
  const output = io.stdout;

  if (!input?.isTTY) {
    return SETUP_MODES.directOnly;
  }

  const readline = createInterface({
    input,
    output,
  });

  try {
    const recommendedAnswer = await readline.question(
      [
        "Choose AgenTTY setup mode.",
        "",
        "Recommended: Full AgenTTY Setup",
        "Best AgenTTY experience. Adds one AgenTTY SSH public key for this user, uses ~/.agentty for managed tmux/runtime files, and adds a fallback relay connector when direct SSH is unavailable.",
        "SSH remains normal SSH; the relay does not receive your private key or terminate the SSH session.",
        "AgenTTY does not edit normal shell startup files outside its managed directory.",
        "",
        "Use Full AgenTTY Setup? [Y/n] ",
      ].join("\n")
    );
    if (!/^(n|no)$/iu.test(recommendedAnswer.trim())) {
      return SETUP_MODES.recommended;
    }

    const directOnlyAnswer = await readline.question(
      [
        "Use Direct Connection Only instead?",
        "This still adds the AgenTTY SSH public key and uses ~/.agentty for managed runtime files, but skips the persistent relay connector and relay fallback. [y/N] ",
      ].join("\n")
    );
    if (/^(y|yes)$/iu.test(directOnlyAnswer.trim())) {
      return SETUP_MODES.directOnly;
    }

    return null;
  } finally {
    readline.close();
  }
}
