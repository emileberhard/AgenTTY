#!/usr/bin/env node

import { runCli } from "../dist/cli.js";

const exitCode = await runCli(process.argv.slice(2), {
  stdin: process.stdin,
  stdout: process.stdout,
  stderr: process.stderr,
});

process.exitCode = exitCode;
