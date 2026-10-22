import type { CommandIO } from "../lib/types.js";

export async function runUnpairCommand(
  _args: readonly string[],
  io: CommandIO
): Promise<number> {
  io.stdout.write("AgenTTY Host unpair is not implemented yet.\n");
  return 0;
}
