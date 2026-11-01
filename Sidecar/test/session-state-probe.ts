/**
 * Pins how a hosted session says it is idle once background work is out.
 *
 *   node test/session-state-probe.ts
 *
 * Since CLI v2.1.269 a headless session no longer reports itself idle while a
 * background *agent* runs. The turn's `result` still arrives when the model is
 * done — the turn is not held back while the input stream is open — and the
 * CLI's own word lives in `status` in `~/.claude/sessions/<pid>.json`, which
 * now waits for the agent. A background *shell* holds nothing: the CLI's
 * "running background tasks" leaves `local_bash` out, so a session with only
 * a backgrounded command out says idle the moment its turn ends, as before.
 * `CLAUDE_CODE_BG_TASKS_REPORT_RUNNING=0` restores the old reading for agents
 * too. The SDK types a `system/session_state_changed` message for the same
 * state; a streaming-input session never receives one.
 *
 * Three sessions, one reading each:
 *
 *   1. A background agent, default. The result comes before the agent settles,
 *      the registry says `busy` three seconds after it and `idle` once the
 *      agent has settled and the CLI's own task-notification turn has run,
 *      and no state message arrives on the stream at any point.
 *   2. A background agent with the flag off. The registry says `idle` three
 *      seconds after the result, agent still running — what every host built
 *      before v2.1.269 was built on.
 *   3. A background shell, default. Same as 2: a shell does not hold it.
 *
 * The host reads `result`, not the registry, on purpose: the app draws an
 * idle-with-work row off `session.tasks`, and the session-level Stop has to
 * stay off while only background work is out. This probe is the alarm for the
 * day the result itself starts being held, or the day the CLI's state starts
 * arriving on the stream and the host has something better to read.
 *
 * Three traps. The registry is read at fixed offsets rather than polled for the
 * wanted value — polling matched the `busy` the turn had written before the
 * result and read the change as present when it wasn't. And it is read while
 * the session is alive: the CLI deletes its record on exit, so a read after
 * `close()` finds nothing and says nothing. The third is the offset itself: a
 * read three seconds after the result only says anything about a session with
 * work out if the work was still out when it landed, and `result → notice`
 * proves nothing about where the read fell between them. So the read is
 * stamped and placed against the notice, and it is taken off a timer rather
 * than awaited in the loop — awaited, the loop stops reading, and a notice that
 * beat the read would be stamped after it and read as a reading that held.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-session-state-"));

const ASK_SHELL =
  "Use the Bash tool exactly once, with run_in_background: true, description " +
  "'sleep in the background', and this exact command: sleep 20 && echo done. " +
  "Then say launched. Do not wait for it, do not check on it, do not use any other tool.";

const ASK_AGENT =
  "Use the Agent tool exactly once, with run_in_background: true, description " +
  "'sleep in the background', and this exact prompt: \"Use the Bash tool to run exactly " +
  "this command and nothing else: sleep 20 && echo done. Then reply with the single " +
  "word done.\" Then say launched. Do not wait for it, do not use TaskOutput, do not " +
  "check on it, do not use any other tool.";

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
 * The registry record the CLI writes for itself, found by session id. `null`
 * is a record with no status — a CLI too old to write one — and `undefined`
 * is no record at all.
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

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Run = {
  events: string[];
  sessionId: string | null;
  taskType: string | null;
  resultAt: number | null;
  noticeAt: number | null;
  stateMessages: number;
  registryAt: number | null;
  registryDuringTask: string | null | undefined;
  registryAfter: string | null | undefined;
};

const LIMIT_MS = 150_000;
const SETTLE_MS = 3_000;

async function probe(ask: string, reportRunning: boolean): Promise<Run> {
  const run: Run = {
    events: [],
    sessionId: null,
    taskType: null,
    resultAt: null,
    noticeAt: null,
    stateMessages: 0,
    registryAt: null,
    registryDuringTask: undefined,
    registryAfter: undefined,
  };
  const input = heldOpen(ask);
  const env: Record<string, string | undefined> = { ...process.env };
  if (!reportRunning) env.CLAUDE_CODE_BG_TASKS_REPORT_RUNNING = "0";
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
      env,
    } as any,
  });

  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  let taskId: string | null = null;
  let duringRead: ReturnType<typeof setTimeout> | null = null;
  try {
    for await (const message of session as AsyncIterable<any>) {
      const subtype: string | undefined = message.subtype;
      if (message.type === "system" && subtype === "init") {
        run.sessionId = message.session_id ?? null;
      }
      if (subtype === "session_state_changed") {
        run.stateMessages += 1;
        run.events.push(`state/${message.state}`);
      }
      if (subtype === "task_started" && message.task_id && !taskId) {
        taskId = message.task_id;
        run.taskType = message.task_type ?? null;
        run.events.push(`task_started/${run.taskType}`);
      }
      if (subtype === "task_notification" && message.task_id === taskId) {
        run.events.push(`task_notification/${message.status}`);
        run.noticeAt = Date.now();
      }
      if (message.type === "result") {
        run.events.push("result");
        if (run.resultAt === null) {
          run.resultAt = Date.now();
          duringRead = setTimeout(() => {
            run.registryAt = Date.now();
            if (run.sessionId) run.registryDuringTask = registryStatus(run.sessionId);
          }, SETTLE_MS);
        } else if (run.noticeAt !== null) {
          // The CLI's own task-notification turn ends here; only now is the
          // session out of work.
          await sleep(SETTLE_MS);
          if (run.sessionId) run.registryAfter = registryStatus(run.sessionId);
          break;
        }
      }
    }
  } finally {
    clearTimeout(deadline);
    if (duringRead) clearTimeout(duringRead);
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

/** Whether the during-task read landed while the work really was still out. */
function readWhileWorking(run: Run): boolean {
  return run.registryAt !== null && run.noticeAt !== null && run.noticeAt > run.registryAt;
}

