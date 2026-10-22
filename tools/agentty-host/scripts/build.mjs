import { execFileSync } from "node:child_process";
import { chmod, copyFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "../../..");
const metadataScriptPath = path.join(repoRoot, "scripts/resolve-build-metadata");

const buildMetadata = resolveBuildMetadata();

await build({
  bundle: true,
  charset: "ascii",
  define: {
    "process.env.AGENTTY_BUILD_VERSION": JSON.stringify(buildMetadata.version),
    "process.env.AGENTTY_GIT_SHA": JSON.stringify(buildMetadata.gitSha),
    "process.env.AGENTTY_GIT_TAG": JSON.stringify(buildMetadata.gitTag),
  },
  entryPoints: ["src/cli.ts"],
  format: "esm",
  legalComments: "none",
  minify: true,
  outfile: "dist/cli.js",
  platform: "node",
  target: "node18",
  treeShaking: true,
});

await chmod("dist/cli.js", 0o755);
await copyFile(path.join(repoRoot, "LICENSE"), "LICENSE");
await copyFile(path.join(repoRoot, "THIRD-PARTY-NOTICES.txt"), "THIRD-PARTY-NOTICES.txt");

function resolveBuildMetadata() {
  const rawOutput = execFileSync(metadataScriptPath, [], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  const metadata = new Map();

  for (const line of rawOutput.trim().split("\n")) {
    const [key, value = ""] = line.split("=", 2);
    metadata.set(key, value);
  }

  const version = metadata.get("version");
  const gitSha = metadata.get("git_sha");
  const gitTag = metadata.get("git_tag") ?? "";
  if (!version || !gitSha) {
    throw new Error("resolve-build-metadata did not return version and git_sha");
  }

  return {
    version,
    gitSha,
    gitTag,
  };
}
