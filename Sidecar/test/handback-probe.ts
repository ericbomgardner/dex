/**
 * Where a subagent's report goes, now that it is a message rather than a result.
 *
 *   node test/handback-probe.ts
 *
 * Since CLI v2.1.278 an agent hands its report back through a `SubagentHandback`
 * tool call, and the parent's `Agent` result is a stub that says so. The report
 * itself arrives at the parent as a *peer message*, the same door another
 * session's `SendMessage` comes through — a different wrapper, a different
 * origin, and a frame around the body. The app reads all of that (`RawOrigin`,
 * `peerMessage(unwrapping:)`, `TranscriptText.handbackReport`,
 * `ToolCall.isHandback`), and until this probe existed the whole reading was
 * three delegations from one session on one afternoon.
 *
 * What is pinned, and what each one holds up:
 *
 *  1. The stub. `toolUseResult` still carries `agentId` and the three counts
 *     beside a new `handback: "send"`, so the tally and the settling were never
 *     touched — the pane's counts come from there, not from the text.
 *  2. The delivery. `origin` is `{kind: "peer", from, senderTaskId, name,
 *     body, handback: true}`, where `name` is the agent's type, not a
 *     messaging name (CLI 2.1.286; absent before), and the wrapper is
 *     `<agent-message from="…">`, not `<cross-session-message>`. Both of those
 *     broke something quietly: a card headed *from another session*, and an
 *     enqueue counted in `heard` as something you typed.
 *  3. The frame. The body opens `[Subagent hand-back] … The report follows:`
 *     and indents the report two spaces, which is what `handbackReport` strips.
 *  4. The agent's own file ends on the call: `tool_use: SubagentHandback` with
 *     the report under `input.message`, answered `{"success":true,…}`.
 *  5. A background agent's `<task-notification>` is unchanged — the tagged
 *     `<usage>` is still there, with the stub under `<result>`.
 *
 * Four runs, because the shape depends on what the parent was doing, and on
 * what the agent did.
 *
 *   foreground — `run_in_background: false`. Measures the stub and the counts,
 *     and the agent's own file, on the door a blocking delegation takes.
 *   background, busy — the parent launches and then sits in a long `ping`, so
 *     both the report and the `<task-notification>` are absorbed into the
 *     running call: `enqueue`, a `queued_command` attachment, `remove` with
 *     `absorbed_mid_turn`. A bare `sleep` is refused by the CLI, which is why
 *     the busy command is a ping, and the run is only read if the send landed
 *     inside it.
 *   background, idle — the parent ends its turn before the agent is back. This
 *     door was never measured; by the cross-session reading it should be an
 *     `isMeta` user turn carrying the same `origin` at the record's top level.
 *     It is printed as a finding, and only what holds either way is asserted:
 *     origin fields, wrapper, frame.
 *   interim — the agent puts its own command in the background and ends its
 *     turn. Since CLI v2.1.299 the parent hears twice: a `completed` notice
 *     naming the call whose `<note>` says the result "may be interim", then,
 *     when the agent is really done, one with the whole run's tally that names
 *     only the task. `bringAgentsBack` joins the second to the call through
 *     the first; this is the shape it relies on.
 *
 * The agents run on haiku and are asked for one line, since what is being read
 * is the plumbing and not the work. Read off disk rather than the stream: a
 * subagent's own turns reach the stream only under `forwardSubagentText`, and
 * the queue records exist nowhere else. Scratch cwd, so a CLAUDE.md above it
 * doesn't talk the session out of delegating.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-handback-"));
const LIMIT_MS = 300_000;
/** How long to keep an idle parent's session open after its agent comes back. */
const AFTER_NOTICE_MS = 30_000;
/** Seconds of ping. Long enough that a haiku one-liner reports inside it. */
const BUSY_PINGS = 60;
/** Seconds the idle run's agent is made to take, so the parent's turn ends first. */
const SLOW_AGENT_PINGS = 45;
/** Seconds of the interim run's agent's own background command. */
const INTERIM_PINGS = 25;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The CLI the SDK actually runs, which is not the one on PATH. */
function bundledCLI(): string | null {
  const require = createRequire(import.meta.url);
  try {
    const manifest = require.resolve(
      `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}/package.json`,
    );
    const binary = path.join(path.dirname(manifest), "claude");
    return existsSync(binary) ? binary : null;
  } catch {
    return null;
  }
}

