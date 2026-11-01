/**
 * What a hosted session says — on the SDK stream and in its transcript — when it
 * is told to `/compact`.
 *
 *   node test/compaction-probe.ts
 *
 * Compaction is the one thing that happens to a conversation rather than in it.
 * The turn count doesn't move, nobody typed anything the pane can show, and what
 * changes is the only number the row reads off the newest assistant turn: the
 * context. So a session that compacts and is then read the way every other
 * session is read looks like a conversation that suddenly forgot what it was
 * carrying, with nothing in the pane saying why.
 *
 * Three readings, one per thing the app is about to rest on:
 *
 *  1. **The stream says it is compacting while it is.** `SDKStatusMessage`
 *     carries `status: "compacting"` and, on the way out, `compact_result`. That
 *     is the only live word there is — the transcript is written after the fact,
 *     and the turn that does the compacting produces no assistant text to read.
 *     What has to hold is that the status arrives *and* that something ends it;
 *     a status that only ever turns on is a spinner that never stops.
 *  2. **The boundary carries the CLI's own pair.** `compact_boundary` /
 *     `compactMetadata.preTokens` and `postTokens` go on the pane's divider.
 *     `post_tokens` is optional in the SDK's own types, so whether it is
 *     actually written is the reading, not an assumption — and whether it is
 *     the badge's number is the reading that came back no (below).
 *  3. **The file order is fixed, and the pane's divider depends on it.** The
 *     block is boundary, summary, caveat, the typed `/compact`, its stdout — so
 *     the summary the pane wants to collapse sits *above* the command that asked
 *     for it, and a reader that drew records in file order with no knowledge of
 *     this would put the answer before the question. The check that carries the
 *     weight is that **no assistant record sits inside the block**: that is what
 *     makes it safe to draw the whole run as one divider.
 *
 * The third prompt is what settles reading 2, and it is the reading that came
 * back **not** as expected. `postTokens` and the badge are two different
 * measurements: `postTokens` counts the *conversation* the CLI kept, and the
 * badge counts what the next request actually sent, which is that conversation
 * **plus the system prompt and the tool schemas**. On this run those two were
 * 2,424 and 21,717 — nine times apart, with the whole of the difference being a
 * floor the session pays on its very first turn (measured here at 21,479, for a
 * one-line prompt). So a badge set from `postTokens` would show a session
 * carrying a tenth of what it is about to send, and a compaction on a short
 * conversation moves the badge barely at all: 24,032 before, 21,717 after,
 * against a `preTokens`/`postTokens` pair that says 25,490 → 2,424.
 *
 * What is asserted is therefore the relation rather than the closeness: the
 * compacted turn carries no more than the session's own opening floor plus a few
 * times the summary. That fails if compaction stops reducing and passes while
 * the floor is the floor, which is the only thing a badge reader needs to know.
 *
 * What the compacted conversation holds is the summary **and the newest reply
 * from before it, kept verbatim** (`preservedMessages`, the next request's
 * blobs). The summary is written without seeing that reply, and says so since
 * 2.1.314; since 2.1.311 a reply with no `<summary>` block is asked for again.
 * Together these mean a session whose last reply is its bulk compacts to about
 * its own size: haiku re-answers the last prompt inside the summary, so the bulk
 * is carried twice. That is what went red on 2.1.314 (25,293 before, 25,402
 * after), and why the fill puts its bulk early and ends on a one-line turn.
 *
 * Run on `haiku`, since none of this is about the model. The filling prompts
 * only exist to give compaction something to do; they ask for no tools, so each
 * turn is one long block of text and nothing else.
 *
 * The order on the stream is worth reading before trusting it: the status turns
 * off *before* the boundary arrives, and a fresh `system/init` sits between them
 * — the CLI restating the session the way it does at the head of a turn. So a
 * client that waits for the status to clear and then looks for the boundary is
 * looking in the right direction, but one that treats the cleared status as
 * "compaction over, nothing more coming" drops the only record carrying the new
 * size.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "compaction-probe-"));

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const brief = (value: unknown, limit = 500): string => {
  const text = JSON.stringify(value);
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
};

/** An input stream that stays open until we let it go, as the host's does. */
function heldOpen(): { stream: AsyncGenerator<unknown>; send: (text: string) => void; close: () => void } {
  const queue: unknown[] = [];
  let wake: (() => void) | null = null;
  let closed = false;

  async function* stream(): AsyncGenerator<unknown> {
    while (true) {
      if (queue.length > 0) {
        yield queue.shift();
        continue;
      }
      if (closed) return;
      await new Promise<void>((resolve) => {
        wake = () => {
          wake = null;
          resolve();
        };
      });
    }
  }

  return {
    stream: stream(),
    send: (text: string) => {
      queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
      wake?.();
    },
    close: () => {
      closed = true;
      wake?.();
    },
  };
}

