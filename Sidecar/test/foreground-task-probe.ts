/**
 * Whether every task the stream starts is a task the stream settles — for the
 * foreground kinds, which background-bash-probe.ts and stop-agent-probe.ts
 * never measured on their own.
 *
 *   node test/foreground-task-probe.ts
 *
 * The host folds every `task_started` into `#tasks` and takes one out only on
 * `task_notification`. The row now reads that set, and the reaper always has:
 * an entry nothing removes pins a session to "working" for the rest of its
 * life and keeps it off the reaper's list. `task_started` fires for foreground
 * work too (`is_backgrounded` is "Set for local_agent and local_bash tasks"),
 * so the exposure is every session that ever runs a plain Bash command or a
 * foreground agent — if their settles arrive on an edge the host doesn't
 * listen for, or never arrive at all. Four runs:
 *
 *  1. A plain foreground Bash command. Does it announce a task, and if so,
 *     does the stream settle it?
 *  2. A foreground agent that finishes on its own. Same question.
 *  3. A foreground agent stopped mid-run with `stopTask` — the pane's own
 *     button. `stop-agent-probe.ts` accepts either `task_notification` or a
 *     killed `task_updated` here, which is exactly the ambiguity that matters:
 *     the host only listens for the notification.
 *  4. A foreground Bash command that outlives its `timeout`. Since CLI 2.1.311
 *     its result says it "was moved to the background": the turn ends while
 *     the command runs on, so the row's working spinner comes from the task
 *     set alone, and the settle has to arrive after the turn's `result`.
 *
 * The third run has to prove it measured a stop. A `stopTask` for an id the CLI
 * has forgotten is accepted rather than refused, and the throw is swallowed, so
 * an agent that finished on its own inside the three seconds settles with an
 * ordinary `completed` notice and passes "every started id was notified" having
 * measured nothing. So the settle must carry the status a stop writes
 * (`stopped` or `killed`, the discriminator `stop-agent-probe.ts` uses), and
 * nothing may have settled that task before the stop was issued. The stop goes
 * off a timer rather than being awaited in the loop: awaited, the loop stops
 * reading, and a notice that beat the stop would be stamped after it.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-foreground-task-"));

const BASH_ASK =
  "Run exactly one Bash command: echo hi. Then say done. Do not use any other tool.";

const AGENT_ASK =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
  "description 'say done', and run_in_background: false, giving it this task: " +
  "Reply with the single word done. " +
  "Then say done yourself. Do not use any other tool.";

/** `sleep` is refused outright now, so the wait is Python's. */
const TIMEOUT_BASH_ASK =
  "Run exactly one Bash command, with run_in_background false and timeout 5000: " +
  "python3 -c \"import time; print('started', flush=True); time.sleep(20); print('finished')\". " +
  "When it comes back, say done. Do not use any other tool, and do not wait for it or check on it.";

/** Long enough to still be going when the stop reaches for it. */
const SLOW_AGENT_ASK =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
  "description 'count slowly', and run_in_background: false, giving it this task: " +
  "Write out every number from 1 to 300, one per line, spelled in words. Write them " +
  "all — do not summarise or skip ahead. " +
  "Then say done. Do not use any other tool, and do not do the counting yourself.";

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

interface TaskEvent {
  subtype: string;
  taskId?: string;
  status?: string;
}

interface Notice {
  taskId: string;
  status?: string;
  at: number;
}

interface Run {
  events: TaskEvent[];
  startedIds: string[];
  notifiedIds: string[];
  terminallyUpdatedIds: string[];
  startedAt: Record<string, number>;
  notices: Notice[];
  stop: { taskId: string; at: number; error: string | null } | null;
  movedToBackground: string[];
  firstResultAt: number | null;
}

const LIMIT_MS = 180_000;
const GRACE_MS = 10_000;
const STOP_AFTER_MS = 3_000;

