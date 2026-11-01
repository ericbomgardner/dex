/**
 * Which settings level a model starts at with nothing picked — the rule
 * `HostDefaults.effort(forModel:)` copies for the effort picker's Default row.
 *
 *   node test/effort-default-probe.ts
 *
 * Asks the bundled CLI's `-p "/model"`, which prints `(effort: …)` beside the
 * model it would run, in a scratch config directory and a scratch project, so
 * it starts no session and needs no login. What it pins, against CLI v2.1.280:
 *   - a top-level `effortLevel` in the user's file reaches every model on
 *     `legacyModels` in DefaultEffort.swift
 *   - and not Opus 5.5, the default Opus — which is the whole reason the list
 *     exists, and the alarm for the day the CLI's own list moves
 *   - nor Haiku 5.5 (CLI v2.1.295), which the `haiku` alias now runs
 *   - a `modelSettings` entry beats its file's top-level level
 *   - a project's top-level level reaches Opus 5.5 too
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const packages = path.resolve(here, "../node_modules/@anthropic-ai");
const platform = readdirSync(packages).find((name) => name.startsWith("claude-agent-sdk-darwin-"));
const cli = platform ? path.join(packages, platform, "claude") : null;
if (!cli || !existsSync(cli)) {
  console.error(`FAIL: no bundled CLI under ${packages}`);
  process.exit(1);
}

const swift = readFileSync(
  path.resolve(here, "../../Sources/DexCore/Actions/DefaultEffort.swift"),
  "utf8",
);
const listed = /legacyModels = \[([^\]]*)\]/.exec(swift)?.[1];
const legacy = [...(listed ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1]);
if (legacy.length === 0) {
  console.error("FAIL: could not read legacyModels out of DefaultEffort.swift");
  process.exit(1);
}

const config = mkdtempSync(path.join(tmpdir(), "dex-effort-config-"));
const project = mkdtempSync(path.join(tmpdir(), "dex-effort-project-"));
const failures: string[] = [];
let checks = 0;

function readout(model: string | null): { name: string; effort: string | null } | null {
  const args = ["-p", ...(model ? ["--model", model] : []), "/model"];
  const run = spawnSync(cli!, args, {
    cwd: project,
    env: { ...process.env, CLAUDE_CONFIG_DIR: config },
    encoding: "utf8",
    timeout: 60_000,
  });
  const line = run.stdout.split("\n").find((l) => l.startsWith("Current model: "));
  if (!line) return null;
  return { name: /`([^`]*)`/.exec(line)?.[1] ?? line, effort: /\(effort: ([a-z]+)\)/.exec(line)?.[1] ?? null };
}

function expect(model: string | null, wanted: string | null, why: string, remapped?: string) {
  checks++;
  const got = readout(model);
  const label = model ?? "(no --model)";
  if (got && remapped && got.name === remapped) {
    checks--;
    console.log(`note  ${label} runs as ${got.name} now, so the list's entry for it is not measured`);
  } else if (!got) {
    failures.push(`${label}: no "Current model" line — ${why}`);
  } else if (got.effort !== wanted) {
    failures.push(`${label} (${got.name}): effort ${got.effort ?? "none"}, wanted ${wanted ?? "none"} — ${why}`);
  } else {
    console.log(`ok  ${label} (${got.name}): ${got.effort ?? "no effort"} — ${why}`);
  }
}

try {
  writeFileSync(
    path.join(config, "settings.json"),
    JSON.stringify({ effortLevel: "low", modelSettings: { "claude-sonnet-5": { effortLevel: "medium" } } }),
  );

  // A retired id answers as the current default rather than as itself.
  const newest = readout("claude-opus-5-5")?.name;
  for (const id of legacy) {
    if (id === "claude-sonnet-5") continue;
    expect(id, "low", "a user-level level reaches a model on the legacy list", newest);
  }
  expect("claude-opus-5-5", null, "a user-level level does not reach Opus 5.5");
  expect("opus[1m]", null, "nor the alias the picker offers for it");
  expect("haiku", null, "nor Haiku 5.5, which the haiku alias runs since CLI 2.1.293");
  expect(null, null, "nor Default, which is Opus 5.5");
  expect("claude-sonnet-5", "medium", "a per-model entry beats its file's top-level level");

  writeFileSync(
    path.join(config, "settings.json"),
    JSON.stringify({ effortLevel: "low", modelSettings: { "claude-opus-5-5": { effortLevel: "medium" } } }),
  );
  expect("claude-opus-5-5", "medium", "a per-model entry in the user's file reaches Opus 5.5");

  mkdirSync(path.join(project, ".claude"));
  writeFileSync(path.join(project, ".claude", "settings.json"), JSON.stringify({ effortLevel: "high" }));
  expect("claude-opus-5-5", "high", "a project's top-level level beats the user's per-model entry");
} finally {
  rmSync(config, { recursive: true, force: true });
  rmSync(project, { recursive: true, force: true });
}

if (failures.length) {
  for (const f of failures) console.error(`FAIL: ${f}`);
  console.error(`effort-default-probe: ${failures.length} of ${checks} check(s) failed`);
  process.exit(1);
}
console.log(`effort-default-probe: ${checks} checks passed`);
