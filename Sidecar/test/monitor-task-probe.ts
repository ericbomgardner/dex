/**
 * What the CLI's `Monitor` tool leaves behind — a background task that can
 * outlive its turn by a quarter of an hour, and settles by nothing the
 * transcript writes.
 *
 *   node test/monitor-task-probe.ts
 *
 * A real session armed `Monitor` on `tail -f <log> | grep …` with a 900000ms
 * timeout. The turn ended, the CLI's own registry said `idle`, and the task sat
 * in the host's set for the full fifteen minutes, because `tail -f` never
 * exits. The row spun for as long as it did. So the readings this pins are the
 * ones a row is drawn from:
 *
 *  1. `Monitor` raises `task_started` at all, and it carries the `tool_use_id`
 *     of the Monitor call — without the id there is a task and no row to count
 *     it on, exactly as for a background agent or shell.
 *  2. The turn's `result` arrives while the monitor is still out. That gap is
 *     the whole stretch the row has to cover from the task set.
 *  3. What the CLI's own registry says three seconds into that stretch — a
 *     background *shell* holds nothing there, a background *agent* does, and
 *     nobody had asked which side a monitor falls on.
 *  4. A monitor *event* — a line written to the watched file — is not a turn.
 *     The model is told, but what arrives and whether it costs a turn is the
 *     thing to read, since anything that looks like a turn moves the row.
 *  5. `stopTask` ends it, and what says so.
 *  6. Whether the transcript records the end at all. A background agent's
 *     `<task-notification>` is what settles its pending call; if a monitor's
 *     end is written nowhere, the socket's task set is the only word there is.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import {
  appendFileSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-monitor-task-"));
const watchLog = path.join(scratch, "watch.log");

// Long enough that the turn is over well before the monitor is, short enough
// that a run that loses its grip on the task still ends inside the limit. The
// tool is named exactly, and every other tool forbidden: a session that reaches
// for Bash instead measures nothing and says it passed.
const ASK =
  "Use the Monitor tool exactly once, with description 'watch the probe log', " +
  `command: tail -f ${watchLog} , timeout_ms: 60000, and persistent: false. ` +
  "Then say started. Do not create the file, do not read it, do not write to it, " +
  "do not use TaskStop, and do not use any other tool.";

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

const sessionsDir = path.join(
  process.env.CLAUDE_CONFIG_DIR?.trim() || path.join(homedir(), ".claude"),
  "sessions",
);

/**
 * The registry record the CLI writes for itself, found by session id. `null` is
 * a record with no status — a CLI too old to write one — and `undefined` is no
 * record at all. Read while the session is alive: the CLI deletes the record on
 * exit, so a read after `close()` says nothing.
 */
function registryStatus(sessionId: string): string | null | undefined {
  let files: string[];
  try {
    files = readdirSync(sessionsDir).filter((name) => name.endsWith(".json"));
  } catch {
    return undefined;
  }
  for (const name of files) {
    try {
      const record = JSON.parse(readFileSync(path.join(sessionsDir, name), "utf8"));
      if (record.sessionId !== sessionId) continue;
      return typeof record.status === "string" ? record.status : null;
    } catch {
      continue;
    }
  }
  return undefined;
}

/** The session's own transcript, wherever the CLI filed it. */
function transcript(sessionId: string): { file: string; text: string } | null {
  const projects = path.join(homedir(), ".claude", "projects");
  if (!existsSync(projects)) return null;
  for (const slug of readdirSync(projects)) {
    const file = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(file)) return { file, text: readFileSync(file, "utf8") };
  }
  return null;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Seen = { at: number; label: string; detail?: string };

interface Run {
  sessionId: string | null;
  startedRaw: Record<string, unknown> | null;
  started: { taskId: string; toolUseId?: string } | null;
  monitorCallId: string | null;
  monitorInput: unknown;
  monitorResult: string | null;
  otherTools: string[];
  resultAt: number | null;
  firstNoticeAt: number | null;
  notice: { status?: string; toolUseId?: string; summary?: string } | null;
  updates: { at: number; patch: unknown }[];
  registryAt: number | null;
  registryDuringTask: string | null | undefined;
  eventWriteAt: number | null;
  duringEventWindow: Seen[];
  stopCalledAt: number | null;
  stopResolved: boolean;
  stopError: string | null;
  noticeAfterStopMs: number | null;
  seen: Seen[];
}

const LIMIT_MS = 150_000;
const SETTLE_MS = 3_000;
const EVENT_WINDOW_MS = 8_000;
const STOP_WAIT_MS = 20_000;

