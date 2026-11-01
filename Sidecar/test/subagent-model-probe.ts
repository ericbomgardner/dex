/**
 * Which model a session's subagents run on: the per-call `model`, and the
 * `CLAUDE_CODE_SUBAGENT_MODEL` default.
 *
 *   node test/subagent-model-probe.ts
 *
 * The app does not set the variable, so the env readings below are what to
 * re-check before setting it. The per-call `model` is relied on.
 *
 * The variable is a default, not a floor — since CLI v2.1.251, which turned
 * the old reading over without a word to anyone running it. It used to be the
 * first branch of the CLI's subagent resolver, returning before the per-call
 * model, the agent's frontmatter and inherit were looked at; an agent that
 * asked for haiku by name came back as Opus. Now the precedence is
 * `tool` > `frontmatter` > `env` > `inherit`: an explicit ask wins, and the
 * variable only decides for agents that never chose. As a floor it dragged
 * agents pinned below the session up to the variable's model.
 * v2.1.257 added `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` to put the override back;
 * the app deliberately does not send it.
 *
 * So the probe pins both halves of "default": an ask the env would have
 * steamrolled is honoured, and a spawn that names nothing still lands on the
 * env's model rather than inheriting the session's.
 *
 * `env` replaces the subprocess environment rather than adding to it, which is
 * why the host spreads `process.env` into it. Left unprobed on its own: a
 * session started without PATH or credentials fails on its first turn, so the
 * control run below is already the check.
 *
 * The session and the ask always name different models, which they did not used
 * to. A haiku session asking its subagent for haiku reads the same whether the
 * `tool` model was honoured or `inherit` was, so that control could not tell the
 * two apart and passed either way. The unpinned runs now ask downward, an Opus
 * session for a haiku agent, and upward, an Opus session for a Fable one. Either
 * coming back as the session's own model means the per-call `model` has stopped
 * being read.
 *
 * The upward run is not symmetry for its own sake: `model: "fable"` quietly
 * resolving to the session's own model is a delegation that costs a call and
 * changes nothing, with nothing in the result to show it happened.
 *
 * Read off the subagent's own transcript rather than out of the model: a
 * subagent asked which model it is cannot answer reliably, but every turn it
 * writes carries the resolved id on `message.model`. The stream is no use here —
 * a subagent's text reaches it only under `forwardSubagentText`, and one that
 * calls no tools sends nothing either way. Verified against SDK 0.3.257 and CLI
 * v2.1.257 on 2026-09-01.
 *
 * Run in a scratch directory, since a CLAUDE.md above the cwd is read by the
 * session deciding whether to delegate at all.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-subagent-model-"));

// Named as the Agent tool rather than the Task tool: asked for the latter, a
// session reaches for TaskCreate and spawns nothing, and the probe reads an
// unpinned run where nothing ran as one where the default held.
function ask(model?: string): string {
  const withModel = model
    ? `with subagent_type 'general-purpose' and model '${model}'`
    : "with subagent_type 'general-purpose' and no model parameter at all";
  return (
    `Use the Agent tool once, ${withModel}, ` +
    "and give it this whole task: reply with the word ping and nothing else. " +
    "Then say done. Do not use any other tool."
  );
}

/** Where a session's subagents write, found by the id it is filed under. */
function subagentDirectory(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, sessionId, "subagents");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** The models the session's subagents ran on, by the ids they wrote down. */
async function subagentModels(
  { session, asked, fallback }: { session: string; asked?: string; fallback?: string },
): Promise<string[]> {
  const options: Record<string, unknown> = {
    cwd: scratch,
    model: session,
    systemPrompt: { type: "preset", preset: "claude_code" },
    ...(fallback ? { env: { ...process.env, CLAUDE_CODE_SUBAGENT_MODEL: fallback } } : {}),
  };

  let sessionId: string | null = null;
  for await (const message of query({ prompt: ask(asked), options: options as any })) {
    if ("session_id" in message && message.session_id) sessionId = message.session_id;
  }
  if (!sessionId) return [];

  const directory = subagentDirectory(sessionId);
  if (!directory) return [];

  const models = new Set<string>();
  for (const file of readdirSync(directory)) {
    for (const line of readFileSync(path.join(directory, file), "utf8").split("\n")) {
      if (!line.startsWith("{")) continue;
      const model = JSON.parse(line)?.message?.model;
      if (model) models.add(model);
    }
  }
  return [...models];
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

/**
 * Asked twice if the first ask spawned nothing.
 *
 * Whether the model reaches for the Agent tool at all is its decision, not a
 * surface — asked for a fable subagent it declined once in a run that had
 * passed all afternoon, and the probe read that as fable being refused. This
 * retries the *setup* and never the reading: a spawn that happens and comes
 * back on the wrong model still fails, first time and every time.
 */
async function spawned(options: Parameters<typeof subagentModels>[0]): Promise<string[]> {
  const first = await subagentModels(options);
  if (first.length > 0) return first;
  console.log("  (nothing spawned — asking once more before calling it a reading)");
  return subagentModels(options);
}

try {
  const down = await spawned({ session: "opus", asked: "haiku" });
  console.log(`  opus session, haiku asked: ${down.join(", ") || "no subagent turns"}`);
  check(down.length > 0, "the ask spawns a subagent at all, so the readings below are readings");
  check(
    down.length > 0 && down.every((model) => model.includes("haiku")),
    "unpinned, an Opus session's subagent asked for haiku runs on haiku",
  );

  const up = await spawned({ session: "opus", asked: "fable" });
  console.log(`  opus session, fable asked: ${up.join(", ") || "no subagent turns"}`);
  check(up.length > 0, "asking for fable spawns a subagent rather than refusing the model");
  check(
    up.length > 0 && up.every((model) => model.includes("fable")),
    "unpinned, an Opus session's subagent asked for fable runs on fable",
  );

  const overruled = await spawned({ session: "haiku", asked: "sonnet", fallback: "opus" });
  console.log(`  env opus, sonnet asked: ${overruled.join(", ") || "no subagent turns"}`);
  check(overruled.length > 0, "a session carrying the env default still spawns its subagent");
  check(
    overruled.length > 0 && overruled.every((model) => model.includes("sonnet")),
    "an explicit ask outranks the env — opus back here means the floor is back",
  );

  const defaulted = await spawned({ session: "haiku", fallback: "opus" });
  console.log(`  env opus, nothing asked: ${defaulted.join(", ") || "no subagent turns"}`);
  check(defaulted.length > 0, "a spawn that names no model still spawns");
  check(
    defaulted.length > 0 && defaulted.every((model) => model.includes("opus")),
    "with no model on the spawn, the env decides — haiku back here means inherit does",
  );
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nsubagent-model: ${failures.length} check(s) failed`
    : "\nsubagent-model: all checks passed",
);
process.exit(failures.length ? 1 : 0);
