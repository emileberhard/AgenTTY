import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { BUILD_GIT_TAG, type CommandIO, type PairingMetadata } from "./types.js";

const DEFAULT_HOST_RUNTIME_ASSET_BASE_URL =
  "https://agentty-assets.esmadil.se/host-runtime";
const HOST_RUNTIME_ASSET_BASE_URL_ENVIRONMENT_KEY =
  "AGENTTY_HOST_RUNTIME_ASSET_BASE_URL";
const CONNECTOR_CONTROL_PROBE_TIMEOUT_MILLISECONDS = 15_000;
const SERVICE_RELOAD_COMMAND_TIMEOUT_MILLISECONDS = 15_000;

interface ConnectorBinaryDescriptor {
  readonly sha256: string;
  readonly url: string;
}

interface HostRuntimeManifestTarget {
  readonly agentty_host_connector?: ConnectorBinaryDescriptor;
}

interface HostRuntimeManifest {
  readonly runtime_version: string;
  readonly targets: Record<string, HostRuntimeManifestTarget>;
}

interface ConnectorRegisterResponse {
  readonly connector_id: string;
  readonly connector_secret: string;
  readonly relay_host_id: string;
}

interface ConnectorRegisterRequestBody {
  readonly bootstrap_token: string;
  readonly existing_connector_id?: string;
  readonly existing_connector_secret?: string;
  readonly machine_id: string;
  readonly platform: PairingMetadata["platform"];
  readonly port: number;
  readonly ssh_username: string;
}

export interface RelayConnectorProvisionRequest {
  readonly baseUrl: URL;
  readonly bootstrapToken: string;
  readonly homeDirectory?: string | undefined;
  readonly io: CommandIO;
  readonly metadata: PairingMetadata;
  readonly platform?: NodeJS.Platform;
}

export interface RelayConnectorProvisionResult {
  readonly relayHostId: string;
}

export async function provisionRelayConnector(
  request: RelayConnectorProvisionRequest
): Promise<RelayConnectorProvisionResult> {
  const homeDirectory = request.homeDirectory ?? os.homedir();
  if (!homeDirectory) {
    throw new Error("Unable to resolve the current home directory.");
  }

  const relayMachineID = await loadOrCreateRelayMachineID(homeDirectory);
  const connectorConfigPath = path.join(homeDirectory, ".agentty", "config", "host-connector.json");
  let existingConnector: { connector_id: string; connector_secret: string } | undefined;
  try {
    const config = JSON.parse(await fs.readFile(connectorConfigPath, "utf8"));
    if (typeof config.connector_id !== "string" || typeof config.connector_secret !== "string"
        || typeof config.public_base_url !== "string") {
      throw new Error("Existing connector configuration is invalid.");
    }
    if (new URL(config.public_base_url).origin === request.baseUrl.origin) {
      existingConnector = config;
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw new Error("Unable to read the existing relay connector configuration.");
    }
  }
  const connectorRegistration = await registerConnector({
    existingConnector,
    baseUrl: request.baseUrl,
    bootstrapToken: request.bootstrapToken,
    machineID: relayMachineID,
    metadata: request.metadata,
  });
  const connectorBinary = await downloadConnectorBinary({
    homeDirectory,
    metadata: request.metadata,
    platform: request.platform ?? process.platform,
  });

  const connectorBinaryPath = path.join(
    homeDirectory,
    ".agentty",
    "libexec",
    "agentty-host-connector"
  );
  const logDirectory = path.join(homeDirectory, ".agentty", "logs");

  await fs.mkdir(path.dirname(connectorBinaryPath), { recursive: true });
  await fs.mkdir(path.dirname(connectorConfigPath), { recursive: true });
  await fs.mkdir(path.join(homeDirectory, ".agentty", "state"), { recursive: true });
  await fs.mkdir(logDirectory, { recursive: true });

  await fs.writeFile(connectorBinaryPath, connectorBinary);
  await fs.chmod(connectorBinaryPath, 0o700);

  const connectorConfig = {
    connector_id: connectorRegistration.connector_id,
    connector_secret: connectorRegistration.connector_secret,
    public_base_url: request.baseUrl.origin,
    relay_host_id: connectorRegistration.relay_host_id,
    ssh_port: request.metadata.port,
  };
  await fs.writeFile(
    connectorConfigPath,
    JSON.stringify(connectorConfig, null, 2) + "\n",
    { mode: 0o600 }
  );
  await fs.chmod(connectorConfigPath, 0o600);

  await installPersistentService({
    connectorBinaryPath,
    connectorConfigPath,
    homeDirectory,
    logDirectory,
    platform: request.platform ?? process.platform,
    username: request.metadata.detectedUsername,
  });
  await verifyConnectorControlConnection({
    connectorBinaryPath,
    connectorConfigPath,
  });

  request.io.stdout.write(
    [
      "Installed AgenTTY relay connector service.",
      `Relay host ID: ${connectorRegistration.relay_host_id}`,
    ].join("\n") + "\n"
  );

  return {
    relayHostId: connectorRegistration.relay_host_id,
  };
}