function cliVersion(): string {
  const binary = bundledCLI();
  if (!binary) return "not found";
  try {
    return execFileSync(binary, ["--version"], { encoding: "utf8" }).trim();
  } catch {
    return "would not answer";
  }
}

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

function transcriptFor(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** The transcript trails the turn that ended it, so wait for it to stop growing. */
async function settled(files: string[], quietMs = 8_000, capMs = 60_000): Promise<void> {
  const until = Date.now() + capMs;
  let total = -1;
  let still = 0;

  while (Date.now() < until) {
    const now = files.filter((f) => existsSync(f)).reduce((sum, f) => sum + statSync(f).size, 0);
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

function blocks(record: any): any[] {
  const content = record?.message?.content;
  return Array.isArray(content) ? content : [];
}

function toolUses(record: any, name?: string): any[] {
  return blocks(record).filter(
    (b) => b?.type === "tool_use" && (name === undefined || b?.name === name),
  );
}

/** A tool_result's text, whichever of the two content shapes it came in. */
function resultText(block: any): string {
  const content = block?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c) => (typeof c === "string" ? c : (c?.text ?? ""))).join("\n");
  }
  return "";
}

function originOf(record: any): any {
  return record?.origin ?? record?.attachment?.origin ?? record?.message?.origin ?? null;
}

/** Whatever text a record put in front of the model, for wrapper matching. */
function shownText(record: any): string {
  if (record?.type === "attachment") {
    const attachment = record.attachment;
    return String(attachment?.prompt ?? attachment?.content ?? "");
  }
  if (record?.type === "queue-operation") return String(record.content ?? "");
  const content = record?.message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((c) => c?.text ?? "").join("\n");
  return "";
}

function shape(record: any): string {
  if (!record) return "none";
  if (record.type === "queue-operation") return `queue-operation/${record.operation}`;
  if (record.type === "attachment") return `attachment/${record.attachment?.type}`;
  return `${record.type}${record.message?.role ? `/${record.message.role}` : ""}`;
}

function trim(text: string, n = 160): string {
  const flat = text.replace(/\n/g, "\\n");
  return flat.length > n ? `${flat.slice(0, n)}…(${flat.length} chars)` : flat;
}

interface Run {
  label: string;
  sessionId: string | null;
  events: string[];
  taskIds: string[];
  results: number[];
  noticeAt: number | null;
  notices: number;
  turnAfterNotice: boolean;
}

/**
 * One session, driven to the end of what it is being measured for.
 *
 * `holdForTask` is the difference between the doors: a busy parent is read at
 * its turn's result, an idle one has to be kept open past it, because
 * backgrounding is precisely what lets the turn end while the agent runs on.
 */
async function drive(label: string, ask: string, holdForTask: boolean, noticesToHoldFor = 1): Promise<Run> {
  const run: Run = {
    label,
    sessionId: null,
    events: [],
    taskIds: [],
    results: [],
    noticeAt: null,
    notices: 0,
    turnAfterNotice: false,
  };

  const input = heldOpen(ask);
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "auto",
      // The hand-back is an auto-mode change ("Changed auto mode so a subagent
      // reports back … through a dedicated hand-back call"), and under
      // bypassPermissions the report still comes back in the result. A probe
      // run in the wrong mode measures the old shape and calls the reading
      // gone. `canUseTool` allows everything so an ask cannot park a headless
      // session; auto is the mode, not the answering.
      canUseTool: async (_name: string, input: unknown) => ({
        behavior: "allow",
        updatedInput: input,
      }),
    } as any,
  });

  const stop = () => {
    input.close();
    session.close?.();
  };
  const deadline = setTimeout(stop, LIMIT_MS);
  let afterNotice: NodeJS.Timeout | null = null;

  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.session_id && !run.sessionId) run.sessionId = message.session_id;
      const subtype: string | undefined = message.subtype;

      if (typeof subtype === "string" && subtype.startsWith("task")) {
        run.events.push(`${subtype}${message.status ? `/${message.status}` : ""}`);
        if (subtype === "task_started" && message.task_id) run.taskIds.push(message.task_id);
        // Only the agent's own: the interim run's agent has a task of its own
        // whose notice reaches this stream too.
        if (subtype === "task_notification" && message.task_id === run.taskIds[0]) {
          run.noticeAt ??= Date.now();
          run.notices += 1;
          // Held open past the notification, not past the turn: an idle parent
          // may run a turn of its own on the report, and that is the reading.
          if (holdForTask && run.notices === noticesToHoldFor) afterNotice = setTimeout(stop, AFTER_NOTICE_MS);
        }
      }

      if (message.type === "result") {
        run.events.push("result");
        run.results.push(Date.now());
        if (run.noticeAt !== null) run.turnAfterNotice = true;
        if (!holdForTask) break;
      }
    }
  } finally {
    clearTimeout(deadline);
    if (afterNotice) clearTimeout(afterNotice);
    stop();
  }

  return run;
}

