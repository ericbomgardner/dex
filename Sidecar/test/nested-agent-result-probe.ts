/**
 * Whether a *nested* background agent's result is written into the transcript of
 * the subagent that launched it.
 *
 *   node test/nested-agent-result-probe.ts
 *
 * The changelog for CLI v2.1.259 says nested background subagent results are now
 * saved in the parent subagent's transcript, "so resumed subagents keep them and
 * shared transcripts show the delivery". Nothing else here watches
 * that, and it is exactly the kind of claim the app is built on: a background
 * agent's call comes back at launch, so the only word that the work is over is
 * whatever the CLI writes afterwards — a `<task-notification>` turn, the same
 * notification absorbed into a running tool call as an `attachment`, or a
 * `TaskOutput` collection. One level down, in `subagents/agent-<id>.jsonl`, the
 * app reads that file as a conversation of its own, and a call with nothing to
 * settle it draws as running for the rest of the file.
 *
 * The nesting is built rather than waited for: a foreground agent at depth 1
 * (so the session's own turn stays open behind it) is told to launch one
 * background agent at depth 2 whose whole job is to echo a marker, then to sit
 * through short `sleep`s until the answer reaches it. `TaskOutput` is refused on
 * purpose — collecting a result is a different door, and
 * what is being measured here is what the CLI *delivers* unasked.
 *
 * What comes out is a census, not a guess: every record in the depth-1 file that
 * could possibly settle the depth-2 call is listed with its shape and its
 * distance from the call. The one assertion is that at least one of them exists.
 * If the CLI writes nothing there, that is the reading, and the probe is red.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-nested-agent-"));

/** Unique per run, so the depth-2 agent's own words are findable anywhere. */
const MARKER = `NESTED-${randomBytes(3).toString("hex").toUpperCase()}`;

// The depth-1 agent's whole task. It must outlive the agent it launches, or the
// CLI has nowhere to deliver to — hence the sleeps, which also put a running
// tool call under the notification and so exercise the absorbed shape too.
const INNER =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
  "description 'marker', and run_in_background: true, giving it this whole task: " +
  `reply with the single word ${MARKER} and nothing else. ` +
  "Then wait for that agent to come back to you: run the Bash command 'sleep 20', " +
  "and after each one check whether its result has reached you, repeating up to " +
  "five times. Do NOT use TaskOutput, and do not do the marker work yourself. " +
  "When you have it, say in one line the exact word it replied with, and the " +
  "agentId of the agent you launched if you know it.";

const ASK =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
  "description 'nested', and run_in_background: false, giving it this whole task, " +
  "which is everything between the ==== lines:\n" +
  `====\n${INNER}\n====\n` +
  "Then say in one line what that agent reported. Do not use any other tool yourself.";

const LIMIT_MS = 240_000;

/** An input stream that stays open until we let it go, as the host's does. */
function heldOpen(text: string): { stream: AsyncGenerator<unknown>; close: () => void } {
  let release: () => void = () => {};
  const closed = new Promise<void>((resolve) => {
    release = resolve;
  });

  async function* stream(): AsyncGenerator<unknown> {
    yield { type: "user", message: { role: "user", content: text }, parent_tool_use_id: null };
    await closed;
  }

  return { stream: stream(), close: () => release() };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function transcriptFor(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * The transcript trails the turn that ended it by seconds, and a subagent's
 * file trails its own last word, so anything counted off disk waits for the
 * files to stop growing rather than reading at the result.
 */
async function settled(files: string[], quietMs = 8_000, capMs = 60_000): Promise<void> {
  const until = Date.now() + capMs;
  let total = -1;
  let still = 0;

  while (Date.now() < until) {
    const now = files
      .filter((f) => existsSync(f))
      .reduce((sum, f) => sum + statSync(f).size, 0);
    still = now === total ? still + 500 : 0;
    total = now;
    if (still >= quietMs) return;
    await sleep(500);
  }
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

/** Keys and short values, so a whole conversation doesn't land in the log. */
function sketch(value: unknown, depth = 0): unknown {
  if (typeof value === "string") {
    return value.length > 140 ? `${value.slice(0, 140)}…(${value.length} chars)` : value;
  }
  if (Array.isArray(value)) {
    const head = value.slice(0, 4).map((v) => sketch(v, depth + 1));
    return value.length > 4 ? [...head, `…${value.length - 4} more`] : head;
  }
  if (value && typeof value === "object") {
    if (depth >= 4) return "{…}";
    const out: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(value as Record<string, unknown>)) {
      out[key] = inner === null || inner === undefined ? inner : sketch(inner, depth + 1);
    }
    return out;
  }
  return value;
}

function blocks(record: any): any[] {
  const content = record?.message?.content;
  return Array.isArray(content) ? content : [];
}

function toolUses(record: any, name?: string): any[] {
  return blocks(record).filter(
    (b) => b?.type === "tool_use" && (name === undefined || b?.name === name),
  );
}

function firstModel(written: any[]): string | null {
  for (const record of written) {
    const model = record?.message?.model;
    if (typeof model === "string" && model !== "<synthetic>") return model;
  }
  return null;
}

interface Run {
  sessionId: string | null;
  tasks: string[];
  events: string[];
}

async function probe(): Promise<Run> {
  const run: Run = { sessionId: null, tasks: [], events: [] };

  const input = heldOpen(ASK);
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
    } as any,
  });

  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.session_id && !run.sessionId) run.sessionId = message.session_id;
      const subtype: string | undefined = message.subtype;
      if (typeof subtype === "string" && subtype.startsWith("task")) {
        run.events.push(`${subtype}${message.status ? `/${message.status}` : ""}`);
        if (subtype === "task_started" && message.task_id) run.tasks.push(message.task_id);
      }
      if (message.type === "result") {
        run.events.push("result");
        break;
      }
    }
  } finally {
    clearTimeout(deadline);
    input.close();
    session.close?.();
  }

  return run;
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