const input = heldOpen();
const session: any = query({
  prompt: input.stream as any,
  options: {
    cwd: scratch,
    model: "haiku",
    systemPrompt: { type: "preset", preset: "claude_code" },
    permissionMode: "bypassPermissions",
    settingSources: [],
  } as any,
});

const iterator = (session as AsyncIterable<any>)[Symbol.asyncIterator]();

/** Everything a turn said, up to and including the `result` that ends it. */
async function turn(text: string, limitMs: number): Promise<any[]> {
  input.send(text);
  const said: any[] = [];
  const deadline = Date.now() + limitMs;
  while (Date.now() < deadline) {
    const next = await Promise.race([
      iterator.next(),
      sleep(Math.max(0, deadline - Date.now())).then(() => ({ done: true, value: undefined })),
    ]);
    if (next.done) break;
    said.push(next.value);
    if (next.value?.type === "result") break;
  }
  return said;
}

const label = (message: any): string => {
  const parts = [message?.type];
  if (message?.subtype) parts.push(message.subtype);
  if (message?.type === "system" && message?.subtype === "status") parts.push(String(message.status));
  return parts.join("/");
};

let sessionId: string | null = null;
let announcedTranscript: string | null = null;

// ------------------------------------------------------------- the stream

console.log("\nfilling the window");

// Three turns rather than one, and this is the probe's own trap. Compaction
// counts *groups*, not tokens: a single fat turn is refused outright with
// `compact_result: "failed"` and `Not enough messages to compact.`, which reads
// exactly like a compaction that ran and went wrong. Whatever is compacted also
// has to sit above whatever is kept, so there has to be something to drop.
//
// And big enough that compaction visibly saves something. Since 2.1.304 the CLI
// sends the skill list again after compacting, ~1.5k tokens the badge regains,
// so a conversation of a few thousand tokens compacts to about its own size.
//
// The bulk goes in the first two turns, not the last. The newest reply is kept
// verbatim after the summary, and the summary is written without seeing it, so
// haiku answers the last prompt again inside the summary: a fat last reply is
// carried twice and compaction saves nothing (2.1.314: 25,293 before, 25,402 after).
const fill = [
  "List 60 kinds of fruit. Write two full sentences about each one. Do not use any tools.",
  "Now 40 vegetables, two full sentences about each one. Still no tools.",
  "Now 40 cheeses, two full sentences about each one. Still no tools.",
  "Now name one bread, in one sentence. Still no tools.",
];

let first: any[] = [];
for (const prompt of fill) {
  first = await turn(prompt, 180_000);
  for (const message of first) {
    if (message.type === "system" && message.subtype === "init" && sessionId === null) {
      sessionId = message.session_id;
      announcedTranscript = message.transcript_path ?? null;
    }
  }
  if (first.at(-1)?.type !== "result") break;
}
console.log(`  session id: ${sessionId ?? "never announced"}`);
console.log(`  transcript_path on init: ${announcedTranscript ?? "not carried"}`);
check(first.at(-1)?.type === "result", "the turns that fill the window all finish");