async function loadOrCreateRelayMachineID(homeDirectory: string): Promise<string> {
  const machineIDPath = path.join(
    homeDirectory,
    ".agentty",
    "state",
    "relay-machine-id"
  );
  try {
    const existing = (await fs.readFile(machineIDPath, "utf8")).trim();
    if (existing) {
      return existing;
    }
  } catch {}

  await fs.mkdir(path.dirname(machineIDPath), { recursive: true });
  const created = randomUUID().toLowerCase();
  await fs.writeFile(machineIDPath, created + "\n", { mode: 0o600 });
  await fs.chmod(machineIDPath, 0o600);
  return created;
}

async function registerConnector({
  existingConnector,
  baseUrl,
  bootstrapToken,
  machineID,
  metadata,
}: {
  readonly baseUrl: URL;
  readonly bootstrapToken: string;
  readonly machineID: string;
  readonly metadata: PairingMetadata;
  readonly existingConnector: { connector_id: string; connector_secret: string } | undefined;
}): Promise<ConnectorRegisterResponse> {
  const response = await fetch(new URL("/v1/connectors/register", baseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      bootstrap_token: bootstrapToken,
      ...(existingConnector ? {
        existing_connector_id: existingConnector.connector_id,
        existing_connector_secret: existingConnector.connector_secret,
      } : {}),
      machine_id: machineID,
      ssh_username: metadata.detectedUsername,
      platform: metadata.platform,
      port: metadata.port,
    } satisfies ConnectorRegisterRequestBody),
  });

  if (!response.ok) {
    const error = await parseRelayError(response);
    throw new Error(error ?? "Failed to register the AgenTTY relay connector.");
  }

  const payload = (await response.json()) as Partial<ConnectorRegisterResponse>;
  if (
    !payload.connector_id ||
    !payload.connector_secret ||
    !payload.relay_host_id
  ) {
    throw new Error("Relay connector registration returned an invalid payload.");
  }
  return payload as ConnectorRegisterResponse;
}

async function downloadConnectorBinary({
  homeDirectory,
  metadata,
  platform,
}: {
  readonly homeDirectory: string;
  readonly metadata: PairingMetadata;
  readonly platform: NodeJS.Platform;
}): Promise<Buffer> {
  const targetKey = hostRuntimeTargetKey(metadata.platform, platform, process.arch);
  const manifestUrl = resolveHostRuntimeManifestUrl();
  const manifestResponse = await fetch(manifestUrl);
  if (!manifestResponse.ok) {
    throw new Error(
      `Failed to fetch host runtime manifest (${manifestResponse.status}).`
    );
  }
  const manifest = (await manifestResponse.json()) as HostRuntimeManifest;
  if (BUILD_GIT_TAG && manifest.runtime_version !== BUILD_GIT_TAG) {
    throw new Error(`Host runtime version must match pairing package ${BUILD_GIT_TAG}.`);
  }
  const target = manifest.targets?.[targetKey];
  const descriptor = target?.agentty_host_connector;
  if (!descriptor) {
    throw new Error(
      `Host runtime manifest does not contain an AgenTTY relay connector for ${targetKey}.`
    );
  }

  const binaryResponse = await fetch(descriptor.url);
  if (!binaryResponse.ok) {
    throw new Error(
      `Failed to fetch the AgenTTY relay connector binary (${binaryResponse.status}).`
    );
  }
  const binaryData = Buffer.from(await binaryResponse.arrayBuffer());
  const actualSHA256 = createHash("sha256").update(binaryData).digest("hex");
  if (actualSHA256 !== descriptor.sha256) {
    throw new Error("Relay connector checksum mismatch.");
  }

  const cachePath = path.join(
    homeDirectory,
    ".agentty",
    "state",
    `relay-connector-${manifest.runtime_version}-${targetKey}`
  );
  await fs.mkdir(path.dirname(cachePath), { recursive: true });
  await fs.writeFile(cachePath, binaryData);
  await fs.chmod(cachePath, 0o700);

  return binaryData;
}