async function probe(): Promise<Run> {
  const run: Run = {
    sessionId: null,
    startedRaw: null,
    started: null,
    monitorCallId: null,
    monitorInput: null,
    monitorResult: null,
    otherTools: [],
    resultAt: null,
    firstNoticeAt: null,
    notice: null,
    updates: [],
    registryAt: null,
    registryDuringTask: undefined,
    eventWriteAt: null,
    duringEventWindow: [],
    stopCalledAt: null,
    stopResolved: false,
    stopError: null,
    noticeAfterStopMs: null,
    seen: [],
  };

  writeFileSync(watchLog, "");

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

  // Resolved when the turn hands itself back, which is where the phases below
  // start. The loop keeps reading throughout — awaited inside it, every phase
  // would stop the stream and the events being measured would never be seen.
  let turnEnded: () => void = () => {};
  const turnOver = new Promise<void>((resolve) => {
    turnEnded = resolve;
  });

  const note = (label: string, detail?: string) => {
    const entry = { at: Date.now(), label, detail };
    run.seen.push(entry);
    if (
      run.eventWriteAt !== null &&
      run.stopCalledAt === null &&
      entry.at >= run.eventWriteAt
    ) {
      run.duringEventWindow.push(entry);
    }
  };

  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  const reading = (async () => {
    for await (const message of session as AsyncIterable<any>) {
      const subtype: string | undefined = message.subtype;

      if (message.type === "system" && subtype === "init" && message.session_id) {
        run.sessionId = message.session_id;
      }

      if (message.type === "assistant") {
        for (const block of message.message?.content ?? []) {
          if (block?.type !== "tool_use") continue;
          note(`tool_use/${block.name}`, block.id);
          if (block.name === "Monitor") {
            run.monitorCallId ??= block.id;
            run.monitorInput ??= block.input;
          } else if (!run.otherTools.includes(block.name)) {
            run.otherTools.push(block.name);
          }
        }
      }

      if (message.type === "user") {
        const content = message.message?.content;
        if (Array.isArray(content)) {
          const kinds = content.map((block: any) => block?.type).join(",");
          note(`user/${kinds}`);
          for (const block of content) {
            if (block?.type === "tool_result" && block.tool_use_id === run.monitorCallId) {
              run.monitorResult ??=
                typeof block.content === "string"
                  ? block.content
                  : JSON.stringify(block.content);
            }
          }
        } else {
          note("user_turn", String(content).replace(/\s+/g, " ").slice(0, 160));
        }
      }

      if (typeof subtype === "string" && subtype.startsWith("task")) {
        note(
          `${subtype}${message.status ? `/${message.status}` : ""}`,
          message.task_id,
        );
      }

      if (subtype === "task_started" && message.task_id && !run.started) {
        run.startedRaw = message;
        run.started = { taskId: message.task_id, toolUseId: message.tool_use_id };
      }

      if (subtype === "task_updated" && message.task_id === run.started?.taskId) {
        run.updates.push({ at: Date.now(), patch: message.patch });
      }

      if (subtype === "task_notification" && message.task_id === run.started?.taskId) {
        if (run.firstNoticeAt === null) {
          run.firstNoticeAt = Date.now();
          run.notice = {
            status: message.status,
            toolUseId: message.tool_use_id,
            summary:
              typeof message.summary === "string"
                ? message.summary
                : JSON.stringify(message.summary ?? null),
          };
          if (run.stopCalledAt !== null) {
            run.noticeAfterStopMs = run.firstNoticeAt - run.stopCalledAt;
          }
        }
      }

      if (message.type === "result") {
        note("result");
        if (run.resultAt === null) {
          run.resultAt = Date.now();
          turnEnded();
        }
      }
    }
  })();

  try {
    await Promise.race([turnOver, sleep(LIMIT_MS)]);

    // The registry read is taken off a fixed offset, as session-state-probe's
    // is: polled for the wanted value it would match whatever the turn had
    // already written and read the change as present.
    await sleep(SETTLE_MS);
    run.registryAt = Date.now();
    if (run.sessionId) run.registryDuringTask = registryStatus(run.sessionId);

    // A monitor event: one line into the watched file. Whether it costs a turn
    // is the reading — anything that arrives as a user turn moves the row.
    run.eventWriteAt = Date.now();
    appendFileSync(watchLog, `probe event ${new Date().toISOString()}\n`);
    await sleep(EVENT_WINDOW_MS);

    if (run.started) {
      run.stopCalledAt = Date.now();
      try {
        await session.stopTask(run.started.taskId);
        run.stopResolved = true;
      } catch (error: any) {
        run.stopError = error?.message ?? String(error);
      }
      const until = Date.now() + STOP_WAIT_MS;
      while (run.firstNoticeAt === null && Date.now() < until) await sleep(250);
      // Let whatever the CLI writes about the end reach the file.
      await sleep(3_000);
    }
  } finally {
    clearTimeout(deadline);
    input.close();
    session.close?.();
    await Promise.race([reading.catch(() => {}), sleep(5_000)]);
  }

  return run;
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const run = await probe();
const origin = run.seen[0]?.at ?? Date.now();
const rel = (at: number | null) => (at === null ? "never" : `+${((at - origin) / 1000).toFixed(1)}s`);

console.log("\nmonitor task");
console.log(`  session id: ${run.sessionId ?? "never named"}`);
console.log(
  `  events: ${run.seen.map((e) => `${rel(e.at)} ${e.label}`).join("\n          ") || "none"}`,
);
console.log(`  Monitor call id: ${run.monitorCallId ?? "never called"}`);
console.log(`  Monitor input: ${JSON.stringify(run.monitorInput ?? null)}`);
console.log(`  Monitor tool_result: ${run.monitorResult ?? "none seen"}`);
console.log(`  other tools used: ${run.otherTools.join(", ") || "none"}`);
console.log(`  task_started: ${JSON.stringify(run.startedRaw ?? null, null, 2)}`);
console.log(
  `  task_started.tool_use_id === Monitor call id: ${
    run.started?.toolUseId === undefined
      ? "no id carried"
      : String(run.started.toolUseId === run.monitorCallId)
  }`,
);
console.log(`  result at ${rel(run.resultAt)}, first notification at ${rel(run.firstNoticeAt)}`);
console.log(
  `  registry ${SETTLE_MS}ms after the result (${rel(run.registryAt)}): ${String(run.registryDuringTask)}`,
);
console.log(`  line written to watch.log at ${rel(run.eventWriteAt)}`);
console.log(
  `  in the ${EVENT_WINDOW_MS}ms after it: ${
    run.duringEventWindow.map((e) => `${rel(e.at)} ${e.label}`).join(", ") || "nothing at all"
  }`,
);
console.log(
  `  task_updated for it: ${
    run.updates.map((u) => `${rel(u.at)} ${JSON.stringify(u.patch)}`).join(", ") || "none"
  }`,
);
console.log(
  `  stopTask at ${rel(run.stopCalledAt)}: ${
    run.stopResolved ? "resolved" : run.stopError ? `rejected — ${run.stopError}` : "never called"
  }`,
);
console.log(`  notification after stopTask: ${JSON.stringify(run.notice ?? null)}`);
console.log(
  `  it arrived ${run.noticeAfterStopMs === null ? "not at all after the stop" : `${run.noticeAfterStopMs}ms after the call`}`,
);

const file = run.sessionId ? transcript(run.sessionId) : null;
console.log(`  transcript: ${file?.file ?? "not found"}`);
if (file) {
  const lines = file.text.split("\n").filter((line) => line.trim());
  const mentions = lines.filter(
    (line) =>
      (run.started?.taskId && line.includes(run.started.taskId)) ||
      line.includes("task-notification") ||
      line.includes("task_notification"),
  );
  console.log(`  records: ${lines.length}`);
  console.log(
    `  records naming the task or a notification: ${mentions.length || "none"}`,
  );
  for (const line of mentions) console.log(`    ${line.slice(0, 420)}`);
  console.log("  last 3 records:");
  for (const line of lines.slice(-3)) console.log(`    ${line.slice(0, 400)}`);
}

rmSync(scratch, { recursive: true, force: true });

check(run.started !== null, "a Monitor raises a task at all");
check(
  run.started?.toolUseId !== undefined,
  "the task names the tool_use it came from, which is what a row can count it by",
);
check(
  run.resultAt !== null && (run.firstNoticeAt === null || run.resultAt < run.firstNoticeAt),
  "the turn ends while the monitor is still out — the stretch the row has to cover",
);
check(
  run.stopResolved || run.firstNoticeAt !== null,
  "stopTask is answered, or the monitor says what became of it within 20s",
);

console.log(
  failures.length
    ? `\nmonitor-task: ${failures.length} check(s) failed`
    : "\nmonitor-task: all checks passed",
);
process.exit(failures.length ? 1 : 0);
