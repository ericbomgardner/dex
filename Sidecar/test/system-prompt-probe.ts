/**
 * Whether omitting `systemPrompt` still leaves a session without one.
 *
 *   node test/system-prompt-probe.ts
 *
 * The SDK does not fall back to the CLI's own prompt when the option is left
 * off: it reads the absent value as an empty custom prompt (`if (s === void 0)
 * d = ""` in sdk.mjs), so a session started without it runs with no system
 * prompt at all — no tool guidance, no Claude Code. Nothing says so. The
 * session comes up, lists its tools and answers, and only behaves oddly. So the
 * host asks for the preset by name, and this checks the reading that made it.
 * Verified against SDK 0.3.227 on 2026-08-11.
 *
 * Measured rather than asked. A session with no system prompt will still say it
 * is Claude Code if you ask it — it has the tools in front of it and infers the
 * rest — and it says so or doesn't depending on how the question is worded, so
 * its own account of its prompt is worth nothing here. What can't be inferred
 * is the size: the preset is thousands of tokens and they are counted for us.
 *
 * The append is asked rather than measured, because a marker invented for this
 * run is not something a session could report without having been handed it.
 *
 * Run in a scratch directory, since a CLAUDE.md above the cwd is context too
 * and would land in the same counts.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const MARKER = "pomelo";
// The preset measured ~6.4k tokens against an empty prompt. Well under that, so
// a build that trims it still passes, but far above the noise between two runs.
const SUBSTANTIAL = 2000;

const scratch = mkdtempSync(path.join(tmpdir(), "dex-system-prompt-"));

interface Run {
  tokens: number;
  text: string;
}

async function run(systemPrompt: unknown, ask: string): Promise<Run> {
  const options: Record<string, unknown> = { cwd: scratch, model: "haiku" };
  if (systemPrompt !== undefined) options.systemPrompt = systemPrompt;

  let tokens = 0;
  let text = "";
  for await (const message of query({ prompt: ask, options: options as any })) {
    if (message.type === "assistant") {
      for (const block of message.message.content ?? []) {
        if (block.type === "text") text += block.text;
      }
    }
    if (message.type === "result") {
      const usage: any = (message as any).usage ?? {};
      tokens =
        (usage.input_tokens ?? 0) +
        (usage.cache_creation_input_tokens ?? 0) +
        (usage.cache_read_input_tokens ?? 0);
    }
  }
  return { tokens, text: text.trim() };
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

try {
  const bare = await run(undefined, "Say ok.");
  const preset = await run({ type: "preset", preset: "claude_code" }, "Say ok.");
  const added = preset.tokens - bare.tokens;
  console.log(`  omitted ${bare.tokens} tokens, preset ${preset.tokens} — ${added} added`);
  check(
    added > SUBSTANTIAL,
    "omitting systemPrompt still costs the session the whole of the CLI's own",
  );

  const briefed = await run(
    { type: "preset", preset: "claude_code", append: `APPEND_MARKER is ${MARKER}.` },
    "What is APPEND_MARKER? Answer with the word alone.",
  );
  console.log(`  append: ${briefed.text.slice(0, 80)}`);
  check(briefed.text.toLowerCase().includes(MARKER), "append still reaches the session");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nsystem-prompt: ${failures.length} check(s) failed`
    : "\nsystem-prompt: all checks passed",
);
process.exit(failures.length ? 1 : 0);