function resolveHostRuntimeManifestUrl(): URL {
  const override = process.env[HOST_RUNTIME_ASSET_BASE_URL_ENVIRONMENT_KEY]?.trim();
  if (override) {
    return new URL("latest.json", override.endsWith("/") ? override : `${override}/`);
  }
  if (BUILD_GIT_TAG) {
    return new URL(`https://github.com/emileberhard/AgenTTY/releases/download/${BUILD_GIT_TAG}/host-runtime-manifest.json`);
  }
  return new URL(`${DEFAULT_HOST_RUNTIME_ASSET_BASE_URL}/latest.json`);
}

function hostRuntimeTargetKey(
  metadataPlatform: PairingMetadata["platform"],
  processPlatform: NodeJS.Platform,
  processArchitecture: string
): string {
  const normalizedPlatform =
    metadataPlatform === "macos"
      ? "darwin"
      : metadataPlatform === "linux"
        ? "linux"
        : normalizeProcessPlatform(processPlatform);
  const normalizedArchitecture =
    processArchitecture === "arm64"
      ? "arm64"
      : processArchitecture === "x64"
        ? "x86_64"
        : processArchitecture;

  switch (`${normalizedPlatform}-${normalizedArchitecture}`) {
    case "darwin-arm64":
    case "darwin-x86_64":
    case "linux-arm64":
    case "linux-x86_64":
      return `${normalizedPlatform}-${normalizedArchitecture}`;
    default:
      throw new Error(
        `Unsupported host runtime target ${normalizedPlatform}-${normalizedArchitecture}.`
      );
  }
}

function normalizeProcessPlatform(platform: NodeJS.Platform): string {
  switch (platform) {
    case "darwin":
      return "darwin";
    case "linux":
      return "linux";
    default:
      throw new Error(`Unsupported platform ${platform}.`);
  }
}

async function installPersistentService({
  connectorBinaryPath,
  connectorConfigPath,
  homeDirectory,
  logDirectory,
  platform,
  username,
}: {
  readonly connectorBinaryPath: string;
  readonly connectorConfigPath: string;
  readonly homeDirectory: string;
  readonly logDirectory: string;
  readonly platform: NodeJS.Platform;
  readonly username: string;
}): Promise<void> {
  switch (platform) {
    case "darwin":
      await installLaunchDaemon({
        connectorBinaryPath,
        connectorConfigPath,
        logDirectory,
        username,
      });
      return;
    case "linux":
      await installSystemdService({
        connectorBinaryPath,
        connectorConfigPath,
        homeDirectory,
        username,
      });
      return;
    default:
      throw new Error(`Unsupported platform ${platform}.`);
  }
}

async function verifyConnectorControlConnection({
  connectorBinaryPath,
  connectorConfigPath,
}: {
  readonly connectorBinaryPath: string;
  readonly connectorConfigPath: string;
}): Promise<void> {
  try {
    await runCapturedCommand(
      connectorBinaryPath,
      ["probe-control", "--config", connectorConfigPath],
      CONNECTOR_CONTROL_PROBE_TIMEOUT_MILLISECONDS
    );
  } catch (error) {
    throw new Error(
      [
        "Installed the AgenTTY relay connector, but its control connection probe failed.",
        error instanceof Error ? error.message : String(error),
      ].join("\n")
    );
  }
}

