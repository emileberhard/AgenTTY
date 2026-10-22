import type { CommandIO } from "../lib/types.js";

export async function runDoctorCommand(
  _args: readonly string[],
  io: CommandIO
): Promise<number> {
  io.stdout.write("AgenTTY Host doctor is not implemented yet.\n");
  return 0;
}