interface Read {
  parent: any[];
  agentCall: any | null;
  stub: string;
  toolUseResult: any;
  delivery: any[];
  enqueue: any | null;
  shown: any | null;
  removal: any | null;
  origin: any;
  notice: any | null;
  noticeText: string;
  agentFile: string | null;
  agentRecords: any[];
  handbackCall: any | null;
  handbackResult: string | null;
}

/** Everything the run left on disk, joined by the agent id the receipt names. */
async function readBack(run: Run, marker: string): Promise<Read | null> {
  if (!run.sessionId) return null;
  const parentFile = transcriptFor(run.sessionId);
  if (!parentFile) return null;

  const directory = path.join(path.dirname(parentFile), run.sessionId, "subagents");
  const names = existsSync(directory)
    ? readdirSync(directory).filter((n) => n.startsWith("agent-") && n.endsWith(".jsonl"))
    : [];
  await settled([parentFile, ...names.map((n) => path.join(directory, n))]);

  const parent = records(parentFile);
  const agentCall = parent.flatMap((r) => toolUses(r, "Agent"))[0] ?? null;

  const resultRecord = agentCall
    ? parent.find((r) =>
        blocks(r).some((b) => b?.type === "tool_result" && b?.tool_use_id === agentCall.id),
      )
    : null;
  const resultBlock = resultRecord
    ? blocks(resultRecord).find((b) => b?.type === "tool_result" && b?.tool_use_id === agentCall.id)
    : null;
  const stub = resultBlock ? resultText(resultBlock) : "";
  const toolUseResult = resultRecord?.toolUseResult ?? null;

  const agentId: string | null =
    (typeof toolUseResult?.agentId === "string" ? toolUseResult.agentId : null) ??
    /agentId:\s*([A-Za-z0-9_-]+)/.exec(stub)?.[1] ??
    null;

  // The delivery is found by the wrapper and by the origin, never by the marker
  // alone: the parent quotes its agent's line back in its own turn, and that is
  // not a delivery.
  const delivery = parent.filter((r) => {
    if (originOf(r)?.handback === true) return true;
    return shownText(r).includes("<agent-message");
  });

  const enqueue = delivery.find((r) => r.type === "queue-operation" && r.operation === "enqueue") ?? null;
  const front =
    delivery.find((r) => r.type === "attachment" || (r.type === "user" && originOf(r))) ?? null;
  // Matched on the wrapper, not on the reason: a background agent's
  // `<task-notification>` is removed with `absorbed_mid_turn` too, and taking
  // that one would report the report as absorbed when it never arrived.
  const removal =
    parent.find(
      (r) =>
        r.type === "queue-operation" &&
        r.operation === "remove" &&
        String(r.content ?? "").includes("<agent-message"),
    ) ?? null;

  const notice =
    parent.find((r) => {
      const raw = JSON.stringify(r);
      return raw.includes("<task-notification>") && (!agentId || raw.includes(agentId));
    }) ?? null;
  const noticeText = notice ? shownText(notice) || JSON.stringify(notice) : "";

  const agentFile = agentId ? path.join(directory, `agent-${agentId}.jsonl`) : null;
  const agentRecords = agentFile && existsSync(agentFile) ? records(agentFile) : [];
  const handbackCall = agentRecords.flatMap((r) => toolUses(r, "SubagentHandback")).at(-1) ?? null;
  const handbackResultBlock = handbackCall
    ? agentRecords
        .flatMap((r) => blocks(r))
        .find((b) => b?.type === "tool_result" && b?.tool_use_id === handbackCall.id)
    : null;

  return {
    parent,
    agentCall,
    stub,
    toolUseResult,
    delivery,
    enqueue,
    shown: front,
    removal,
    origin: front ? originOf(front) : (enqueue ? originOf(enqueue) : null),
    notice,
    noticeText,
    agentFile,
    agentRecords,
    handbackCall,
    handbackResult: handbackResultBlock ? resultText(handbackResultBlock) : null,
  };
}