const preResult = first.at(-1);
const preTurn = [...first].reverse().find((m) => m.type === "assistant" && m.message?.usage);
const usageOf = (message: any): number => {
  const usage = message?.message?.usage ?? {};
  return (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
};
const preContext = preTurn ? usageOf(preTurn) : 0;
console.log(`  carrying before compaction: ${preContext} tokens`);
if (preResult?.total_cost_usd !== undefined) console.log(`  cost so far: $${preResult.total_cost_usd}`);

console.log("\nthe /compact turn on the stream");
const during = await turn("/compact", 300_000);

console.log(`  sequence: ${during.map(label).join(" → ") || "nothing at all"}`);

const statuses = during.filter((m) => m.type === "system" && m.subtype === "status");
const boundaries = during.filter((m) => m.type === "system" && m.subtype === "compact_boundary");
for (const message of [...statuses, ...boundaries]) console.log(`  ${label(message)}: ${brief(message)}`);

check(
  statuses.some((m) => m.status === "compacting"),
  "a system/status message says the session is compacting",
);

const ender = statuses.find(
  (m, index) => index > statuses.findIndex((s) => s.status === "compacting") && m.status !== "compacting",
);
console.log(
  `  ended by: ${ender ? `${label(ender)} compact_result=${ender.compact_result ?? "none"}` : "nothing — the status never turns off"}`,
);
check(ender !== undefined, "a later status message ends the compacting state");
check(
  ender?.compact_result === "success",
  `the ending status carries compact_result=success (saw ${ender?.compact_result ?? "nothing"})`,
);

check(boundaries.length === 1, `exactly one compact_boundary on the stream (saw ${boundaries.length})`);
const streamBoundary = boundaries[0];
check(
  streamBoundary?.compact_metadata?.trigger === "manual",
  `the boundary calls the trigger manual (saw ${streamBoundary?.compact_metadata?.trigger ?? "nothing"})`,
);
check(
  typeof streamBoundary?.compact_metadata?.pre_tokens === "number",
  `the boundary carries pre_tokens (${streamBoundary?.compact_metadata?.pre_tokens})`,
);
check(
  typeof streamBoundary?.compact_metadata?.post_tokens === "number",
  `the boundary carries post_tokens (${streamBoundary?.compact_metadata?.post_tokens})`,
);

const summaryOnStream = during.find((m) => {
  if (m.type !== "user") return false;
  if (m.isCompactSummary) return true;
  const content = m.message?.content;
  const text = typeof content === "string"
    ? content
    : (Array.isArray(content) ? content : []).map((b: any) => (b?.type === "text" ? b.text : "")).join("");
  return text.startsWith("This session is being continued");
});
check(summaryOnStream !== undefined, "the summary arrives on the stream as a user message");

// The status clears first and the boundary comes after it, with a fresh
// `system/init` in between. Pinned because the obvious client — clear the
// spinner, stop reading — would miss the record carrying the new size.
const statusEndsAt = during.indexOf(ender!);
const boundaryAt = during.findIndex((m) => m.subtype === "compact_boundary");
check(
  statusEndsAt >= 0 && boundaryAt > statusEndsAt,
  `the boundary arrives after the status has already cleared (status at ${statusEndsAt}, boundary at ${boundaryAt})`,
);

check(during.at(-1)?.type === "result", "a result ends the /compact turn");
const boundaryBeforeResult = during.findIndex((m) => m.subtype === "compact_boundary");
check(
  boundaryBeforeResult >= 0 && boundaryBeforeResult < during.length - 1,
  "and the boundary arrives before that result, not after it",
);

// ------------------------------------------------------------- after it

console.log("\nthe turn after");
const third = await turn("Reply with just: ok.", 120_000);
check(third.at(-1)?.type === "result", "the session takes another turn after compacting");

input.close();
try {
  await session.close?.();
} catch {}

// --------------------------------------------------------------- the file

console.log("\nthe transcript");

function transcriptFor(id: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${id}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

let file = announcedTranscript && existsSync(announcedTranscript) ? announcedTranscript : null;
const findDeadline = Date.now() + 30_000;
while (file === null && Date.now() < findDeadline) {
  file = sessionId ? transcriptFor(sessionId) : null;
  if (file === null) await sleep(200);
}
check(file !== null, `the transcript is on disk (${file ?? "never found"})`);

if (file) {
  // The lag runs to the far end of the turn, so the file is waited on until it
  // stops moving rather than sampled once.
  let size = -1;
  let quietFor = 0;
  while (quietFor < 2_000) {
    const now = statSync(file).size;
    if (now === size) quietFor += 250;
    else {
      size = now;
      quietFor = 0;
    }
    await sleep(250);
  }

  const records = readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter((record) => record !== null) as any[];

  const textOf = (record: any): string => {
    const content = record?.message?.content;
    if (typeof content === "string") return content;
    return (Array.isArray(content) ? content : [])
      .map((block: any) => (block?.type === "text" ? block.text : ""))
      .join("");
  };

  const at = records.findIndex((r) => r.type === "system" && r.subtype === "compact_boundary");
  check(at >= 0, "the transcript holds a compact_boundary record");

  if (at >= 0) {
    const block = records.slice(at, at + 5);
    console.log("  the block, in file order:");
    for (const [offset, record] of block.entries()) {
      const marks = [
        record.isCompactSummary ? "isCompactSummary" : null,
        record.isMeta ? "isMeta" : null,
      ].filter(Boolean);
      const summary = record.type === "system"
        ? brief(record.compactMetadata, 260)
        : textOf(record).slice(0, 90).replace(/\n/g, " ");
      console.log(`    ${at + offset}  ${record.type}${record.subtype ? `/${record.subtype}` : ""}` +
        `${marks.length ? ` [${marks.join(", ")}]` : ""}  ${summary}`);
    }

    const metadata = block[0]?.compactMetadata ?? {};
    check(metadata.trigger === "manual", `compactMetadata.trigger is manual (saw ${metadata.trigger})`);
    check(typeof metadata.preTokens === "number", `compactMetadata.preTokens is a number (${metadata.preTokens})`);
    check(typeof metadata.postTokens === "number", `compactMetadata.postTokens is a number (${metadata.postTokens})`);

    check(
      block[1]?.type === "user" && block[1]?.isCompactSummary === true,
      "the record after the boundary is the user record carrying the summary",
    );
    check(
      block[2]?.type === "user" && block[2]?.isMeta === true,
      "then the isMeta caveat",
    );
    check(
      block[3]?.type === "user" && textOf(block[3]).includes("<command-name>/compact</command-name>"),
      "then the user turn holding the typed /compact",
    );
    const stdoutAt = records.findIndex(
      (r, index) => index > at && r.type === "user" && textOf(r).includes("<local-command-stdout>"),
    );
    check(
      stdoutAt === at + 4,
      `then the <local-command-stdout> turn (found at ${stdoutAt >= 0 ? stdoutAt : "nowhere"}, expected ${at + 4})`,
    );

    const promptAt = records.findIndex(
      (r, index) => index > stdoutAt && r.type === "user" && textOf(r).includes("Reply with just: ok."),
    );
    const relisted = records.findIndex(
      (r, index) => index > stdoutAt && r.type === "attachment" && r.attachment?.type === "skill_listing",
    );
    check(
      stdoutAt >= 0 && relisted > stdoutAt && (promptAt < 0 || relisted < promptAt),
      `a skill_listing attachment follows the block, before the next prompt (at ${relisted}, prompt at ${promptAt})`,
    );

    // What the compacted conversation is: the summary, then the newest reply
    // from before the boundary, kept as it was. The boundary names it twice,
    // as `logicalParentUuid` and in `preservedMessages`.
    const summaryText = textOf(block[1]);
    const kept: string[] = metadata.preservedMessages?.uuids ?? [];
    const newest = records.slice(0, at).filter((r) => r.type === "assistant" && !r.isSidechain).at(-1);
    const keptRecords = records.slice(0, at).filter((r) => kept.includes(r.uuid));
    console.log(
      `  summary: ${summaryText.length} chars; kept verbatim: ${kept.length} record(s), ` +
        `${keptRecords.map((r) => JSON.stringify(r.message?.content ?? "").length).join(" + ")} chars`,
    );
    check(
      kept.length > 0 &&
        keptRecords.length === kept.length &&
        keptRecords.every((r) => r.type === "assistant" && r.message?.id === newest?.message?.id) &&
        block[0]?.logicalParentUuid === newest?.uuid,
      `the boundary keeps the newest reply from before it, and only that (${kept.length} uuid(s))`,
    );
    check(
      summaryText.includes("kept verbatim") && summaryText.includes("written without seeing them"),
      "the summary says the messages after it were kept verbatim and not seen by it",
    );
    // 2.1.311: a reply with no <summary> block is asked for once more, so a
    // compaction that succeeds always carries one, drawn as `Summary:`.
    check(/\nSummary:\n/.test(summaryText), "the summary holds a Summary: section");

    // The next request sends exactly that: the summary, then the kept reply.
    const blobs = records.slice(at).filter((r) => r.type === "api-request-blob");
    const summaryBlob = blobs.findIndex(
      (b) => b.message?.role === "user" && textOf(b).startsWith("This session is being continued"),
    );
    const keptText = keptRecords.map(textOf).join("");
    const keptBlob = blobs.findIndex((b) => b.message?.role === "assistant" && keptText.length > 0 && textOf(b) === keptText);
    check(
      summaryBlob >= 0 && keptBlob > summaryBlob,
      `the next request sends the summary, then the kept reply word for word (blobs ${summaryBlob}, ${keptBlob})`,
    );

    // What makes the whole run drawable as one divider: nothing the pane would
    // render as a turn of its own sits inside it.
    const inside = records
      .slice(at, stdoutAt >= 0 ? stdoutAt : at + 5)
      .filter((r) => r.type === "assistant");
    check(inside.length === 0, `no assistant record sits between the boundary and the stdout record (saw ${inside.length})`);

    // --------------------------------------------------------- the badge

    const after = records.find(
      (r, index) =>
        index > at &&
        r.type === "assistant" &&
        !r.isSidechain &&
        r.message?.model !== "<synthetic>" &&
        usageOf(r) > 0,
    );
    const badge = after ? usageOf(after) : 0;

    // What a session pays before it has said anything: its first turn is the
    // system prompt, the tool schemas and one line of typing. The badge can
    // never go below this, whatever compaction does, which is the whole of why
    // `postTokens` and the badge are not the same number.
    const opening = records.find((r) => r.type === "assistant" && usageOf(r) > 0);
    const floor = opening ? usageOf(opening) : 0;

    console.log(
      `\n  the CLI's own pair: preTokens ${metadata.preTokens} → postTokens ${metadata.postTokens}` +
        `\n  the badge's pair:   ${preContext} → ${badge}` +
        `\n  the session's floor (its first assistant turn): ${floor}` +
        `\n  badge − postTokens = ${badge - metadata.postTokens}, which is the floor the CLI's count leaves out`,
    );
    check(after !== undefined, "there is an assistant turn after the boundary to read a badge from");
    // Haiku sometimes answers the fill with a bare list, and then there is too
    // little to drop for the drop below to mean anything.
    check(
      preContext - floor >= 4_000,
      `the fill put at least 4k of conversation above the floor (${preContext - floor})`,
    );
    check(
      metadata.postTokens * 3 < metadata.preTokens,
      `the CLI's own two numbers show the cliff (${metadata.postTokens} against ${metadata.preTokens})`,
    );
    // Asserted as measured, not as hoped. The badge is *not* within 3x of
    // postTokens — it was 9x on the run this was written against — because the
    // system prompt and tool schemas ride on the real request and not on the
    // CLI's count. The app shows postTokens after a boundary anyway, marked
    // `~` as an estimate, because at 500k the floor is noise and a badge that
    // waited for the next turn sat at the pre-compaction size indefinitely.
    check(
      badge > metadata.postTokens,
      `the badge reads higher than postTokens, so postTokens is not the badge (${badge} vs ${metadata.postTokens})`,
    );
    check(
      badge > 0 && badge <= floor + metadata.postTokens * 3,
      `the compacted turn carries no more than the floor plus a few times the summary` +
        ` (${badge} against ${floor} + 3 × ${metadata.postTokens})`,
    );
    check(
      badge < preContext,
      `and less than the turn before compaction (${badge} vs ${preContext})`,
    );
  }
}

// ------------------------------------------------- a resume told to compact

// The app counts a resume as up when it hears `system/init`. Told `/compact`
// first, a resumed session says `compacting` at once and `init` only when the
// compaction is over, which on a full window ran past the app's 90s patience.
// The host announces a resume on its first message of any kind for this.
console.log("\na resumed session whose first prompt is /compact");
{
  async function* once(text: string): AsyncGenerator<any> {
    yield { type: "user", message: { role: "user", content: text }, parent_tool_use_id: null };
  }
  const options = {
    cwd: scratch,
    model: "haiku",
    systemPrompt: { type: "preset", preset: "claude_code" },
    permissionMode: "bypassPermissions",
    settingSources: [],
  } as any;
  let resumeId: string | null = null;
  for (const prompt of [
    "List 30 kinds of fruit, two sentences each. No tools.",
    "Now 20 vegetables, two sentences each. No tools.",
    "Name one bread, in one sentence. No tools.",
  ]) {
    for await (const message of query({ prompt: once(prompt), options: { ...options, ...(resumeId ? { resume: resumeId } : {}) } }) as AsyncIterable<any>) {
      if (message.type === "system" && message.subtype === "init") resumeId ??= message.session_id;
    }
  }
  check(resumeId !== null, `the session to resume has an id (${resumeId})`);

  const said: any[] = [];
  if (resumeId) {
    for await (const message of query({ prompt: once("/compact"), options: { ...options, resume: resumeId } }) as AsyncIterable<any>) {
      said.push(message);
    }
  }
  console.log(`  sequence: ${said.map(label).join(" → ") || "nothing at all"}`);
  const compactingAt = said.findIndex((m) => m.type === "system" && m.subtype === "status" && m.status === "compacting");
  const initAt = said.findIndex((m) => m.type === "system" && m.subtype === "init");
  const boundaryAt = said.findIndex((m) => m.type === "system" && m.subtype === "compact_boundary");
  check(compactingAt === 0, `compacting is the first thing it says (at ${compactingAt})`);
  check(
    initAt > compactingAt && (boundaryAt < 0 || initAt < boundaryAt),
    `init comes only after the compaction, before the boundary (init at ${initAt}, boundary at ${boundaryAt})`,
  );
  check(initAt < 0 || said[initAt].session_id === resumeId, "and names the resumed id, which the host announces early");
}

rmSync(scratch, { recursive: true, force: true });

console.log(
  failures.length === 0
    ? "\ncompaction-probe: all checks passed"
    : `\ncompaction-probe: ${failures.length} check(s) failed\n  - ${failures.join("\n  - ")}`,
);
process.exit(failures.length === 0 ? 0 : 1);
