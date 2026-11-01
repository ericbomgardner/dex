/**
 * Whether a session blocked on a foreground task can be handed a message and
 * answer it without losing the work it was blocked on.
 *
 *   node test/background-foreground-task-probe.ts
 *
 * A foreground agent holds the turn for as long as it runs — minutes, on a
 * real one — and a message sent into that stretch is written but not read,
 * because the model has no step to read it in. The app's only lever was
 * `interrupt`, which ends the turn and takes the agent with it.
 *
 * `query.backgroundTasks(toolUseId?)` is the SDK's Ctrl+B: every in-flight
 * foreground task (agents and Bash alike) is moved to the background, each
 * blocking call returns at once with a "running in the background" result,
 * and the turn carries on. Named with no id it backgrounds all of them.
 *
 * Three things have to hold for that to be worth sending on, and the last two
 * are the ones that would fail quietly:
 *
 *  1. The call is accepted and reports it moved something.
 *  2. The waiting message is answered *while the agent is still running* —
 *     the turn resuming is not the same as the model being handed what was
 *     said, and a message that only lands at the end of the turn is the bug
 *     this exists to fix.
 *  3. The agent still settles by `task_notification`, since that is the only
 *     edge the host removes on (`foreground-task-probe.ts`) and a task nothing
 *     settles pins the row to "working" for good.
 *
 * The Bash runs also settle a reading the agent runs cannot: `task_started`
 * turns out to depend on how long the command runs. `echo hi` announces no
 * task at all, where 75 seconds of shell announces one and settles it — which
 * is why the host gates on the session's *state* and not on its task set. A
 * task set says something is running. It does not say the turn has no step
 * left to read a message in, and those are different questions.
 *
 * The **control run is the whole measurement**. Backgrounding a task whose
 * agent was about to finish anyway looks identical to backgrounding one that
 * had minutes left, so the same ask is run once without the lever: if the
 * control also answers early, the agent is too fast and the run measured
 * nothing. Both orders are tried, because "send then background" and
 * "background then send" differ by which side of the resumed step the message
 * is sitting on, and only one of them can be built on.
 *
 * The tool result the backgrounded call comes back with is printed rather than
 * asserted: it is what the pane has to recognise as *not* an answer, and
 * pinning its wording here would only pin the CLI's phrasing twice.
 *
 * **Every run proves it sent into the phase it claims to measure.** The message
 * goes out a beat after the call the ask named — matched by tool name *and*
 * input, since a model that reaches for a quick Read first would otherwise put
 * the send outside the blocking call, where a fast answer proves nothing — and
 * each run asserts that the send lands between that call's own `task_started`
 * and its `task_notification`, printing both distances. A run that drifted out
 * of the window fails rather than passing assertions it was never asked.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-background-foreground-"));

/**
 * An ask, and the call it is meant to produce. The send is timed off that call
 * and nothing else: a model that reaches for some quick tool first would hand a
 * send fired on "any tool_use" a turn that is no longer blocked, and the fast
 * answer that follows would pass the very check the slow call exists for.
 */
interface Ask {
  text: string;
  what: string;
  matches(block: any): boolean;
}

/** Long enough that a message sent mid-run has somewhere to wait. */
const SLOW_AGENT_ASK: Ask = {
  what: "the counting agent",
  text:
    "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
    "description 'count slowly', and run_in_background: false, giving it this task: " +
    "Write out every number from 1 to 600, one per line, spelled in words. Write them " +
    "all — do not summarise or skip ahead. " +
    "Then say done. Do not use any other tool, and do not do the counting yourself.",
  matches: (block) =>
    (block.name === "Agent" || block.name === "Task") &&
    block.input?.run_in_background !== true &&
    JSON.stringify(block.input ?? {}).includes("600"),
};

/**
 * The other half: a plain foreground Bash blocks the turn exactly as an agent
 * does, and is the shape this project blocks on most — a build or a test run.
 * It runs a fixed 75 seconds, which is a firmer control than an agent whose
 * length is the model's to decide. A bare `sleep` is refused by the CLI, so
 * the wait is a loop that does work.
 */
