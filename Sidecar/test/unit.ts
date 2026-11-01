import { spawnSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sidecar = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const files = ["test/unit", "test/private/unit"].flatMap((folder) =>
  existsSync(path.join(sidecar, folder))
    ? readdirSync(path.join(sidecar, folder))
        .filter((name) => name.endsWith(".test.ts"))
        .sort()
        .map((name) => path.join(folder, name))
    : [],
);

const run = spawnSync(
  process.execPath,
  ["--test", ...process.argv.slice(2), ...files, "test/exit-policy-test.ts"],
  { cwd: sidecar, stdio: "inherit" },
);
process.exit(run.status ?? 1);
