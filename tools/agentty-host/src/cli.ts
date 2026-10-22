import { runDoctorCommand } from "./commands/doctor.js";
import { runPairCommand } from "./commands/pair.js";
import { runRepairCommand } from "./commands/repair.js";
import { runUnpairCommand } from "./commands/unpair.js";
import type { CommandIO } from "./lib/types.js";
import { BUILD_GIT_SHA, BUILD_VERSION, PACKAGE_NAME } from "./lib/types.js";

type Command = (args: readonly string[], io: CommandIO) => Promise<number>;

const commands = new Map<string, Command>([
  ["pair", runPairCommand],
  ["doctor", runDoctorCommand],
  ["repair", runRepairCommand],
  ["unpair", runUnpairCommand],
]);

export async function runCli(args: readonly string[], io: CommandIO): Promise<number> {
  const [commandName, ...rest] = args;

  if (!commandName) {
    return runPairCommand([], io);
  }

  if (isPairModeArgument(commandName)) {
    return runPairCommand(args, io);
  }

  if (isHelpArgument(commandName)) {
    writeHelp(io.stdout);
    return 0;
  }

  if (isVersionArgument(commandName)) {
    const suffix = BUILD_VERSION === BUILD_GIT_SHA ? "" : ` (${BUILD_GIT_SHA})`;
    io.stdout.write(`${PACKAGE_NAME} ${BUILD_VERSION}${suffix}\n`);
    return 0;
  }

  const command = commands.get(commandName);
  if (!command) {
    io.stderr.write(`Unknown command: ${commandName}\n\n`);
    writeHelp(io.stderr);
    return 1;
  }

  return command(rest, io);
}

function isHelpArgument(argument: string): boolean {
  return argument === "help" || argument === "--help" || argument === "-h";
}

function isVersionArgument(argument: string): boolean {
  return argument === "--version" || argument === "-v";
}

function isPairModeArgument(argument: string): boolean {
  return argument === "--direct-only" || argument === "--recommended";
}

function writeHelp(stream: CommandIO["stdout"]): void {
  stream.write(
    [
      "Usage: agentty-pair [command] [options]",
      "Usage: npx -y @agentty-app/pair [--recommended|--direct-only]",
      "",
      "Commands:",
      "  pair     Start the host pairing flow",
      "  doctor   Run host diagnostics",
      "  repair   Repair a broken host setup",
      "  unpair   Remove AgenTTY host pairing",
      "",
      "Pairing options:",
      "  --recommended  Explicitly use Full AgenTTY Setup with relay fallback",
      "  --direct-only  Skip the persistent relay connector and use direct SSH only",
      "",
      "Examples:",
      "  npx -y @agentty-app/pair",
      "  npx -y @agentty-app/pair --direct-only",
      "  npx -y @agentty-app/pair doctor",
      "",
    ].join("\n")
  );
}