try {
  const run = await probe();
  console.log(`\n  marker: ${MARKER}`);
  console.log(`  session: ${run.sessionId ?? "never announced"}`);
  console.log(`  task events: ${run.events.join(" → ") || "none"}`);

  const parent = run.sessionId ? transcriptFor(run.sessionId) : null;
  if (!parent) {
    check(false, "the session wrote a transcript to read");
  } else {
    const directory = path.join(path.dirname(parent), run.sessionId!, "subagents");
    const names = existsSync(directory)
      ? readdirSync(directory).filter((n) => n.startsWith("agent-") && n.endsWith(".jsonl"))
      : [];
    await settled([parent, ...names.map((n) => path.join(directory, n))]);

    console.log(`\n  transcript: ${parent}`);
    console.log(`  subagents/: ${existsSync(directory) ? directory : "never created"}`);

    const filed = names.map((name) => {
      const file = path.join(directory, name);
      const written = records(file);
      return {
        name,
        file,
        id: name.replace(/^agent-|\.jsonl$/g, ""),
        written,
        agentCalls: written.flatMap((r) => toolUses(r, "Agent")),
        model: firstModel(written),
      };
    });

    for (const f of filed) {
      console.log(
        `    ${f.name}  ${f.written.length} records  model=${f.model ?? "none"}` +
          `  Agent calls=${f.agentCalls.length}`,
      );
    }

    // Depth 1 is the file that launched something; depth 2 is the one it named.
    const depth1 = filed.find((f) => f.agentCalls.length > 0) ?? null;
    const nestedCall = depth1?.agentCalls.find((c) => c?.input?.run_in_background === true)
      ?? depth1?.agentCalls[0]
      ?? null;
    const callIndex = depth1
      ? depth1.written.findIndex((r) => toolUses(r).some((b) => b.id === nestedCall?.id))
      : -1;

    // The receipt: the tool_result for that call. At depth 2 the reading
    // says `toolUseResult` is null on every spawn, so the id lives only
    // in the receipt's own text.
    const receiptIndex = depth1
      ? depth1.written.findIndex((r) =>
          blocks(r).some((b) => b?.type === "tool_result" && b?.tool_use_id === nestedCall?.id),
        )
      : -1;
    const receipt = receiptIndex >= 0 ? depth1!.written[receiptIndex] : null;
    const receiptText = receipt ? JSON.stringify(receipt) : "";
    const namedInReceipt = receiptText.match(/agentId:\s*([A-Za-z0-9_-]+)/)?.[1] ?? null;

    // Named by the receipt, or failing that the file that said the marker. Never
    // "whatever else is in the directory": a resumed or retried agent writes a
    // file too, and binding to it would describe the wrong relationship.
    const depth2 =
      filed.find((f) => f.id === namedInReceipt) ??
      filed.find((f) => f !== depth1 && JSON.stringify(f.written).includes(MARKER)) ??
      null;

    console.log(`\n  depth-1 file: ${depth1?.name ?? "none found"}`);
    console.log(`  depth-2 file: ${depth2?.name ?? "none found"}  (${depth2?.written.length ?? 0} records)`);
    console.log(`  nested Agent call: ${nestedCall?.id ?? "none"} at record #${callIndex}`);
    console.log(
      `  background: ${nestedCall ? JSON.stringify(nestedCall.input?.run_in_background) : "—"}`,
    );
    console.log(
      `  receipt at record #${receiptIndex}, toolUseResult = ` +
        `${receipt ? JSON.stringify(sketch(receipt.toolUseResult)) : "no receipt"}`,
    );
    console.log(`  agent id in the receipt text: ${namedInReceipt ?? "not named"}`);
    console.log(`  TaskOutput used at depth 1: ${depth1 ? depth1.written.some((r) => toolUses(r, "TaskOutput").length > 0) : false}`);

    // Everything in the depth-1 file that could be the depth-2 result. Kinds are
    // collected rather than short-circuited: a record can be more than one, and
    // which shapes co-occur is part of the reading.
    const agentIds = [namedInReceipt, depth2?.id].filter(Boolean) as string[];
    const candidates: { index: number; kinds: string[]; record: any }[] = [];

    depth1?.written.forEach((record, index) => {
      if (index === receiptIndex || index === callIndex) return;
      const raw = JSON.stringify(record);
      const kinds: string[] = [];

      // A notification settles the call only if it names it: the depth-1 agent
      // can background a Bash of its own, and that writes the same shapes for a
      // task this probe is not measuring.
      const namesTheCall =
        (nestedCall?.id && raw.includes(nestedCall.id)) || agentIds.some((id) => raw.includes(id));
      const isNotice =
        raw.includes("<task-notification>") || raw.includes('"commandMode":"task-notification"');
      if (isNotice && !namesTheCall) kinds.push("notification for another task");
      if (namesTheCall && raw.includes("<task-notification>")) kinds.push("task-notification text");
      if (namesTheCall && raw.includes('"commandMode":"task-notification"')) kinds.push("attachment/commandMode");
      if (record?.type === "attachment") kinds.push("attachment record");
      if (record?.type === "queue-operation") kinds.push(`queue/${record.operation}`);
      if (blocks(record).some((b) => b?.type === "tool_result" && b?.tool_use_id === nestedCall?.id)) {
        kinds.push("tool_result for the nested call");
      }
      const result = record?.toolUseResult;
      if (result && typeof result === "object") {
        if (typeof result.agentId === "string" && agentIds.includes(result.agentId)) {
          kinds.push("toolUseResult.agentId");
        }
        if (typeof result.task?.task_id === "string" && agentIds.includes(result.task.task_id)) {
          kinds.push("toolUseResult.task.task_id");
        }
      }
      if (!kinds.length && agentIds.some((id) => raw.includes(id))) kinds.push("mentions the agent id");
      if (!kinds.length && record?.type === "user" && raw.includes(MARKER)) kinds.push("mentions the marker");

      if (kinds.length) candidates.push({ index, kinds, record });
    });

    console.log(`\n  records in the depth-1 file that could settle the call: ${candidates.length}`);
    for (const candidate of candidates) {
      const away = callIndex >= 0 ? candidate.index - callIndex : NaN;
      const where = Number.isNaN(away)
        ? "position unknown"
        : `${Math.abs(away)} record(s) ${away > 0 ? "after" : "before"} the call`;
      console.log(`\n  #${candidate.index}  ${where}  [${candidate.kinds.join(", ")}]`);
      console.log(`    ${JSON.stringify(sketch(candidate.record))}`);
    }

    // The launch receipt is not a completion, and neither is a record that only
    // happens to quote the id. What settles the call is a delivered result.
    const settlingKinds = [
      "task-notification text",
      "attachment/commandMode",
      "tool_result for the nested call",
      "toolUseResult.agentId",
      "toolUseResult.task.task_id",
    ];
    const settlers = candidates.filter((c) => c.kinds.some((k) => settlingKinds.includes(k)));

    const parentRecords = records(parent);
    const parentNotices = parentRecords.filter((r) => {
      const raw = JSON.stringify(r);
      return raw.includes("<task-notification>") || raw.includes('"commandMode":"task-notification"');
    });
    const parentNamesDepth2 = parentNotices.filter((r) =>
      agentIds.some((id) => JSON.stringify(r).includes(id)),
    );

    console.log(`\n  main transcript: ${parentRecords.length} records, ` +
      `${parentNotices.length} notification record(s), ` +
      `${parentNamesDepth2.length} of them naming the depth-2 agent`);
    for (const notice of parentNamesDepth2) {
      console.log(`    ${JSON.stringify(sketch(notice))}`);
    }
    console.log(
      `  depth-2 agent said the marker: ` +
        `${depth2 ? JSON.stringify(depth2.written).includes(MARKER) : false}`,
    );
    console.log(
      `  depth-1 agent repeated the marker: ` +
        `${depth1 ? depth1.written.some((r) => r.type === "assistant" && JSON.stringify(r).includes(MARKER)) : false}`,
    );

    console.log("");
    // Setup, not reading: without a nested background spawn there is nothing to
    // measure, and a run that measures nothing must not read as a pass.
    check(depth1 !== null && nestedCall !== null, "a depth-1 agent launched a nested agent");
    check(
      nestedCall?.input?.run_in_background === true,
      "and launched it in the background, which is the shape being measured",
    );
    check(depth2 !== null && depth2.written.length > 0, "the nested agent wrote its own transcript");

    check(
      settlers.length > 0,
      "the depth-1 file holds a record that settles the nested background call",
    );

    if (!settlers.length) {
      console.log(
        `\n  what was found instead: ${
          candidates.length
            ? candidates.map((c) => `#${c.index} [${c.kinds.join(", ")}]`).join("; ")
            : "nothing in the depth-1 file mentions the nested agent at all"
        }`,
      );
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nnested-agent-result: FAIL — ${failures.length} check(s) failed`
    : "\nnested-agent-result: PASS — all checks passed",
);
process.exit(failures.length ? 1 : 0);