async function probe(ask: string, stopFirstTask: boolean, graceMs = GRACE_MS): Promise<Run> {
  const run: Run = {
    events: [],
    startedIds: [],
    notifiedIds: [],
    terminallyUpdatedIds: [],
    startedAt: {},
    notices: [],
    stop: null,
    movedToBackground: [],
    firstResultAt: null,
  };

  const input = heldOpen(ask);
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

  // The turn's result is not the last word: a settle can trail it, and whether
  // one does is the entire question. Hold the stream open a while after.
  let grace: ReturnType<typeof setTimeout> | null = null;
  let stopTimer: ReturnType<typeof setTimeout> | null = null;

  try {
    for await (const message of session as AsyncIterable<any>) {
      const subtype: string | undefined = message.subtype;
      if (typeof subtype === "string" && subtype.startsWith("task")) {
        const status = message.status ?? message.patch?.status;
        run.events.push({ subtype, taskId: message.task_id, status });

        if (subtype === "task_started" && message.task_id) {
          run.startedIds.push(message.task_id);
          run.startedAt[message.task_id] = Date.now();
          if (stopFirstTask && run.startedIds.length === 1) {
            const taskId: string = message.task_id;
            stopTimer = setTimeout(() => {
              run.stop = { taskId, at: Date.now(), error: null };
              session.stopTask(taskId).catch((error: any) => {
                if (run.stop) run.stop.error = error?.message ?? String(error);
              });
            }, STOP_AFTER_MS);
          }
        }
        if (subtype === "task_notification" && message.task_id) {
          run.notifiedIds.push(message.task_id);
          run.notices.push({ taskId: message.task_id, status, at: Date.now() });
        }
        if (
          subtype === "task_updated" &&
          message.task_id &&
          ["killed", "completed", "failed", "stopped"].includes(status)
        ) {
          run.terminallyUpdatedIds.push(message.task_id);
        }
        if (subtype === "task_updated" && message.task_id && message.patch?.is_backgrounded === true) {
          run.movedToBackground.push(message.task_id);
        }
      }

      if (message.type === "result") {
        run.events.push({ subtype: "result" });
        run.firstResultAt ??= Date.now();
      }

      const allSettled =
        run.startedIds.length > 0 &&
        run.startedIds.every((id) => run.notifiedIds.includes(id));
      if (message.type === "result" && (allSettled || run.startedIds.length === 0)) break;
      if (message.type === "result" && !grace) {
        grace = setTimeout(() => {
          input.close();
          session.close?.();
        }, graceMs);
      }
    }
  } finally {
    clearTimeout(deadline);
    if (grace) clearTimeout(grace);
    if (stopTimer) clearTimeout(stopTimer);
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

function describe(run: Run): void {
  console.log(
    `  events: ${run.events.map((e) => `${e.subtype}${e.status ? `/${e.status}` : ""}`).join(" → ") || "none"}`,
  );
  console.log(`  started: ${run.startedIds.length}, notified: ${run.notifiedIds.length}`);
}

try {
  console.log("\nforeground bash");
  const bash = await probe(BASH_ASK, false);
  describe(bash);
  check(
    bash.startedIds.every((id) => bash.notifiedIds.includes(id)),
    "every task a plain Bash call starts, a notification settles",
  );

  console.log("\nforeground agent, finishing on its own");
  const agent = await probe(AGENT_ASK, false);
  describe(agent);
  check(agent.startedIds.length > 0, "a foreground agent announces a task at all (control)");
  check(
    agent.startedIds.every((id) => agent.notifiedIds.includes(id)),
    "its finish arrives as a notification, the one edge the host removes on",
  );

  console.log("\nforeground agent, stopped from outside");
  const stopped = await probe(SLOW_AGENT_ASK, true);
  describe(stopped);
  const target = stopped.stop?.taskId ?? null;
  const forTarget = stopped.notices.filter((n) => n.taskId === target);
  const settle = forTarget[0];
  const startedAt = target === null ? undefined : stopped.startedAt[target];
  console.log(
    `  task_started → stop: ${stopped.stop && startedAt ? `${stopped.stop.at - startedAt}ms` : "no stop issued"}` +
      `, stop → notification: ${stopped.stop && settle ? `${settle.at - stopped.stop.at}ms` : "no notification"}` +
      (stopped.stop?.error ? `, stopTask threw: ${stopped.stop.error}` : ""),
  );
  check(stopped.startedIds.length > 0, "the agent to stop announced itself (control)");
  check(stopped.stop !== null, "a stop was issued against it (control)");
  check(
    stopped.startedIds.every((id) => stopped.notifiedIds.includes(id)),
    "a stop settles by notification too — a kill that only reaches task_updated wedges the host's set",
  );
  check(
    settle !== undefined && (settle.status === "stopped" || settle.status === "killed"),
    `the settle names the stop rather than a finish of its own (${settle?.status ?? "no notification"})`,
  );
  check(
    stopped.stop !== null && !forTarget.some((n) => n.at < stopped.stop!.at),
    "and nothing settled that task before the stop was issued — an agent that finished on its own is not a stop measured",
  );

  console.log("\nforeground bash, past its timeout");
  const timedOut = await probe(TIMEOUT_BASH_ASK, false, 60_000);
  describe(timedOut);
  const moved = timedOut.movedToBackground[0];
  const settledAt = timedOut.notices.find((n) => n.taskId === moved)?.at;
  check(timedOut.startedIds.length > 0, "the command announced a task (control)");
  check(
    moved !== undefined && timedOut.startedIds.includes(moved),
    "the timeout moved that task to the background rather than ending it (control)",
  );
  check(
    timedOut.firstResultAt !== null && settledAt !== undefined && timedOut.firstResultAt < settledAt,
    "the turn ended while the command ran on — only the task set says the session is still working",
  );
  check(
    timedOut.startedIds.every((id) => timedOut.notifiedIds.includes(id)),
    "and the command's own end still settles it by notification",
  );
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nforeground-task: ${failures.length} check(s) failed`
    : "\nforeground-task: all checks passed",
);
process.exit(failures.length ? 1 : 0);
