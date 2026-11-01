/**
 * What `priority: "now"` on a user message does to a working session.
 *
 *   node test/now-priority-probe.ts
 *
 * Unset, a message's priority is "next": read at the next tool boundary. The
 * CLI's queue takes "now" too, and on a read of the bundled binary it aborts
 * the running step (`_abortOnNowPriorityCommand`). This measures what that
 * costs and saves, against a plain send as the control:
 *
 *  1. How fast a "now" message is answered, mid-generation and mid-Bash.
 *  2. What the abort takes with it: the partial reply, the Bash command (does
 *     its last line ever run), and a foreground agent (does it settle
 *     `completed` or `stopped`).
 *  3. The host's send, which since CLI v2.1.281's terminal send-now is
 *     `backgroundTasks()` and then "now": does the agent survive it.
 *  4. A send while a call waits to run, on a slow PreToolUse hook and in auto
 *     mode: "now" throws the call away, and the host's cut-in, held until the
 *     call has a task or a result, moves it instead.
 *  5. What the transcript writes, printed rather than asserted.
 *
 * Every run asserts it sent inside the phase it claims to measure.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-now-priority-"));

const WORD = "PINEAPPLE";
const INTERJECTION = `Ignore what you are doing for a moment and reply with exactly the word ${WORD} and nothing else. Then carry on with what you were doing.`;
const LIMIT_MS = 300_000;

type Phase = "generating" | "bash" | "agent";
type Priority = "now" | undefined;
/**
 * What goes with the send: a priority, or what the host does beside a plain
 * send — `backgroundTasks` at once, and again on each `task_started` while the
 * message waits. `host` is the host's whole cut-in: held until the call has a
 * task or a result, then `backgroundTasks`, then "now".
 */
type Lever = Priority | "background" | "background-now" | "host";

interface Ask {
  phase: Phase;
  text: string;
  /** The call the send is timed from; absent for a phase with no call. */
  matches?(block: any): boolean;
}

const GENERATE: Ask = {
  phase: "generating",
  text:
    "Without using any tools, write out every number from 1 to 400 in words, one per line. " +
    "Write them all — do not summarise or skip ahead. Then say done.",
};

const marker = path.join(scratch, "bash-finished");
const BASH: Ask = {
  phase: "bash",
  text:
    "Run exactly one Bash command, in the foreground, and wait for it: " +
    `bash -c 'end=$((SECONDS+20)); while [ $SECONDS -lt $end ]; do sleep 1; done; touch ${marker}; echo ok'. ` +
    "Then say done. Do not use any other tool, and do not run it in the background.",
  matches: (block) => block.name === "Bash" && String(block.input?.command ?? "").includes("SECONDS+20"),
};

const AGENT: Ask = {
  phase: "agent",
  text:
    "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
    "description 'count slowly', and run_in_background: false, giving it this task: " +
    "Write out every number from 1 to 300, one per line, spelled in words. Write them " +
    "all — do not summarise or skip ahead. " +
    "Then say done. Do not use any other tool, and do not do the counting yourself.",
  matches: (block) =>
    (block.name === "Agent" || block.name === "Task") &&
    block.input?.run_in_background !== true &&
    JSON.stringify(block.input ?? {}).includes("300"),
};

function conversation(first: string) {
  const pending: unknown[] = [];
  let wake: () => void = () => {};
  let closed = false;
  const message = (content: string, priority?: Priority) => ({
    type: "user",
    message: { role: "user", content },
    parent_tool_use_id: null,
    ...(priority ? { priority } : {}),
  });

  async function* stream(): AsyncGenerator<unknown> {
    yield message(first);
    while (!closed) {
      if (pending.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
        continue;
      }
      yield pending.shift();
    }
  }

  return {
    stream: stream(),
    send(text: string, priority: Priority) {
      pending.push(message(text, priority));
      wake();
    },
    close() {
      closed = true;
      wake();
    },
  };
}