const SLOW_BASH_ASK: Ask = {
  what: "the 75s command",
  text:
    "Run exactly one Bash command, in the foreground, and wait for it: " +
    "bash -c 'end=$((SECONDS+75)); n=0; while [ $SECONDS -lt $end ]; do n=$((n+1)); sleep 1; done; echo $n'. " +
    "Then say done. Do not use any other tool, and do not run it in the background.",
  matches: (block) =>
    block.name === "Bash" && String(block.input?.command ?? "").includes("SECONDS+75"),
};

/** Distinctive enough that no other turn says it by accident. */
const WORD = "PINEAPPLE";
const INTERJECTION = `Ignore what you are doing for a moment and reply with exactly the word ${WORD} and nothing else.`;

const LIMIT_MS = 300_000;

/** A stream that stays open and takes more messages after the first. */
function conversation(first: string) {
  const pending: string[] = [];
  let wake: () => void = () => {};
  let closed = false;

  async function* stream(): AsyncGenerator<unknown> {
    yield { type: "user", message: { role: "user", content: first }, parent_tool_use_id: null };
    while (!closed) {
      if (pending.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
        continue;
      }
      const text = pending.shift()!;
      yield { type: "user", message: { role: "user", content: text }, parent_tool_use_id: null };
    }
  }

  return {
    stream: stream(),
    send(text: string) {
      pending.push(text);
      wake();
    },
    close() {
      closed = true;
      wake();
    },
  };
}

interface Started {
  taskId: string;
  toolUseId: string | null;
  at: number;
}

interface Notified {
  taskId: string;
  at: number;
}

interface Run {
  backgrounded?: boolean;
  backgroundError?: string;
  started: Started[];
  notified: Notified[];
  /** The call the ask named — what the send has to land inside. */
  callId?: string;
  sentAt?: number;
  answeredAt?: number;
  settledAt?: number;
  /** The turn the interjection was answered in ended. */
  finishedAt?: number;
  results: string[];
}

type Order = "control" | "send-then-background" | "background-then-send";

function startedIds(run: Run): string[] {
  return run.started.map((task) => task.taskId);
}

function notifiedIds(run: Run): string[] {
  return run.notified.map((task) => task.taskId);
}

/** Every task the session announced has come back. */
function allSettled(run: Run): boolean {
  return run.started.length > 0 && startedIds(run).every((id) => notifiedIds(run).includes(id));
}

/**
 * The task the CLI announced for the call the ask named — the one the turn is
 * blocked on, read off `tool_use_id` rather than off "the first task", since
 * any other task out there answers a different question.
 */
function blockingTask(run: Run): { startedAt: number; notifiedAt?: number } | null {
  if (run.callId === undefined) return null;
  const started = run.started.find((task) => task.toolUseId === run.callId);
  if (!started) return null;
  return {
    startedAt: started.at,
    notifiedAt: run.notified.find((task) => task.taskId === started.taskId)?.at,
  };
}

function textOf(block: any): string {
  if (typeof block?.text === "string") return block.text;
  if (typeof block?.content === "string") return block.content;
  if (Array.isArray(block?.content)) return block.content.map(textOf).join(" ");
  return "";
}

