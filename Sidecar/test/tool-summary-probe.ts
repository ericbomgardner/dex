/**
 * What the CLI's own summaries of tool calls are, under the SDK.
 *
 *   node test/tool-summary-probe.ts
 *
 * Two undocumented switches name what a session's calls did:
 *
 *  - `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` in the environment: after a reply's
 *    calls come back, a side request writes a label for them, sent as a
 *    `tool_use_summary` message with `summary` and `preceding_tool_use_ids`.
 *  - `agentProgressSummaries` on the query: a running subagent's
 *    `task_progress` carries a `summary`, re-made about every 30s.
 *
 * Run 1 sets the env var on a session that reads, searches, runs a failing
 * command and edits, across several replies, and records each summary: which
 * calls it covers, how long after the last of their results it lands, and
 * whether it lands before the next reply starts. Then it reads the transcript
 * for any trace of the summaries and for what the helper ran on.
 *
 * Run 2 leaves the env var off and sets `agentProgressSummaries`, with a
 * foreground subagent that works for over a minute: does the main session
 * stay silent, and what does `task_progress` say.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-tool-summary-"));
const LIMIT_MS = 300_000;

writeFileSync(path.join(scratch, "alpha.txt"), "first file\nneedle here\n");
writeFileSync(path.join(scratch, "beta.txt"), "second file\nno match\n");
writeFileSync(path.join(scratch, "gamma.swift"), "let greeting = \"hello\"\nprint(greeting)\n");

const WORK =
  "Do these steps in order, one reply per step, and say nothing between them:\n" +
  "1. Read alpha.txt and beta.txt, both in the same reply.\n" +
  "2. Use Grep to search this folder for the word needle.\n" +
  "3. Use Bash to run `ls missing-folder` (it will fail).\n" +
  "4. Use Edit on gamma.swift to change hello to goodbye.\n" +
  "Then reply with the word done.";

const AGENT_WORK =
  "Use the Agent tool once, with subagent_type 'general-purpose' and description 'slow tour', " +
  "in the foreground. Its prompt: 'In this folder, run `sleep 20` with Bash, then read alpha.txt, " +
  "then run `sleep 20`, then read beta.txt, then run `sleep 20`, then read gamma.swift. One call per " +
  "step, in that order. Then reply with the word toured.' Do not use any other tool. When the agent " +
  "returns, reply with the word done.";

interface Summary {
  text: string;
  ids: string[];
  at: number;
}

interface Run {
  sessionId?: string;
  calls: Map<string, { name: string; input: unknown; resultAt?: number; isError?: boolean }>;
  replyStarts: number[];
  summaries: Summary[];
  progress: { summary?: string; description: string; at: number }[];
  agentStartedAt?: number;
  result?: any;
}

function blocks(message: any): any[] {
  return Array.isArray(message?.message?.content) ? message.message.content : [];
}

async function probe(prompt: string, options: Record<string, unknown>, env: Record<string, string>): Promise<Run> {
  const run: Run = { calls: new Map(), replyStarts: [], summaries: [], progress: [] };
  const session: any = query({
    prompt,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
      includePartialMessages: true,
      env: { ...process.env, ...env },
      ...options,
    } as any,
  });
  const deadline = setTimeout(() => session.close?.(), LIMIT_MS);
  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.session_id) run.sessionId ??= message.session_id;
      if (message.type === "stream_event" && message.parent_tool_use_id == null && message.event?.type === "message_start") {
        run.replyStarts.push(Date.now());
      }
      if (message.type === "assistant" && message.parent_tool_use_id == null) {
        for (const block of blocks(message)) {
          if (block.type === "tool_use") run.calls.set(block.id, { name: block.name, input: block.input });
        }
      }
      if (message.type === "user" && message.parent_tool_use_id == null) {
        for (const block of blocks(message)) {
          const call = block.type === "tool_result" ? run.calls.get(block.tool_use_id) : undefined;
          if (call && call.resultAt === undefined) {
            call.resultAt = Date.now();
            call.isError = block.is_error === true;
          }
        }
      }
      if (message.type === "tool_use_summary") {
        run.summaries.push({ text: message.summary, ids: message.preceding_tool_use_ids ?? [], at: Date.now() });
      }
      if (message.type === "system" && message.subtype === "task_started") run.agentStartedAt ??= Date.now();
      if (message.type === "system" && message.subtype === "task_progress") {
        run.progress.push({ summary: message.summary, description: message.description, at: Date.now() });
      }
      if (message.type === "result") {
        run.result = message;
        break;
      }
    }
  } finally {
    clearTimeout(deadline);
    session.close?.();
  }
  return run;
}

function transcriptFor(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function records(file: string): any[] {
  return readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

function brief(input: unknown): string {
  return JSON.stringify(input).slice(0, 80);
}

try {
  const run = await probe(WORK, {}, { CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES: "1" });
  console.log(`\nrun 1: env var set, ${run.calls.size} calls, ${run.summaries.length} summaries`);
  for (const [id, call] of run.calls) console.log(`  call ${id.slice(-6)} ${call.name}${call.isError ? " (error)" : ""} ${brief(call.input)}`);
  for (const summary of run.summaries) {
    const lastResult = Math.max(...summary.ids.map((id) => run.calls.get(id)?.resultAt ?? 0));
    const nextReply = run.replyStarts.find((at) => at > lastResult);
    const names = summary.ids.map((id) => run.calls.get(id)?.name ?? `unknown ${id.slice(-6)}`);
    console.log(
      `  "${summary.text}" (${summary.text.length} chars) covers ${summary.ids.length} [${names.join(", ")}], ` +
        `${summary.at - lastResult}ms after its last result, ` +
        (nextReply === undefined
          ? "no reply after"
          : nextReply > summary.at
            ? `${nextReply - summary.at}ms before the next reply starts`
            : `${summary.at - nextReply}ms after the next reply started`),
    );
  }
  console.log(`  cost $${run.result?.total_cost_usd?.toFixed(4)}; models: ${JSON.stringify(run.result?.modelUsage)}`);

  const covered = new Set(run.summaries.flatMap((summary) => summary.ids));
  check(run.summaries.length > 0, "the env var makes the SDK stream tool_use_summary messages");
  check(run.summaries.length >= 3, "a summary per reply with calls, not one per turn");
  check([...run.calls.keys()].every((id) => covered.has(id)), "every main-thread call is covered by some summary");
  check(run.summaries.some((summary) => summary.ids.length === 2), "a reply's parallel calls share one summary");
  check(
    run.summaries.every((summary) => summary.ids.every((id) => run.calls.get(id)?.resultAt !== undefined)),
    "a summary comes after the results of every call it covers",
  );

  const file = run.sessionId ? transcriptFor(run.sessionId) : null;
  check(file !== null, "the session's transcript is found");
  if (file) {
    const all = records(file);
    const types = [...new Set(all.map((record) => record.type))];
    console.log(`  transcript record types: ${types.join(", ")}`);
    const text = readFileSync(file, "utf8");
    // A label can repeat the prompt word for word ("Read alpha.txt and beta.txt"), so only one the prompt doesn't hold counts.
    const own = run.summaries.filter((summary) => !WORK.includes(summary.text));
    const traced = own.filter((summary) => text.includes(JSON.stringify(summary.text).slice(1, -1)));
    console.log(`  summaries not in the prompt whose text is in the file: ${traced.length} of ${own.length}`);
    const sources = all.filter((record) => record.type === "api-request").map((record) => `${record.querySource}:${record.params?.model}`);
    console.log(`  api-request sources: ${[...new Set(sources)].join(", ") || "(none)"}`);
    check(own.length > 0 && traced.length === 0, "nothing of the summaries is written to the transcript");
    check(!types.some((type) => /summary/i.test(type)), "no summary record type in the transcript");
    check(!sources.some((source) => source.startsWith("tool_use_summary")), "the helper's requests are not recorded as api-request");
  }

  const agent = await probe(AGENT_WORK, { agentProgressSummaries: true }, {});
  console.log(`\nrun 2: agentProgressSummaries, no env var; ${agent.summaries.length} tool_use_summary, ${agent.progress.length} task_progress`);
  for (const progress of agent.progress) {
    console.log(`  +${progress.at - (agent.agentStartedAt ?? progress.at)}ms description "${progress.description}" summary ${JSON.stringify(progress.summary)}`);
  }
  console.log(`  cost $${agent.result?.total_cost_usd?.toFixed(4)}; models: ${JSON.stringify(agent.result?.modelUsage)}`);
  check(agent.summaries.length === 0, "without the env var there are no tool_use_summary messages");
  check(agent.progress.some((progress) => progress.summary), "agentProgressSummaries puts a summary on task_progress");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\ntool-summary: ${failures.length} check(s) failed` : "\ntool-summary: all checks passed");
process.exit(failures.length ? 1 : 0);