interface Run {
  sessionId?: string;
  sentAt?: number;
  /** The step the send was meant to land in: first text delta, or the call. */
  phaseStartedAt?: number;
  /** That step ending: its assistant message, or the call's result. */
  phaseEndedAt?: number;
  answeredAt?: number;
  results: { subtype: string; at: number; stop?: string }[];
  /** Assistant text written after the answer — did the turn carry on. */
  textAfter: string;
  /** How far the generation got in the message the send cut into. */
  interruptedText?: string;
  toolResult?: string;
  taskStartedAt?: number;
  taskStatus?: string;
  taskSettledAt?: number;
  backgrounded?: boolean | string;
  markerExisted?: boolean;
  /** How long the host lever held the send for the call to start. */
  heldFor?: number;
}

function textOf(block: any): string {
  if (typeof block?.text === "string") return block.text;
  if (typeof block?.content === "string") return block.content;
  if (Array.isArray(block?.content)) return block.content.map(textOf).join(" ");
  return "";
}

async function probe(
  ask: Ask,
  lever: Lever,
  sendAfter = 5_000,
  permissionMode = "bypassPermissions",
  /** A PreToolUse hook that takes this long, standing in for auto mode's classifier. */
  holdBeforeRunMs = 0,
): Promise<Run> {
  const priority: Priority = lever === "now" || lever === "background-now" || lever === "host" ? "now" : undefined;
  rmSync(marker, { force: true });
  const run: Run = { results: [], textAfter: "" };
  const input = conversation(ask.text);
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode,
      includePartialMessages: true,
      ...(holdBeforeRunMs > 0
        ? {
            hooks: {
              PreToolUse: [
                {
                  matcher: "Bash",
                  hooks: [async () => (await new Promise((resolve) => setTimeout(resolve, holdBeforeRunMs)), {})],
                },
              ],
            },
          }
        : {}),
    } as any,
  });

  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  let interjected = false;
  let callId: string | undefined;
  let streamed = "";
  let streamedSinceSend = "";
  function background(): void {
    session.backgroundTasks?.().then(
      (moved: boolean) => (run.backgrounded = moved),
      (error: any) => (run.backgrounded = `threw: ${error?.message ?? error}`),
    );
  }
  function interject(delay: number): void {
    if (interjected) return;
    interjected = true;
    setTimeout(async () => {
      run.sentAt = Date.now();
      streamedSinceSend = "";
      // What the terminal's send-now does since CLI v2.1.281: move the running
      // tasks off the turn, then cut in.
      if (lever === "host") {
        try {
          await session.backgroundTasks();
        } catch {}
        while (run.taskStartedAt === undefined && run.phaseEndedAt === undefined) {
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        run.heldFor = Date.now() - run.sentAt;
      }
      if (lever === "background-now" || lever === "host") {
        try {
          run.backgrounded = await session.backgroundTasks();
        } catch (error: any) {
          run.backgrounded = `threw: ${error?.message ?? error}`;
        }
      }
      input.send(INTERJECTION, priority);
      if (lever === "background") background();
    }, delay);
  }

  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.type === "system" && message.subtype === "init") run.sessionId ??= message.session_id;

      // Answered at the first streamed word, not the finished message: a
      // model that answers and then resumes its long reply in the same block
      // would otherwise read as slow as the reply.
      if (message.type === "stream_event" && message.parent_tool_use_id == null) {
        const delta = message.event?.delta;
        if (delta?.type === "text_delta") {
          if (run.sentAt === undefined) streamed += delta.text;
          else streamedSinceSend += delta.text;
          if (run.sentAt !== undefined && run.answeredAt === undefined && streamedSinceSend.includes(WORD)) {
            run.answeredAt = Date.now();
          }
          if (ask.phase === "generating" && run.phaseStartedAt === undefined) {
            run.phaseStartedAt = Date.now();
            interject(3_000);
          }
        }
      }

      if (message.type === "assistant" && message.parent_tool_use_id == null) {
        for (const block of message.message?.content ?? []) {
          if (block?.type === "tool_use" && ask.matches?.(block) && callId === undefined) {
            callId = block.id;
            run.phaseStartedAt = Date.now();
            interject(sendAfter);
          }
          if (block?.type !== "text") continue;
          const text = textOf(block);
          if (run.sentAt !== undefined && text.includes(WORD)) {
            run.textAfter += text.split(WORD).slice(1).join(WORD);
            continue;
          }
          if (run.answeredAt !== undefined) run.textAfter += text;
          else if (ask.phase === "generating" && run.phaseEndedAt === undefined && run.phaseStartedAt !== undefined) {
            run.phaseEndedAt = Date.now();
          }
        }
      }

      if (ask.phase === "generating" && run.sentAt !== undefined && run.interruptedText === undefined) {
        run.interruptedText = streamed;
      }

      if (message.type === "user" && callId !== undefined) {
        for (const block of message.message?.content ?? []) {
          if (block?.type === "tool_result" && block.tool_use_id === callId && run.phaseEndedAt === undefined) {
            run.phaseEndedAt = Date.now();
            run.toolResult = textOf(block).trim().slice(0, 200);
          }
        }
      }

      if (message.type === "system" && message.subtype === "task_started") {
        run.taskStartedAt ??= Date.now();
        if ((lever === "background" || lever === "host") && run.sentAt !== undefined && run.answeredAt === undefined)
          background();
      }

      if (message.type === "system" && message.subtype === "task_notification" && message.tool_use_id === callId) {
        run.taskStatus = message.status;
        run.taskSettledAt = Date.now();
      }

      if (message.type === "result") {
        run.results.push({ subtype: message.subtype, at: Date.now(), stop: message.stop_reason ?? undefined });
        const agentDone = ask.phase !== "agent" || run.taskSettledAt !== undefined;
        if (run.answeredAt !== undefined && agentDone) break;
      }
    }
  } finally {
    clearTimeout(deadline);
    input.close();
    session.close?.();
  }

  // Closing the session kills a backgrounded command, so only a command left
  // in the foreground can say whether its last line ran.
  if (ask.phase === "bash" && lever !== "background" && lever !== "background-now" && lever !== "host") {
    await new Promise((resolve) => setTimeout(resolve, 25_000));
    run.markerExisted = existsSync(marker);
  }
  return run;
}