async function probe(ask: Ask, order: Order): Promise<Run> {
  const run: Run = { started: [], notified: [], results: [] };

  const input = conversation(ask.text);
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
    } as any,
  });

  // The only thing that closes the stream early. **Not a grace period after
  // the turn's result**, which is what this was written with and what made the
  // settle read as missing: backgrounding a task is precisely what lets the
  // turn end while the task runs on, so a run cut off at the result cuts off
  // before the one edge it exists to watch for.
  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  // Once, on the first task the session announces, and only after a beat —
  // the agent has to be genuinely mid-run for the reading to mean anything.
  let interjected = false;
  async function interject(): Promise<void> {
    if (interjected) return;
    interjected = true;
    await new Promise((resolve) => setTimeout(resolve, 5_000));

    if (order === "background-then-send") {
      await background();
      run.sentAt = Date.now();
      input.send(INTERJECTION);
      return;
    }

    run.sentAt = Date.now();
    input.send(INTERJECTION);
    if (order === "send-then-background") {
      // A beat for the message to reach the CLI before the turn is let go.
      await new Promise((resolve) => setTimeout(resolve, 2_000));
      await background();
    }
  }

  async function background(): Promise<void> {
    if (typeof session.backgroundTasks !== "function") {
      run.backgroundError = "the SDK has no backgroundTasks";
      return;
    }
    try {
      run.backgrounded = await session.backgroundTasks();
    } catch (error: any) {
      run.backgroundError = error?.message ?? String(error);
    }
  }

  try {
    for await (const message of session as AsyncIterable<any>) {
      const subtype: string | undefined = message.subtype;

      if (subtype === "task_started" && message.task_id) {
        run.started.push({
          taskId: message.task_id,
          toolUseId: message.tool_use_id ?? null,
          at: Date.now(),
        });
      }
      if (subtype === "task_notification" && message.task_id) {
        run.notified.push({ taskId: message.task_id, at: Date.now() });
        run.settledAt ??= Date.now();
      }

      if (message.type === "assistant") {
        // On the call the ask named rather than on `task_started`: the send is
        // timed from the call, and the window it has to land in is read off the
        // task the CLI announces for that same call.
        for (const block of message.message?.content ?? []) {
          if (block?.type === "tool_use" && ask.matches(block)) {
            run.callId ??= block.id;
            void interject();
          }
          if (block?.type !== "text") continue;
          if (run.answeredAt === undefined && textOf(block).includes(WORD)) {
            run.answeredAt = Date.now();
          }
        }
      }

      // The blocking call's own result, wherever it comes back from.
      if (message.type === "user") {
        for (const block of message.message?.content ?? []) {
          if (block?.type !== "tool_result") continue;
          const text = textOf(block).trim();
          if (text) run.results.push(text.slice(0, 200));
        }
      }

      if (allSettled(run) && run.answeredAt !== undefined) break;
      if (message.type === "result" && run.answeredAt !== undefined) {
        run.finishedAt ??= Date.now();
        if (run.started.length === 0) break;
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

/** Milliseconds from the message being sent to it being answered, or null. */
function lag(run: Run): number | null {
  if (run.sentAt === undefined || run.answeredAt === undefined) return null;
  return run.answeredAt - run.sentAt;
}

/**
 * Answered while the task it was blocked on was still running. A run that never
 * saw the task come back cannot say that, so it reads false: taken the other way
 * round, a run whose settle went missing — the one failure this probe is here to
 * catch — would have counted as the proof.
 */
function answeredEarly(run: Run): boolean {
  if (run.answeredAt === undefined || run.settledAt === undefined) return false;
  return run.answeredAt < run.settledAt;
}

function describe(name: string, run: Run): void {
  const wait = lag(run);
  const task = blockingTask(run);
  console.log(`\n${name}`);
  console.log(
    `  started: ${run.started.length}, notified: ${run.notified.length}` +
      `, backgrounded: ${run.backgrounded ?? "not asked"}` +
      (run.backgroundError ? ` (${run.backgroundError})` : ""),
  );
  if (run.sentAt === undefined || task === null) {
    console.log(
      `  sent: ${run.sentAt === undefined ? "never — the ask's own call was never made" : "no task_started named that call"}`,
    );
  } else {
    console.log(
      `  sent: ${run.sentAt - task.startedAt}ms after the call's task_started, ` +
        (task.notifiedAt === undefined
          ? "and its task_notification never arrived"
          : `${task.notifiedAt - run.sentAt}ms before its task_notification`),
    );
  }
  console.log(
    `  answered: ${run.answeredAt === undefined ? "never" : `${wait}ms after sending`}` +
      `, task still running when it did: ${answeredEarly(run)}`,
  );
  for (const result of run.results) console.log(`  result: ${result.replace(/\s+/g, " ")}`);
}

/** The run acted inside the phase it claims to measure, or it measured nothing. */
function checkSentInside(run: Run, what: string): void {
  const task = blockingTask(run);
  check(
    run.sentAt !== undefined &&
      task !== null &&
      task.notifiedAt !== undefined &&
      run.sentAt > task.startedAt &&
      run.sentAt < task.notifiedAt,
    `the message was sent inside ${what}'s own run — after its task_started and before its task_notification`,
  );
}

try {
  const control = await probe(SLOW_AGENT_ASK, "control");
  describe("agent control — a message sent into a blocked turn, nothing backgrounded", control);
  check(control.started.length > 0, "the control's agent announced a task (control's control)");
  checkSentInside(control, SLOW_AGENT_ASK.what);
  check(
    !answeredEarly(control),
    "the control does NOT answer while the agent runs — if it does, the agent was too quick and the runs below measure nothing",
  );

  const after = await probe(SLOW_AGENT_ASK, "send-then-background");
  describe("agent — send, then background", after);
  check(after.backgroundError === undefined, "backgroundTasks is accepted");
  check(after.backgrounded === true, "it reports having moved something");
  checkSentInside(after, SLOW_AGENT_ASK.what);
  check(
    answeredEarly(after),
    "the waiting message is answered while the agent is still running — the whole point",
  );
  check(
    startedIds(after).every((id) => notifiedIds(after).includes(id)),
    "the backgrounded agent still settles by notification, the one edge the host removes on",
  );

  const before = await probe(SLOW_AGENT_ASK, "background-then-send");
  describe("agent — background, then send", before);
  check(before.started.length > 0, "this order's agent announced a task too");
  check(before.backgrounded === true, "and backgroundTasks reports having moved it");
  checkSentInside(before, SLOW_AGENT_ASK.what);
  check(
    answeredEarly(before),
    "the other order answers early too — if only one order works, the host has to use that one",
  );

  // The half the gate is actually written for. A foreground Bash blocks the
  // turn without announcing a task, so nothing on the socket knows it is out
  // there — and the command runs a fixed 75 seconds, which is a firmer control
  // than an agent whose length is the model's to decide.
  const bashControl = await probe(SLOW_BASH_ASK, "control");
  describe("bash control — a message sent into a turn blocked on a shell command", bashControl);
  // Measured, and the opposite of what this probe was written expecting: a
  // foreground Bash long enough to be worth backgrounding *does* announce a
  // task, where `foreground-task-probe.ts`'s `echo hi` announces none. The
  // reading that survives is the one that matters here — a task set says
  // something is running, and says nothing about whether a message can be
  // read. This run is blocked with its task announced.
  check(
    bashControl.started.length > 0 && !answeredEarly(bashControl),
    "the control is blocked *with* its task announced — a task set is not a reading of whether the turn can take a message",
  );
  checkSentInside(bashControl, SLOW_BASH_ASK.what);
  check(
    bashControl.answeredAt === undefined || lag(bashControl)! > 30_000,
    "the control waits out the command rather than answering during it",
  );

  const bash = await probe(SLOW_BASH_ASK, "send-then-background");
  describe("bash — send, then background", bash);
  check(bash.backgroundError === undefined, "backgroundTasks is accepted for a shell command too");
  // The lag below is only a reading of the 75 seconds because the send is inside
  // them: sent after the command returned, a fast answer says nothing at all.
  checkSentInside(bash, SLOW_BASH_ASK.what);
  check(
    bash.answeredAt !== undefined && lag(bash)! < 30_000,
    "the waiting message is answered long before the 75s command could have ended",
  );
  // The reading the row rests on. The Bash call itself really does settle when
  // it is converted — the result is `Command was manually backgrounded…`, not
  // a launch receipt the pane refuses — so from that moment `session.tasks` is
  // the only thing saying the command is still running. A conversion the
  // socket did not name would leave a live build looking finished.
  check(
    bash.started.length > 0,
    "the task survives the conversion — `session.tasks` is all that keeps the row honest once the call has settled",
  );
  check(
    startedIds(bash).every((id) => notifiedIds(bash).includes(id)),
    "and it settles by notification, so the host's set empties again",
  );

} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\nbackground-foreground-task: ${failures.length} check(s) failed`
    : "\nbackground-foreground-task: all checks passed",
);
process.exit(failures.length ? 1 : 0);