const failures: string[] = [];
function check(held: unknown, description: string): void {
  console.log(`${held ? "  ok" : "FAIL"}  ${description}`);
  if (!held) failures.push(description);
}

/** The frame the CLI puts round the report, and the indent it argues for. */
function frame(body: string, marker: string): { opens: boolean; follows: boolean; harness: string | null; indented: boolean } {
  const lines = body.split("\n");
  const first = lines[0] ?? "";
  const harness = lines.slice(1, 3).find((l) => l.trimStart().startsWith("[harness:")) ?? null;
  const reportLine = lines.find((l) => l.includes(marker)) ?? "";
  return {
    opens: first.startsWith("[Subagent hand-back]"),
    follows: first.trimEnd().endsWith("The report follows:"),
    harness,
    indented: reportLine.startsWith("  "),
  };
}

/** Asserted on both doors, since only the record carrying it differs. */
function checkPeerOrigin(read: Read, marker: string, agentId: string | null): void {
  const origin = read.origin;
  check(origin?.kind === "peer", "the report's origin is a peer message");
  check(
    typeof origin?.from === "string" && (!agentId || origin.from === agentId),
    "origin.from is the agent id",
  );
  check(
    typeof origin?.senderTaskId === "string" && origin.senderTaskId === origin.from,
    "origin.senderTaskId is the same id",
  );
  check(origin?.handback === true, "origin.handback marks it as a hand-back");
  check(
    origin?.name === "general-purpose",
    "and its name is the agent's type, so the id is still all that tells two agents apart",
  );
  check(typeof origin?.body === "string" && origin.body.includes(marker), "origin.body holds the report");

  const wrapper = /<agent-message([^>]*)>/.exec(shownText(read.shown) || shownText(read.enqueue));
  check(wrapper !== null, "the text is wrapped in <agent-message …>, not <cross-session-message>");
  check(
    wrapper !== null && (!agentId || wrapper[1].includes(agentId)),
    "and the wrapper names the agent it came from",
  );

  const framed = frame(String(origin?.body ?? ""), marker);
  check(framed.opens, "the body opens [Subagent hand-back]");
  check(framed.follows, "its first line ends 'The report follows:'");
  check(framed.indented, "and the report itself is indented two spaces");
  console.log(`  note  [harness: …] line: ${framed.harness ? JSON.stringify(trim(framed.harness, 100)) : "absent"}`);
  console.log(`  note  origin.flagged: ${"flagged" in (read.origin ?? {}) ? JSON.stringify(read.origin.flagged) : "absent"}`);
}

function describe(read: Read): void {
  console.log(`  shape: delivery records — ${read.delivery.map(shape).join(", ") || "none"}`);
  console.log(`  shape: enqueue content ${read.enqueue ? JSON.stringify(trim(String(read.enqueue.content), 120)) : "none"}`);
  console.log(`  shape: shown as ${shape(read.shown)}`);
  if (read.shown?.type === "attachment") {
    const a = read.shown.attachment;
    console.log(`  shape: commandMode=${a?.commandMode} isMeta=${a?.isMeta ?? read.shown.isMeta ?? "absent"}`);
  } else if (read.shown) {
    const content = read.shown.message?.content;
    console.log(
      `  shape: isMeta=${read.shown.isMeta ?? "absent"} content is ${typeof content === "string" ? "a plain string" : "blocks"}`,
    );
    console.log(
      `  shape: promptSource=${read.shown.promptSource ?? "absent"} turnOrigin=${read.shown.turnOrigin ?? "absent"}` +
        ` queueSkipAttachments=${read.shown.queueSkipAttachments ?? "absent"}`,
    );
  }
  const text = shownText(read.shown);
  const lead = text.slice(0, Math.max(0, text.indexOf("<agent-message")));
  console.log(`  shape: text before the wrapper ${lead ? JSON.stringify(trim(lead, 120)) : "none"}`);
  console.log(`  shape: origin sits at ${read.shown?.origin ? "the record's top level" : read.shown?.attachment?.origin ? "attachment.origin" : read.shown?.message?.origin ? "message.origin" : "nowhere on the shown record"}`);
  console.log(`  shape: removal ${read.removal ? `reason=${read.removal.reason}` : "none"}`);
  console.log(`  shape: origin ${JSON.stringify(read.origin)?.slice(0, 400) ?? "none"}`);
}