/** Records the CLI wrote from just before the send to the answer. */
function transcriptAround(run: Run): string[] {
  if (!run.sessionId || run.sentAt === undefined) return ["(no session id or no send)"];
  const root = path.join(homedir(), ".claude", "projects");
  for (const dir of readdirSync(root)) {
    const file = path.join(root, dir, `${run.sessionId}.jsonl`);
    if (!existsSync(file)) continue;
    const from = run.sentAt - 1_000;
    const to = (run.answeredAt ?? run.sentAt) + 1_000;
    return readFileSync(file, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
      .filter((record) => {
        const at = Date.parse(record.timestamp ?? "");
        return at >= from && at <= to;
      })
      .map((record) => {
        const content = record.message?.content;
        const blocks = Array.isArray(content)
          ? content.map((block: any) => `${block.type}:${textOf(block).slice(0, 60).replace(/\s+/g, " ")}`).join(" | ")
          : String(content ?? record.content ?? record.attachment?.type ?? "").slice(0, 80).replace(/\s+/g, " ");
        return `${record.type}${record.operation ? `/${record.operation}` : ""}${record.priority ? ` priority=${record.priority}` : ""} ${blocks}`;
      });
  }
  return ["(transcript not found)"];
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

function lag(run: Run): number | null {
  return run.sentAt !== undefined && run.answeredAt !== undefined ? run.answeredAt - run.sentAt : null;
}

function sentInside(run: Run): boolean {
  return (
    run.sentAt !== undefined &&
    run.phaseStartedAt !== undefined &&
    run.sentAt > run.phaseStartedAt &&
    (run.phaseEndedAt === undefined || run.sentAt < run.phaseEndedAt)
  );
}

function describe(name: string, run: Run): void {
  console.log(`\n${name}`);
  console.log(
    `  sent ${run.sentAt !== undefined && run.phaseStartedAt !== undefined ? run.sentAt - run.phaseStartedAt : "?"}ms into the phase; ` +
      `phase ended ${run.phaseEndedAt !== undefined && run.sentAt !== undefined ? `${run.phaseEndedAt - run.sentAt}ms after the send` : "never"}`,
  );
  console.log(`  answered: ${lag(run) ?? "never"}ms after sending`);
  console.log(`  results: ${run.results.map((result) => `${result.subtype}/${result.stop ?? "-"} at +${run.sentAt ? result.at - run.sentAt : "?"}ms`).join(", ") || "none"}`);
  if (run.interruptedText !== undefined) {
    const lines = run.interruptedText.trim().split("\n");
    console.log(`  streamed before the answer: ${lines.length} lines, last "${lines.at(-1)?.slice(0, 60)}"`);
  }
  if (run.toolResult !== undefined) console.log(`  call's result: ${run.toolResult.replace(/\s+/g, " ")}`);
  if (run.backgrounded !== undefined) console.log(`  backgroundTasks: ${run.backgrounded}`);
  if (run.taskStartedAt !== undefined && run.sentAt !== undefined) {
    console.log(`  task_started ${run.taskStartedAt - run.sentAt}ms after the send`);
  }
  if (run.taskStatus !== undefined) console.log(`  its task settled: ${run.taskStatus} at +${run.taskSettledAt! - run.sentAt!}ms`);
  if (run.markerExisted !== undefined) console.log(`  command's last line ran: ${run.markerExisted}`);
  console.log(`  text after the answer: ${run.textAfter.length} chars${run.textAfter ? ` — "${run.textAfter.slice(0, 80).replace(/\s+/g, " ")}"` : ""}`);
  console.log("  transcript:");
  for (const line of transcriptAround(run)) console.log(`    ${line}`);
}

try {
  const genControl = await probe(GENERATE, undefined);
  describe("generating, plain send (control)", genControl);
  check(sentInside(genControl), "control: sent while the reply was still streaming");
  check(
    genControl.phaseEndedAt !== undefined && genControl.answeredAt !== undefined && genControl.answeredAt > genControl.phaseEndedAt,
    "control: answered only after the reply finished — if not, the reply was too short to measure anything",
  );

  const genNow = await probe(GENERATE, "now");
  describe("generating, priority now", genNow);
  check(sentInside(genNow), "now: sent while the reply was still streaming");
  check(
    genNow.phaseEndedAt !== undefined && genNow.sentAt !== undefined && genNow.phaseEndedAt - genNow.sentAt < 1_000,
    "now: the streaming reply is cut off within a second of the send",
  );
  check(
    lag(genNow) !== null && lag(genControl) !== null && lag(genNow)! < lag(genControl)! / 2,
    "now: answered in under half the control's wait",
  );
  check(genNow.results[0]?.at - genNow.sentAt! < 1_000, "now: the cut step ends with a result of its own, before the answer's turn");

  const bashControl = await probe(BASH, undefined);
  describe("20s foreground Bash, plain send (control)", bashControl);
  check(sentInside(bashControl), "control: sent while the command was running");
  check(bashControl.markerExisted === true, "control: the command ran to its last line");

  const bashNow = await probe(BASH, "now");
  describe("20s foreground Bash, priority now", bashNow);
  check(sentInside(bashNow), "now: sent while the command was running");
  // Measured, against the expectation this was written with: the abort cuts a
  // streaming step and a foreground agent, but a running Bash is left to finish
  // and the message waits for it exactly as a plain send does.
  check(
    bashNow.markerExisted === true && bashNow.phaseEndedAt !== undefined && bashNow.sentAt !== undefined &&
      bashNow.phaseEndedAt - bashNow.sentAt > 12_000,
    "now: a running foreground Bash is NOT cut — it runs to its last line and the message waits for it",
  );

  // What the host does, sent a second into the command. A foreground Bash is
  // announced as a task some 3.5s in, and `backgroundTasks` before that answers
  // true and moves nothing — which is what held real messages behind builds.
  // Only the retry on `task_started` can unblock this one.
  const bashBackground = await probe(BASH, "background", 1_000);
  describe("20s foreground Bash, plain send + backgroundTasks at once and on task_started (the host)", bashBackground);
  check(sentInside(bashBackground), "host: sent while the command was running");
  check(
    bashBackground.taskStartedAt !== undefined && bashBackground.sentAt !== undefined &&
      bashBackground.taskStartedAt > bashBackground.sentAt,
    "host: sent before the command was announced as a task — the window the retry is for",
  );
  check(
    bashBackground.toolResult?.includes("backgrounded") &&
      bashBackground.phaseEndedAt! - bashBackground.taskStartedAt! < 2_000,
    "host: the call comes back backgrounded within 2s of the task being announced",
  );
  // The command runs 20s from the call; what follows the move is the model's
  // own thinking, which is not the host's to shorten.
  check(
    bashBackground.answeredAt !== undefined && bashBackground.answeredAt < bashBackground.phaseStartedAt! + 20_000,
    "host: answered before the command could have ended",
  );

  const agentNow = await probe(AGENT, "now");
  describe("foreground agent, priority now", agentNow);
  check(sentInside(agentNow), "now: sent while the agent was running");
  check(agentNow.answeredAt !== undefined && lag(agentNow)! < 20_000, "now: answered while the agent would still have been counting");
  check(agentNow.taskStatus === "stopped", "now: the foreground agent is killed, settling `stopped` — its work is lost");

  // The terminal's send-now since CLI v2.1.281, done from the host: move the
  // running tasks off the turn first, then send with "now".
  const agentBackgroundNow = await probe(AGENT, "background-now");
  describe("foreground agent, backgroundTasks then priority now", agentBackgroundNow);
  check(sentInside(agentBackgroundNow), "background+now: sent while the agent was running");
  check(agentBackgroundNow.backgrounded === true, "background+now: backgroundTasks says it moved something");
  check(
    agentBackgroundNow.answeredAt !== undefined && lag(agentBackgroundNow)! < 20_000,
    "background+now: answered while the agent would still have been counting",
  );
  check(
    agentBackgroundNow.taskStatus === "completed",
    "background+now: the agent is not killed — it runs on and settles `completed`",
  );

  const bashBackgroundNow = await probe(BASH, "background-now");
  describe("20s foreground Bash, backgroundTasks then priority now", bashBackgroundNow);
  check(sentInside(bashBackgroundNow), "background+now: sent while the command was running");
  check(bashBackgroundNow.toolResult?.includes("backgrounded"), "background+now: the command is moved, not cut");
  check(
    bashBackgroundNow.answeredAt !== undefined && bashBackgroundNow.answeredAt < bashBackgroundNow.phaseStartedAt! + 20_000,
    "background+now: answered before the command could have ended",
  );

  // Before a call runs it can wait on its PreToolUse hooks and, in auto mode,
  // the classifier: seconds with no task and no result that look like a
  // running command from outside. A hook that takes 5s stands in for both, so
  // the send lands inside that stretch every time. Measured on CLI v2.1.314:
  // "now" there kills the call, and in a real auto-mode session it came back
  // `Command was aborted before completion`.
  const hookNow = await probe(BASH, "background-now", 1_000, "bypassPermissions", 5_000);
  describe("5s PreToolUse hook, backgroundTasks then priority now a second in", hookNow);
  check(sentInside(hookNow), "hook, background+now: sent while the call was waiting to run");
  check(
    hookNow.phaseEndedAt !== undefined && hookNow.phaseEndedAt - hookNow.sentAt! < 1_000 && !hookNow.toolResult?.includes("ok"),
    `hook, background+now: the call is thrown away before it runs (${hookNow.toolResult ?? "no result"})`,
  );

  const hookHost = await probe(BASH, "host", 1_000, "bypassPermissions", 5_000);
  describe("5s PreToolUse hook, the host's cut-in a second in", hookHost);
  check(sentInside(hookHost), "hook, host: sent while the call was waiting to run");
  check(hookHost.toolResult?.includes("backgrounded"), `hook, host: the command runs and is moved, not cut (${hookHost.toolResult ?? "no result"})`);

  // The same in auto mode, where how long the classifier takes is not ours to set.
  const autoHost = await probe(BASH, "host", 1_000, "auto");
  describe("auto mode, 20s foreground Bash, the host's cut-in a second in", autoHost);
  check(sentInside(autoHost), "auto, host: sent while the call was being started");
  check(autoHost.toolResult?.includes("backgrounded"), `auto, host: the command is moved, not cut (${autoHost.toolResult ?? "no result"})`);
  check(
    autoHost.answeredAt !== undefined && autoHost.answeredAt < autoHost.phaseStartedAt! + 20_000,
    `auto, host: answered before the command could have ended (held ${autoHost.heldFor}ms)`,
  );
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nnow-priority: ${failures.length} check(s) failed` : "\nnow-priority: all checks passed");
process.exit(failures.length ? 1 : 0);
