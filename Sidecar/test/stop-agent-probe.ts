/**
 * Whether an agent can be stopped on its own, and what the session is left with
 * when it is.
 *
 *   node test/stop-agent-probe.ts
 *
 * The pane names every agent a session still has out. Stopping one from there
 * needs three things to be true, and none of them is documented as behaviour
 * anyone may rely on:
 *
 *  1. A **running** agent has an id we can reach. `stopTask` wants a `task_id`,
 *     and the only place the app had ever seen one was the notification that
 *     arrives when an agent *finishes* — no use for stopping it. `task_started`
 *     claims to carry one at the other end, keyed by `tool_use_id`, which is
 *     what the transcript knows an agent by. That join is the whole feature: no
 *     `tool_use_id` on the event and the app cannot tell which row it belongs
 *     to.
 *  2. `stopTask` actually stops it, and says so — `task_notification` with
 *     status `stopped`.
 *  3. The call the agent was spawned by **comes back**. The pane reads what is
 *     running off the transcript, where a call with no result is a call still
 *     going; an agent stopped without a result written would spin in the strip
 *     for the rest of the session, and the button would look like it did
 *     nothing.
 *
 * Both kinds are probed because the app draws both. A foreground agent blocks
 * the turn that spawned it, so stopping one has to hand the turn back; a
 * background one was launched with a receipt and the turn carried on past it,
 * so its notification is the only thing that ever settles the call.
 *
 * The session is held open by a stream that doesn't end, the way the host holds
 * one: a background agent's notification lands after the turn that launched it,
 * and a prompt handed over as a string closes the input behind itself.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-stop-agent-"));

/** Long enough to still be going when we reach for it, with no tool to ask for. */
const WORK =
  "Write out every number from 1 to 400, one per line, spelled in words " +
  "(one, two, three …). Write them all — do not summarise or skip ahead.";

// `run_in_background` is named either way. It defaults to true, so a prompt that
// leaves it out gets a background agent whichever kind it meant to ask for —
// which is how the first run of this probe came to measure the same thing twice.
function ask(background: boolean): string {
  return (
    "Use the Agent tool exactly once, with subagent_type 'general-purpose'" +
    `, description 'count slowly', and run_in_background: ${background}` +
    `, giving it this whole task: ${WORK}` +
    " Then say done. Do not use any other tool, and do not do the counting yourself."
  );
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

/** The session's own transcript, wherever the CLI filed it. */
function transcript(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  if (!existsSync(projects)) return null;
  for (const slug of readdirSync(projects)) {
    const file = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(file)) return readFileSync(file, "utf8");
  }
  return null;
}

/**
 * What the transcript says became of that call — which is all the pane has to go
 * on.
 *
 * The tool result is not the answer: an agent's call comes back the moment it is
 * launched, and the app reads that receipt as the launch it is rather than as a
 * result (`isLaunch`). What settles the row is the `<task-notification>` the CLI
 * writes as a turn of its own, which is what `TranscriptText.finishedAgents`
 * parses — so that is what is looked for, and the status inside it is the
 * reading that matters.
 */
function settledBy(
  text: string | null,
  toolUseID: string,
): { settled: boolean; how: string } {
  if (!text) return { settled: false, how: "no transcript" };

  let receipt = false;

  for (const line of text.split("\n")) {
    if (line.includes("task-notification") && line.includes(toolUseID)) {
      const status = /<status>([^<]*)<\/status>/.exec(line)?.[1] ?? "no status";
      return { settled: true, how: `notification, status ${status}` };
    }

    if (!line.startsWith("{") || !line.includes(toolUseID)) continue;
    let record: any;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    const carries = (record?.message?.content ?? []).some(
      (block: any) => block?.type === "tool_result" && block?.tool_use_id === toolUseID,
    );
    if (!carries) continue;

    // A launch receipt is not a result — the app reads it as the launch it is,
    // and goes on drawing the agent as running.
    if (record?.toolUseResult?.status === "async_launched") receipt = true;
    else return { settled: true, how: "tool result" };
  }

  return { settled: false, how: receipt ? "a launch receipt and nothing since" : "nothing at all" };
}