console.log(`handback-probe — CLI ${cliVersion()}`);
console.log(`  cwd: ${scratch}`);

function agentTask(marker: string, slow = false): string {
  // The idle door only exists if the parent gets to the end of its turn first,
  // and a haiku one-liner beats it there — the first run had the notification
  // ahead of the result. So the idle run's agent is made to take its time, and
  // with a ping rather than a sleep, which the CLI refuses on its own.
  // In the foreground, and said twice: backgrounded, the agent's own turn ends
  // at once and the CLI notifies the parent that the agent "has not reported
  // yet", which is a third shape and not the one being measured.
  const wait = slow
    ? "First use the Bash tool exactly once, with run_in_background: false, and this exact " +
      `command: ping -c ${SLOW_AGENT_PINGS} -i 1 127.0.0.1 > /dev/null. Wait for it to finish — ` +
      "do not background it and do not report until it has returned. Then "
    : "";
  return (
    `${wait}report exactly this one line and nothing else, ` +
    `with no preamble: ${marker}`
  );
}

function delegation(
  marker: string,
  background: boolean,
  description: string,
  slow = false,
): string {
  return (
    "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
    `model 'haiku', description '${description}', run_in_background: ${background}, ` +
    `and give it this whole task: ${agentTask(marker, slow)}`
  );
}