async function installLaunchDaemon({
  connectorBinaryPath,
  connectorConfigPath,
  logDirectory,
  username,
}: {
  readonly connectorBinaryPath: string;
  readonly connectorConfigPath: string;
  readonly logDirectory: string;
  readonly username: string;
}): Promise<void> {
  const label = serviceLabel(username);
  const launchDaemonPath = `/Library/LaunchDaemons/${label}.plist`;
  const tempDirectory = await fs.mkdtemp(
    path.join(os.tmpdir(), "agentty-host-connector-")
  );
  const tempPlistPath = path.join(tempDirectory, `${label}.plist`);
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${connectorBinaryPath}</string>
    <string>--config</string>
    <string>${connectorConfigPath}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>UserName</key>
  <string>${username}</string>
  <key>StandardOutPath</key>
  <string>${path.join(logDirectory, "host-connector.stdout.log")}</string>
  <key>StandardErrorPath</key>
  <string>${path.join(logDirectory, "host-connector.stderr.log")}</string>
</dict>
</plist>
`;
  await fs.writeFile(tempPlistPath, plist, "utf8");

  try {
    await runInteractiveCommand("sudo", [
      "install",
      "-m",
      "644",
      tempPlistPath,
      launchDaemonPath,
    ]);
    // bootout is just cleanup for a prior install; later bootstrap/kickstart/probe
    // decide whether the reinstall actually worked, so keep this step quiet.
    await runBestEffortCapturedCommand("sudo", [
      "launchctl",
      "bootout",
      "system",
      launchDaemonPath,
    ]);
    await runInteractiveCommand("sudo", [
      "launchctl",
      "bootstrap",
      "system",
      launchDaemonPath,
    ]);
    await runInteractiveCommand("sudo", [
      "launchctl",
      "kickstart",
      "-k",
      `system/${label}`,
    ]);
  } finally {
    await fs.rm(tempDirectory, { recursive: true, force: true });
  }
}

async function installSystemdService({
  connectorBinaryPath,
  connectorConfigPath,
  homeDirectory,
  username,
}: {
  readonly connectorBinaryPath: string;
  readonly connectorConfigPath: string;
  readonly homeDirectory: string;
  readonly username: string;
}): Promise<void> {
  const label = serviceLabel(username);
  const serviceName = `${label}.service`;
  const servicePath = `/etc/systemd/system/${serviceName}`;
  const tempDirectory = await fs.mkdtemp(
    path.join(os.tmpdir(), "agentty-host-connector-")
  );
  const tempServicePath = path.join(tempDirectory, serviceName);
  const service = `[Unit]
Description=AgenTTY host connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${username}
ExecStart=${connectorBinaryPath} --config ${connectorConfigPath}
Restart=always
RestartSec=2
WorkingDirectory=${homeDirectory}

[Install]
WantedBy=multi-user.target
`;
  await fs.writeFile(tempServicePath, service, "utf8");

  try {
    await runInteractiveCommand("sudo", [
      "install",
      "-m",
      "644",
      tempServicePath,
      servicePath,
    ]);
    await runInteractiveCommand("sudo", ["systemctl", "daemon-reload"]);
    await runInteractiveCommand("sudo", [
      "systemctl",
      "enable",
      "--now",
      serviceName,
    ]);
  } finally {
    await fs.rm(tempDirectory, { recursive: true, force: true });
  }
}

function serviceLabel(username: string): string {
  const sanitizedUsername = username.replace(/[^a-z0-9]+/giu, "-").toLowerCase();
  return `se.esmadil.agentty-host-connector.${sanitizedUsername}`;
}

async function runBestEffortCapturedCommand(
  command: string,
  args: readonly string[]
): Promise<void> {
  try {
    await runCapturedCommand(
      command,
      args,
      SERVICE_RELOAD_COMMAND_TIMEOUT_MILLISECONDS
    );
  } catch {}
}

async function runInteractiveCommand(
  command: string,
  args: readonly string[]
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(
        new Error(
          `${command} ${args.join(" ")} exited with status ${code ?? "unknown"}.`
        )
      );
    });
  });
}

async function runCapturedCommand(
  command: string,
  args: readonly string[],
  timeoutMilliseconds: number
): Promise<{ readonly stderr: string; readonly stdout: string }> {
  return await new Promise<{ readonly stderr: string; readonly stdout: string }>((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMilliseconds);

    child.stdout?.on("data", (chunk: Buffer) => {
      stdoutChunks.push(chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderrChunks.push(chunk);
    });

    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("exit", (code, signal) => {
      clearTimeout(timeout);
      const stdout = Buffer.concat(stdoutChunks).toString("utf8").trim();
      const stderr = Buffer.concat(stderrChunks).toString("utf8").trim();
      if (timedOut) {
        reject(
          new Error(
            `${command} ${args.join(" ")} timed out after ${timeoutMilliseconds}ms.`
          )
        );
        return;
      }
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      reject(
        new Error(
          [
            `${command} ${args.join(" ")} exited with status ${code ?? "unknown"}${signal ? ` signal=${signal}` : ""}.`,
            stdout ? `stdout:\n${stdout}` : "",
            stderr ? `stderr:\n${stderr}` : "",
          ]
            .filter(Boolean)
            .join("\n")
        )
      );
    });
  });
}

async function parseRelayError(response: Response): Promise<string | null> {
  try {
    const payload = (await response.json()) as {
      readonly detail?: string;
      readonly error?: string;
      readonly message?: string;
    };
    return payload.detail ?? payload.error ?? payload.message ?? null;
  } catch {
    return null;
  }
}
