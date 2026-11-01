/**
 * Whether the task id names the agent's own transcript file.
 *
 *   node test/agent-file-probe.ts
 *
 * A foreground agent's `agentId` arrives beside the *result*, so for its whole
 * run the app knows no file to read and the row can show nothing but the launch
 * input. The one thing that names a running agent is `task_started`, and it
 * carries `task_id` — an id the app already holds, keyed by the `tool_use_id`
 * the transcript knows the row by, because the Stop button needed the same
 * join. If `task_id` is the stem of `subagents/agent-<id>.jsonl`, the id the
 * viewer needs was on the wire all along and live viewing is a lookup, not a
 * protocol change.
 *
 * Nothing documents these as the same id. They print alike (17 hex chars), and
 * one measured pair matching would still be a coincidence a rename could end —
 * so this pins the reading, and the checks are exact: the file named by the
 * task id exists while the agent is still out, and the records inside it name
 * the same id back (`agentId`), which is the field the app already trusts when
 * the result finally carries it.
 *
 * Also measured: how long after `task_started` the file turns up, since the
 * announcement-to-file gap is never zero (see transcript-arrival-probe) and
 * the pane polls rather than assumes.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-agent-file-"));

/** Long enough to still be going when we look, with no tool to ask for. */
const WORK =
  "Write out every number from 1 to 400, one per line, spelled in words " +
  "(one, two, three …). Write them all — do not summarise or skip ahead.";

// `run_in_background` defaults to true, so it is named even though this probe
// only wants the foreground kind — the one whose id is otherwise unreachable.
const ASK =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose'" +
  ", description 'count slowly', and run_in_background: false" +
  `, giving it this whole task: ${WORK}` +
  " Then say done. Do not use any other tool, and do not do the counting yourself.";

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

/** The session's transcript directory, wherever the CLI filed it. */
function sessionDirectory(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  if (!existsSync(projects)) return null;
  for (const slug of readdirSync(projects)) {
    if (existsSync(path.join(projects, slug, `${sessionId}.jsonl`))) {
      return path.join(projects, slug, sessionId);
    }
  }
  return null;
}

/**
 * Whether the parent transcript has settled the call — a tool_result naming
 * it, or the task-notification. Read off disk rather than off the stream:
 * the poll below runs after the message loop is left, so the stream cannot
 * say whether the agent had already finished when the file was found, and a
 * check that read it there could never fail.
 */
function settled(sessionId: string | null, toolUseId: string | null): boolean {
  if (!sessionId || !toolUseId) return true;
  const dir = sessionDirectory(sessionId);
  if (!dir) return true;
  const parent = path.join(path.dirname(dir), `${sessionId}.jsonl`);
  if (!existsSync(parent)) return true;
  for (const line of readFileSync(parent, "utf8").split("\n")) {
    if (!line.includes(toolUseId)) continue;
    if (line.includes("task-notification")) return true;
    try {
      const blocks = JSON.parse(line)?.message?.content ?? [];
      if (
        Array.isArray(blocks) &&
        blocks.some((block: any) => block?.type === "tool_result" && block?.tool_use_id === toolUseId)
      ) {
        return true;
      }
    } catch {
      continue;
    }
  }
  return false;
}

interface Run {
  taskId: string | null;
  toolUseId: string | null;
  fileAfterMs: number | null;
  agentIdsInFile: string[];
  siblingStems: string[];
  stillRunningWhenSeen: boolean;
}

const LIMIT_MS = 180_000;
const POLL_MS = 100;

async function probe(): Promise<Run> {
  const run: Run = {
    taskId: null,
    toolUseId: null,
    fileAfterMs: null,
    agentIdsInFile: [],
    siblingStems: [],
    stillRunningWhenSeen: false,
  };

  let sessionId: string | null = null;

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
    // Left as soon as the id is announced. The poll runs outside rather than
    // inside an iteration: a 30s wait mid-loop is 30s of unconsumed stream,
    // and nothing read after the break could move the checks anyway — what
    // settles the call is read off the transcript instead.
    for await (const message of session as AsyncIterable<any>) {
      if (message.session_id) sessionId = message.session_id;
      if (message.subtype === "task_started" && message.task_id) {
        run.taskId = message.task_id;
        run.toolUseId = message.tool_use_id ?? null;
        break;
      }
    }

    // The watch starts the moment the id is announced, which is the moment the
    // app would go looking. The directory is resolved every tick, not once: the
    // announcement-to-file gap covers the session's own folder too.
    const announced = Date.now();
    while (run.taskId && sessionId && Date.now() - announced < 30_000) {
      const dir = sessionDirectory(sessionId);
      const file = dir && path.join(dir, "subagents", `agent-${run.taskId}.jsonl`);
      if (file && existsSync(file)) {
        run.fileAfterMs = Date.now() - announced;
        run.stillRunningWhenSeen = !settled(sessionId, run.toolUseId);
        for (const line of readFileSync(file, "utf8").split("\n")) {
          if (!line.startsWith("{")) continue;
          try {
            const agentId = JSON.parse(line)?.agentId;
            if (typeof agentId === "string" && !run.agentIdsInFile.includes(agentId)) {
              run.agentIdsInFile.push(agentId);
            }
          } catch {
            continue;
          }
        }
        run.siblingStems = readdirSync(path.dirname(file)).map((name) =>
          name.replace(/^agent-|\.jsonl$/g, ""),
        );
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, POLL_MS));
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

let run: Run;
try {
  run = await probe();
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(`  task id: ${run.taskId ?? "never seen"}`);
console.log(`  tool_use id: ${run.toolUseId ?? "not carried"}`);
console.log(`  file appeared after: ${run.fileAfterMs === null ? "never" : `${run.fileAfterMs}ms`}`);
console.log(`  agentId inside the file: ${run.agentIdsInFile.join(", ") || "none"}`);
console.log(`  subagents/ held: ${run.siblingStems.join(", ") || "nothing"}`);

check(run.taskId !== null, "a foreground agent announces a task id");
check(run.toolUseId !== null, "the task names the tool_use it came from");
check(run.fileAfterMs !== null, "agent-<task_id>.jsonl exists under the session's subagents/");
check(run.stillRunningWhenSeen, "seen while the agent was still out, not after it finished");
check(
  run.agentIdsInFile.length > 0 && run.agentIdsInFile.every((id) => id === run.taskId),
  "every record in it names the task id back as its agentId",
);

console.log(
  failures.length
    ? `\nagent-file: ${failures.length} check(s) failed`
    : "\nagent-file: all checks passed",
);
process.exit(failures.length ? 1 : 0);