function describe(label: string, run: Run): void {
  console.log(`\n${label}`);
  console.log(`  events: ${run.events.join(" → ") || "none"}`);
  console.log(
    `  result → notice: ${run.resultAt && run.noticeAt ? `${run.noticeAt - run.resultAt}ms` : "never"}`,
  );
  const gap = run.registryAt && run.noticeAt ? run.noticeAt - run.registryAt : null;
  console.log(
    `  registry read: ${run.registryAt && run.resultAt ? `${run.registryAt - run.resultAt}ms after the result` : "never taken"}` +
      `, ${gap === null ? "no notice in yet" : gap > 0 ? `${gap}ms before the notice` : `${-gap}ms AFTER the notice`}`,
  );
  console.log(`  registry ${SETTLE_MS}ms after the result: ${String(run.registryDuringTask)}`);
  console.log(`  registry once the work is over: ${String(run.registryAfter)}`);
  console.log(`  state messages on the stream: ${run.stateMessages}`);
}

let agent: Run;
let agentLegacy: Run;
let shell: Run;
try {
  agent = await probe(ASK_AGENT, true);
  agentLegacy = await probe(ASK_AGENT, false);
  shell = await probe(ASK_SHELL, true);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

describe("background agent, default", agent);
check(agent.taskType === "local_agent", "the session launched a background agent");
check(
  agent.resultAt !== null && agent.noticeAt !== null && agent.resultAt < agent.noticeAt,
  "the turn's result still arrives while the agent is out — the result is not held back with the input open",
);
check(
  readWhileWorking(agent),
  "the registry was read before the agent settled — a read after the notice says nothing about a session with work out (phase)",
);
check(
  agent.registryDuringTask === "busy",
  "the sessions registry still says busy after the result, while the agent runs",
);
check(agent.registryAfter === "idle", "and idle once the agent and the CLI's own notification turn are done");
check(
  agent.stateMessages === 0,
  "the CLI's state never reaches the stream — session_state_changed is typed and never sent, so the host has only the result to read",
);

describe("background agent, CLAUDE_CODE_BG_TASKS_REPORT_RUNNING=0", agentLegacy);
check(agentLegacy.taskType === "local_agent", "the session launched a background agent");
check(
  readWhileWorking(agentLegacy),
  "the registry was read before the agent settled — with the flag off an idle reading taken after it would hold either way (phase)",
);
check(
  agentLegacy.registryDuringTask === "idle",
  "with the flag off the registry says idle after the result, agent still running — the pre-v2.1.269 reading",
);

describe("background shell, default", shell);
check(shell.taskType === "local_bash", "the session launched a background shell");
check(
  readWhileWorking(shell),
  "the registry was read before the command settled — an idle reading taken after it would hold either way (phase)",
);
check(
  shell.registryDuringTask === "idle",
  "a background shell holds nothing: the registry says idle after the result with the command still running",
);

console.log(
  failures.length
    ? `\nsession-state: ${failures.length} check(s) failed`
    : "\nsession-state: all checks passed",
);
process.exit(failures.length ? 1 : 0);