try {
  // ---- 1. a foreground delegation ------------------------------------------
  const FG = `HANDBACK-FG-${randomBytes(3).toString("hex").toUpperCase()}`;
  console.log("\n--- a foreground delegation ---");
  const fgRun = await drive(
    "foreground",
    `${delegation(FG, false, "handback fg")}. Then say done. Do not use any other tool.`,
    false,
  );
  console.log(`  session: ${fgRun.sessionId ?? "never announced"}`);
  console.log(`  task events: ${fgRun.events.join(" → ") || "none"}`);

  const fg = await readBack(fgRun, FG);
  if (!fg || !fg.agentCall) {
    check(false, "the foreground run delegated and wrote a transcript");
  } else {
    const agentId: string | null = fg.toolUseResult?.agentId ?? null;
    console.log(`  agent: ${agentId ?? "not named"}  (${fg.agentRecords.length} records in its own file)`);
    console.log(`  stub: ${JSON.stringify(trim(fg.stub, 300))}`);

    check(fg.stub.includes("SubagentHandback"), "the Agent result is a stub naming SubagentHandback");
    check(
      fg.stub.includes("Read it there; it is not repeated here"),
      "and says the report is not repeated there",
    );
    check(typeof fg.toolUseResult?.agentId === "string", "toolUseResult still carries agentId");
    check(typeof fg.toolUseResult?.totalToolUseCount === "number", "and totalToolUseCount");
    check(typeof fg.toolUseResult?.totalTokens === "number", "and totalTokens");
    check(typeof fg.toolUseResult?.totalDurationMs === "number", "and totalDurationMs");
    check(fg.toolUseResult?.handback === "send", 'beside the new handback: "send"');

    describe(fg);
    checkPeerOrigin(fg, FG, agentId);

    // 4. the agent's own file ends on the call it reported through.
    check(fg.handbackCall !== null, "the agent's own file holds a SubagentHandback tool_use");
    check(
      typeof fg.handbackCall?.input?.message === "string" && fg.handbackCall.input.message.includes(FG),
      "with the report under input.message",
    );
    let answered: any = null;
    try {
      answered = JSON.parse(String(fg.handbackResult ?? "").trim());
    } catch {
      answered = null;
    }
    check(answered?.success === true, "answered by a tool_result parsing as JSON with success: true");
    console.log(`  note  hand-back result: ${JSON.stringify(trim(String(fg.handbackResult ?? "none"), 200))}`);
  }

  // ---- 2. a background delegation to a parent busy in a tool call -----------
  const BG = `HANDBACK-BG-${randomBytes(3).toString("hex").toUpperCase()}`;
  console.log("\n--- a background delegation, parent busy in a tool call ---");
  const busyRun = await drive(
    "busy",
    `${delegation(BG, true, "handback busy")}. ` +
      "Immediately after launching it, and without waiting for it, use the Bash tool " +
      `exactly once with this exact command: ping -c ${BUSY_PINGS} -i 1 127.0.0.1 > /dev/null. ` +
      "Then say done. Do not use any other tool.",
    false,
  );
  console.log(`  session: ${busyRun.sessionId ?? "never announced"}`);
  console.log(`  task events: ${busyRun.events.join(" → ") || "none"}`);

  const busy = await readBack(busyRun, BG);
  if (!busy || !busy.agentCall) {
    check(false, "the busy run delegated and wrote a transcript");
  } else {
    const agentId: string | null = busy.toolUseResult?.agentId ?? null;
    console.log(`  agent: ${agentId ?? "not named"}`);
    describe(busy);

    // Setup, not reading: a report that landed after the ping finished measures
    // the idle door under the busy run's name, so the run is refused rather
    // than read — a timing miss must not look like the shape moving.
    if (busy.shown?.type !== "attachment") {
      check(
        false,
        "SETUP: the report was not absorbed into the running call — it landed after the ping finished; re-run before reading this as a change",
      );
    } else {
    check(busy.enqueue !== null, "it arrives as a queue-operation enqueue");
    check(
      String(busy.enqueue?.content ?? "").trimStart().startsWith("<agent-message from="),
      "whose content opens with the <agent-message from=…> wrapper",
    );
    check(busy.shown?.attachment?.type === "queued_command", "shown as a queued_command attachment");
    check(busy.shown?.attachment?.commandMode === "prompt", 'under commandMode "prompt"');
    check(
      (busy.shown?.attachment?.isMeta ?? busy.shown?.isMeta) === true,
      "marked isMeta",
    );
    check(busy.removal?.reason === "absorbed_mid_turn", "and removed with reason absorbed_mid_turn");

    checkPeerOrigin(busy, BG, agentId);

    // 5. the notification, which is what settles the call, is untouched.
    console.log(`  notice: ${shape(busy.notice)} ${JSON.stringify(trim(busy.noticeText, 300))}`);
    check(busy.notice !== null, "the background agent still writes a <task-notification>");
    for (const tag of ["<subagent_tokens>", "<tool_uses>", "<duration_ms>"]) {
      check(busy.noticeText.includes(tag), `its <usage> still carries ${tag}`);
    }
    check(
      /<result>[\s\S]*SubagentHandback[\s\S]*<\/result>/.test(busy.noticeText),
      "and its <result> holds the same stub",
    );
    }
  }

  // ---- 3. a background delegation to a parent that has gone idle ------------
  const IDLE = `HANDBACK-IDLE-${randomBytes(3).toString("hex").toUpperCase()}`;
  console.log("\n--- a background delegation, parent idle when the agent reports ---");
  const idleRun = await drive(
    "idle",
    `${delegation(IDLE, true, "handback idle", true)}. ` +
      "Then say launched. Do not wait for that agent, do not check on it, " +
      "and do not use any other tool.",
    true,
  );
  console.log(`  session: ${idleRun.sessionId ?? "never announced"}`);
  console.log(`  task events: ${idleRun.events.join(" → ") || "none"}`);
  console.log(
    `  the turn ended ${
      idleRun.noticeAt && idleRun.results.length
        ? `${Math.round((idleRun.noticeAt - idleRun.results[0]) / 1000)}s before the agent came back`
        : "— timings unavailable"
    }`,
  );
  console.log(`  a turn ran after the notification: ${idleRun.turnAfterNotice}`);

  const idle = await readBack(idleRun, IDLE);
  if (!idle || !idle.agentCall) {
    check(false, "the idle run delegated and wrote a transcript");
  } else {
    const agentId: string | null = idle.toolUseResult?.agentId ?? null;
    console.log(`  agent: ${agentId ?? "not named"}`);

    // Setup, not reading, and both halves have been wrong in a run: the parent's
    // turn has to end first, and the agent has to have reported at all — one
    // that backgrounds its own work ends its turn early and the CLI notifies
    // the parent that it "has not reported yet", which is a third shape.
    check(
      idleRun.results.length > 0 && idleRun.noticeAt !== null && idleRun.results[0] < idleRun.noticeAt,
      "the parent's turn ended before the agent reported, so this is the idle door",
    );
    check(
      idle.handbackCall !== null,
      "the agent reported through SubagentHandback rather than ending its turn early",
    );
    if (!idle.handbackCall) console.log(`  notice: ${trim(idle.noticeText, 400)}`);

    console.log("\n  FINDING — the idle door, previously unmeasured:");
    describe(idle);
    const front = idle.shown;
    console.log(
      `  shape: the parent ${idleRun.turnAfterNotice ? "ran a turn of its own on the report" : "ran no turn on the report"}`,
    );
      console.log(
      `  shape: records after the report: ${
        front
          ? idle.parent.slice(idle.parent.indexOf(front) + 1).map(shape).slice(0, 8).join(", ") || "none"
          : "the report was never found"
      }`,
    );

    // The idle door's own shape, which the busy door does not have: the
    // report is a user turn, not an attachment, and the parent acts on it.
    check(idle.shown?.type === "user", "the report is written as a user record");
    check(idle.shown?.isMeta === true, "marked isMeta on the record itself");
    check(typeof idle.shown?.message?.content === "string", "with plain-string content, not blocks");
    check(idle.shown?.origin != null, "origin sits at the record's top level");
    check(idle.shown?.turnOrigin === "peer", 'and the record says turnOrigin "peer"');
    check(
      shownText(idle.shown).startsWith("Another Claude session sent a message:"),
      "the CLI's peer preamble sits ahead of the wrapper",
    );
    check(idle.removal === null, "nothing is absorbed, so there is no remove");
    check(idleRun.turnAfterNotice, "and the parent ran a turn of its own on the report");

    checkPeerOrigin(idle, IDLE, agentId);
  }

  // ---- 4. an agent that backgrounds its own work -----------------------------
  const INTERIM = `HANDBACK-INTERIM-${randomBytes(3).toString("hex").toUpperCase()}`;
  console.log("\n--- a background agent that backgrounds its own work ---");
  const interimRun = await drive(
    "interim",
    "Use the Agent tool exactly once, with subagent_type 'general-purpose', model 'haiku', " +
      "description 'handback interim', run_in_background: true, and give it this whole task: " +
      "Use the Bash tool exactly once, with run_in_background: true and this exact command: " +
      `ping -c ${INTERIM_PINGS} -i 1 127.0.0.1 > /dev/null. End your turn at once without waiting for it. ` +
      `When you are told it finished, report exactly this one line and nothing else: ${INTERIM}. ` +
      "-- Then say launched. Do not wait for that agent and do not use any other tool.",
    true,
    2,
  );
  console.log(`  session: ${interimRun.sessionId ?? "never announced"}`);
  console.log(`  task events: ${interimRun.events.join(" → ") || "none"}`);

  const interim = await readBack(interimRun, INTERIM);
  const taskId = interimRun.taskIds[0];
  if (!interim || !interim.agentCall || !taskId) {
    check(false, "the interim run delegated and wrote a transcript");
  } else {
    // Each notice once, from the records that carry it into the conversation:
    // a queue-operation repeats it, and since 2.1.300 so does a request blob.
    const notices = interim.parent
      .filter((r) => r.type === "user" || (r.type === "attachment" && r.attachment?.commandMode === "task-notification"))
      .flatMap((r) => shownText(r).match(/<task-notification>[\s\S]*?<\/task-notification>/g) ?? [])
      .filter((n) => n.includes(`<task-id>${taskId}</task-id>`));
    const field = (tag: string, text: string) =>
      new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(text)?.[1]?.trim() ?? null;
    for (const n of notices) {
      console.log(`  notice: ${JSON.stringify(trim(n.replace(/<output-file>[\s\S]*?<\/output-file>\n?/, ""), 600))}`);
    }

    const [first, last] = [notices[0] ?? "", notices.at(-1) ?? ""];
    check(notices.length >= 2, `the agent's task notified more than once (${notices.length})`);
    check(field("tool-use-id", first) === interim.agentCall.id, "the first notice names the call");
    check(field("status", first) === "completed", "and says completed");
    check((field("note", first) ?? "").includes("interim"), "and its <note> says the result may be interim");
    check(notices.length >= 2 && field("tool-use-id", last) === null, "the last notice names no call");
    check(field("task-id", last) === taskId, "only the same task");
    check(field("status", last) === "completed", "says completed");
    check(!(field("note", last) ?? "").includes("interim"), "and is not interim");
    const uses = (text: string) => Number(field("tool_uses", text) ?? NaN);
    check(uses(last) > uses(first), `and its tally covers the whole run (${uses(first)} then ${uses(last)} tool uses)`);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nhandback: FAIL — ${failures.length} check(s) failed:\n${failures.map((f) => `  - ${f}`).join("\n")}`
    : "\nhandback: PASS — all checks passed",
);
process.exit(failures.length ? 1 : 0);