interface Run {
  events: { subtype: string; taskId?: string; toolUseId?: string; status?: string }[];
  started: { taskId: string; toolUseId?: string; description?: string } | null;
  stopError: string | null;
  stoppedNotice: { taskId: string; status: string } | null;
  killed: boolean;
  sessionId: string | null;
  sawResult: boolean;
}

const LIMIT_MS = 180_000;

async function probe(background: boolean): Promise<Run> {
  const run: Run = {
    events: [],
    started: null,
    stopError: null,
    stoppedNotice: null,
    killed: false,
    sessionId: null,
    sawResult: false,
  };

  const input = heldOpen(ask(background));
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
      if (message.session_id) run.sessionId = message.session_id;

      const subtype: string | undefined = message.subtype;
      if (typeof subtype === "string" && (subtype.startsWith("task") || subtype.includes("background_tasks"))) {
        run.events.push({
          subtype,
          taskId: message.task_id,
          toolUseId: message.tool_use_id,
          status: message.status ?? message.patch?.status,
        });
      }

      // The one event that names a *running* agent. Reached for as soon as it
      // lands: a stop that waits for the agent to be interesting has nothing
      // left to prove.
      if (subtype === "task_started" && message.task_id && !run.started) {
        run.started = {
          taskId: message.task_id,
          toolUseId: message.tool_use_id,
          description: message.description,
        };
        await new Promise((resolve) => setTimeout(resolve, 3_000));
        try {
          await session.stopTask(message.task_id);
        } catch (error: any) {
          run.stopError = error?.message ?? String(error);
        }
      }

      if (subtype === "task_notification" && message.task_id === run.started?.taskId) {
        run.stoppedNotice = { taskId: message.task_id, status: message.status };
      }

      if (subtype === "task_updated" && message.patch?.status === "killed") {
        run.killed = true;
      }

      if (message.type === "result") run.sawResult = true;

      // Both halves before letting go: the turn has to hand itself back, and the
      // agent has to say what became of it. A background agent's word comes
      // after the turn it was launched in either way.
      if (run.sawResult && run.stoppedNotice) break;
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

async function report(background: boolean): Promise<void> {
  const kind = background ? "background" : "foreground";
  console.log(`\n${kind} agent`);

  const run = await probe(background);
  console.log(`  events: ${run.events.map((e) => `${e.subtype}${e.status ? `/${e.status}` : ""}`).join(" → ") || "none"}`);
  console.log(`  task id: ${run.started?.taskId ?? "never seen"}`);
  console.log(`  tool_use id: ${run.started?.toolUseId ?? "not carried"}`);
  if (run.stopError) console.log(`  stopTask threw: ${run.stopError}`);

  check(run.started !== null, `${kind}: a running agent announces a task id at all`);
  check(
    run.started?.toolUseId !== undefined,
    `${kind}: the task names the tool_use it came from, which is what the pane knows it by`,
  );
  // A stop that lands as the turn is already handing itself back never gets
  // its answer: the query closes first and `stopTask` rejects, while the agent
  // stops all the same — the transcript below says `killed`. Measured on
  // v2.1.238, failing about one run in two. So the reading is whether the agent
  // stopped, which is what the pane's Stop is for; the promise resolving is the
  // mechanism, and only a throw that came with the agent still running is one
  // the app would have to do something about.
  const closedFirst = run.stopError?.includes("Query closed") ?? false;
  const stopped = run.stoppedNotice?.status === "stopped" || run.killed;
  check(
    run.stopError === null || (closedFirst && stopped),
    `${kind}: stopTask is accepted, or refused only because the turn beat it`,
  );
  check(stopped, `${kind}: the agent reports that it stopped`);

  check(run.sawResult, `${kind}: the turn hands itself back rather than hanging on the agent`);

  const settled = run.started?.toolUseId
    ? settledBy(transcript(run.sessionId ?? ""), run.started.toolUseId)
    : { settled: false, how: "no task to look for" };
  console.log(`  transcript settles it by: ${settled.how}`);
  check(
    settled.settled,
    `${kind}: the transcript is told, so the pane stops drawing the agent as running`,
  );
}

try {
  await report(false);
  await report(true);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nstop-agent: ${failures.length} check(s) failed`
    : "\nstop-agent: all checks passed",
);
process.exit(failures.length ? 1 : 0);
