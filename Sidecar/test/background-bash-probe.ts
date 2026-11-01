/**
 * Whether a background shell command is a task the way a background agent is —
 * announced by `task_started` while it runs, settled by `task_notification`
 * after the turn that launched it has ended.
 *
 *   node test/background-bash-probe.ts
 *
 * The sidebar reads a session's background work off `session.tasks`, which the
 * host builds from those two bookends. The SDK's types say they fire for
 * `local_bash` as well as agents (`is_backgrounded` is documented as "Set for
 * local_agent and local_bash tasks"), but every probe here had only ever raised
 * an agent, so the shell half of the row's working indicator rested on a doc
 * comment. Three readings, in the order the bug lived in them:
 *
 *  1. `Bash(run_in_background: true)` emits `task_started` with a `task_id`
 *     and the `tool_use_id` of the Bash call — without the id there is a task
 *     and no row to count it on.
 *  2. The turn ends while the task is still out: the `result` arrives before
 *     any `task_notification` for it. That gap is the grey dot — state `idle`,
 *     work still running.
 *  3. The `task_notification` does arrive, which is what takes the row back
 *     off "working" when the command finishes.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-background-bash-"));

// Long enough that the turn is over well before the command is; short enough
// that the notification lands inside the limit.
const ASK =
  "Use the Bash tool exactly once, with run_in_background: true, " +
  "description 'sleep in the background', and this exact command: sleep 20 && echo done. " +
  "Then say launched. Do not wait for the command, do not read its output, " +
  "and do not use any other tool.";

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

interface Run {
  started: {
    taskId: string;
    toolUseId?: string;
    taskType?: string;
    isBackgrounded?: boolean;
  } | null;
  resultBeforeNotice: boolean | null;
  notice: { taskId: string; status: string } | null;
  events: string[];
}

const LIMIT_MS = 120_000;

async function probe(): Promise<Run> {
  const run: Run = { started: null, resultBeforeNotice: null, notice: null, events: [] };

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
      const subtype: string | undefined = message.subtype;
      if (typeof subtype === "string" && subtype.startsWith("task")) {
        run.events.push(`${subtype}${message.status ? `/${message.status}` : ""}`);
      }

      if (subtype === "task_started" && message.task_id && !run.started) {
        run.started = {
          taskId: message.task_id,
          toolUseId: message.tool_use_id,
          taskType: message.task_type,
          isBackgrounded: message.is_backgrounded,
        };
      }

      if (message.type === "result") {
        run.events.push("result");
        if (run.resultBeforeNotice === null) run.resultBeforeNotice = run.notice === null;
      }

      if (subtype === "task_notification" && message.task_id === run.started?.taskId) {
        run.notice = { taskId: message.task_id, status: message.status };
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
  console.log(`  events: ${run.events.join(" → ") || "none"}`);
  console.log(`  task id: ${run.started?.taskId ?? "never seen"}`);
  console.log(`  tool_use id: ${run.started?.toolUseId ?? "not carried"}`);
  console.log(`  task_type: ${run.started?.taskType ?? "not named"}`);
  console.log(`  is_backgrounded: ${run.started?.isBackgrounded ?? "not marked"}`);

  check(run.started !== null, "a background shell command announces a task id at all");
  check(
    run.started?.toolUseId !== undefined,
    "the task names the tool_use it came from, which is what a row can count it by",
  );
  check(
    run.resultBeforeNotice === true,
    "the turn ends while the command is still out — the stretch the row has to cover",
  );
  check(
    run.notice?.status === "completed",
    "the notification arrives and says completed, which is what settles the row",
  );
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nbackground-bash: ${failures.length} check(s) failed`
    : "\nbackground-bash: all checks passed",
);
process.exit(failures.length ? 1 : 0);
