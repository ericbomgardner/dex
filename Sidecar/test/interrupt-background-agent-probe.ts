/**
 * What `interrupt` does to a background agent when the session is idle, and
 * what the stream says while that agent works.
 *
 * A session launches an agent in the background (or resumes a finished one
 * with SendMessage), its turn ends, and the agent runs on with the parent at
 * the prompt. Measured here, for both kinds: the agent's own turns arrive on
 * the parent's stream as `assistant`/`user` messages with `parent_tool_use_id`
 * set — the host used to read those as the parent working, and nothing ever
 * said idle again; `interrupt` kills the agent; the stream says so at once
 * (`task_notification`, status `stopped`); the agent's own file ends with
 * `[Request interrupted by user]`; and the parent transcript says nothing at
 * all — no interruption, no notification.
 *
 * Found 2026-09-10 on a resumed agent: Stop on the "Main agent" row did
 * nothing visible, the agent was in fact dead, and the row spun until the
 * next message.
 */
import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const LIMIT_MS = 180_000;
const AFTER_INTERRUPT_MS = 20_000;
const IDLE_BEFORE_INTERRUPT_MS = 8_000;
const MAX_IDLE_BEFORE_INTERRUPT_MS = 45_000;

const scratch = mkdtempSync(path.join(tmpdir(), "dex-interrupt-bg-"));
const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

/** An input stream that stays open and takes more messages, as the host's does. */
function heldOpen(first: string): { stream: AsyncGenerator<unknown>; send: (text: string) => void; close: () => void } {
  const queue: string[] = [first];
  let wake: () => void = () => {};
  let closed = false;
  const poke = () => wake();
  async function* stream(): AsyncGenerator<unknown> {
    while (!closed) {
      const text = queue.shift();
      if (text !== undefined) {
        yield { type: "user", message: { role: "user", content: text }, parent_tool_use_id: null };
        continue;
      }
      await new Promise<void>((resolve) => {
        wake = resolve;
      });
    }
  }
  return {
    stream: stream(),
    send: (text) => {
      queue.push(text);
      poke();
    },
    close: () => {
      closed = true;
      poke();
    },
  };
}

function transcriptPath(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const file = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(file)) return file;
  }
  return null;
}

function records(file: string): any[] {
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function textOf(record: any): string {
  const content = record?.message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((block: any) => block?.type === "text")
      .map((block: any) => block.text)
      .join("\n");
  }
  return "";
}

// The agent has to be working when the interrupt lands. Left to itself it
// backgrounds a five-minute command and ends its turn, and the interrupt then
// hits the parent's task-notification turn instead (seen at CLI v2.1.280).
// The warm-up gives it a turn after the parent's result: its first call alone
// can beat that result to the stream and then sit silent (2026-10-19).
const LONG_WORK = [
  "First run the Bash command `sleep 15; echo warm`.",
  "Then run the Bash command `for i in $(seq 1 100); do echo tick $i; sleep 3; done` and report the output.",
  "Run both in the foreground with the Bash tool's timeout set to 330000; do not set run_in_background, and wait for each to finish before going on.",
].join(" ");

const LAUNCH_LONG = [
  "Use the Agent tool with run_in_background: true to launch one agent.",
  `Its prompt: ${LONG_WORK}`,
  "Do not wait for it. As soon as the launch receipt comes back, reply with the single word launched and end your turn.",
].join(" ");

const LAUNCH_SHORT = [
  "Use the Agent tool with run_in_background: true to launch one agent.",
  "Its prompt: reply with the single word hello and stop.",
  "Do not wait for it. As soon as the launch receipt comes back, reply with the single word launched and end your turn.",
].join(" ");

const RESUME_LONG = [
  "The agent you launched is finished. Use SendMessage to continue it (its agentId is in the launch receipt).",
  `The message: ${LONG_WORK}`,
  "Do not wait for it. Once SendMessage returns, reply with the single word sent and end your turn.",
].join(" ");

type Scenario = "launched" | "resumed";

interface Run {
  scenario: Scenario;
  sessionId: string | null;
  firstTaskId: string | null;
  taskEvents: string[];
  task: { taskId: string; toolUseId: string | null } | null;
  turnEndedBeforeInterrupt: boolean;
  subagentTurnsWhileIdle: number;
  interruptedAt: number | null;
  interruptError: string | null;
  streamAfterInterrupt: string[];
  notification: { status: string | null; at: number } | null;
  agentDoneBeforeInterrupt: boolean;
  resultAfterInterrupt: boolean;
}

async function measure(scenario: Scenario): Promise<Run> {
  const run: Run = {
    scenario,
    sessionId: null,
    firstTaskId: null,
    taskEvents: [],
    task: null,
    turnEndedBeforeInterrupt: false,
    subagentTurnsWhileIdle: 0,
    interruptedAt: null,
    interruptError: null,
    streamAfterInterrupt: [],
    notification: null,
    agentDoneBeforeInterrupt: false,
    resultAfterInterrupt: false,
  };
  const input = heldOpen(scenario === "launched" ? LAUNCH_LONG : LAUNCH_SHORT);
  let resumeSent = false;
  let sawSendMessage = false;
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
  let closer: ReturnType<typeof setTimeout> | null = null;

  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.session_id) run.sessionId = message.session_id;
      const subtype: string | undefined = message.subtype;
      const tagged = typeof subtype === "string" && subtype.startsWith("task");
      if (message.type === "assistant" && Array.isArray(message.message?.content)) {
        if (message.message.content.some((block: any) => block?.type === "tool_use" && block.name === "SendMessage")) {
          sawSendMessage = true;
        }
      }
      if (tagged || message.type === "result") {
        const line = `${subtype ?? message.type}${message.status ? `/${message.status}` : ""}${message.task_id ? ` ${message.task_id}` : ""}`;
        run.taskEvents.push(line);
        if (run.interruptedAt !== null) run.streamAfterInterrupt.push(line);
      }
      if (scenario === "resumed" && !resumeSent) {
        if (subtype === "task_started" && message.task_id && !run.firstTaskId) {
          run.firstTaskId = message.task_id;
        }
        if (subtype === "task_notification" && message.task_id === run.firstTaskId) {
          resumeSent = true;
          input.send(RESUME_LONG);
        }
        continue;
      }
      if (subtype === "task_started" && message.task_id && !run.task) {
        run.task = { taskId: message.task_id, toolUseId: message.tool_use_id ?? null };
      }
      if (
        run.turnEndedBeforeInterrupt &&
        run.interruptedAt === null &&
        (message.type === "assistant" || message.type === "user") &&
        message.parent_tool_use_id
      ) {
        run.subagentTurnsWhileIdle += 1;
      }
      const armed = scenario === "launched" ? run.task !== null : sawSendMessage;
      if (message.type === "result" && run.interruptedAt === null && armed && !run.turnEndedBeforeInterrupt) {
        run.turnEndedBeforeInterrupt = true;
        // Off a timer rather than awaited here, so the loop keeps reading the
        // agent's turns for the stretch the parent is idle.
        // A resumed agent can think past the floor before its first call, and
        // an interrupt sent then measures an agent that never spoke.
        const idleSince = Date.now();
        const fire = async () => {
          const waited = Date.now() - idleSince;
          if (run.subagentTurnsWhileIdle === 0 && waited < MAX_IDLE_BEFORE_INTERRUPT_MS) {
            setTimeout(fire, 500);
            return;
          }
          run.interruptedAt = Date.now();
          try {
            await session.interrupt();
          } catch (error: any) {
            run.interruptError = error?.message ?? String(error);
          }
          closer = setTimeout(() => {
            input.close();
            session.close?.();
          }, AFTER_INTERRUPT_MS);
        };
        setTimeout(fire, IDLE_BEFORE_INTERRUPT_MS);
      } else if (message.type === "result" && run.interruptedAt !== null) {
        run.resultAfterInterrupt = true;
      }
      if (
        subtype === "task_notification" &&
        run.task &&
        message.task_id === run.task.taskId &&
        run.interruptedAt === null
      ) {
        run.agentDoneBeforeInterrupt = true;
      }
      if (
        subtype === "task_notification" &&
        run.task &&
        message.task_id === run.task.taskId &&
        run.interruptedAt !== null
      ) {
        run.notification = { status: message.status ?? null, at: Date.now() - run.interruptedAt };
      }
    }
  } finally {
    clearTimeout(deadline);
    if (closer) clearTimeout(closer);
    input.close();
    session.close?.();
  }
  return run;
}

async function report(scenario: Scenario): Promise<void> {
  console.log(`\n== ${scenario} ==`);
  const run = await measure(scenario);
  console.log(JSON.stringify(run, null, 2));

  check(
    run.task !== null,
    run.scenario === "launched"
      ? "the background agent announced itself with task_started"
      : "the resumed agent announced itself with task_started (a resume is a task too)",
  );
  check(run.turnEndedBeforeInterrupt, "the launching turn ended before the interrupt was sent (session idle, task out)");
  check(
    !run.agentDoneBeforeInterrupt,
    "the agent was still working when the interrupt was sent (no task_notification for it before)",
  );
  check(run.interruptError === null, `interrupt on an idle session did not throw (${run.interruptError ?? "ok"})`);

  const file = run.sessionId ? transcriptPath(run.sessionId) : null;
  check(file !== null, "the parent transcript was found");
  const agentID = run.task?.taskId ?? run.firstTaskId;
  if (!file || !agentID) return;

  await new Promise((resolve) => setTimeout(resolve, 2_000));
  const agentFile = path.join(
    path.dirname(file),
    path.basename(file, ".jsonl"),
    "subagents",
    `agent-${agentID}.jsonl`,
  );
  check(existsSync(agentFile), `the agent's own transcript exists at ${agentFile}`);

  const parent = records(file);
  const parentInterruption = parent.some(
    (record) => record.type === "user" && textOf(record).trim().startsWith("[Request interrupted by user"),
  );
  const parentStopNotice = parent.some((record) => {
    const raw = JSON.stringify(record);
    if (!raw.includes("task-notification") || !raw.includes(agentID)) return false;
    const status = raw.match(/<status>([^<]*)<\/status>/)?.[1];
    return status !== undefined && status !== "completed";
  });
  const agent = existsSync(agentFile) ? records(agentFile) : [];
  const agentTurns = agent.filter((record) => record.type === "user" || record.type === "assistant");
  const last = agentTurns[agentTurns.length - 1];
  const agentEndsInterrupted =
    last?.type === "user" && textOf(last).trim().startsWith("[Request interrupted by user");

  console.log(
    JSON.stringify(
      {
        parentInterruption,
        parentStopNotice,
        agentRecords: agent.length,
        agentLastText: textOf(last).slice(0, 80),
      },
      null,
      2,
    ),
  );

  check(agentEndsInterrupted, "the agent's own file ends with [Request interrupted by user] — the interrupt reached the agent");
  check(!parentInterruption, "the parent transcript records no interruption of its own (there was no turn to interrupt)");
  check(
    run.notification !== null,
    `the stream carried a task_notification for the interrupted agent (${run.notification ? `${run.notification.status} after ${run.notification.at}ms` : "none in " + AFTER_INTERRUPT_MS + "ms"})`,
  );
  check(
    run.subagentTurnsWhileIdle > 0,
    `the agent's turns reached the parent's stream while the parent was idle, marked parent_tool_use_id (${run.subagentTurnsWhileIdle})`,
  );
  check(
    !parentStopNotice,
    "the parent transcript records no task-notification for the interrupted agent — the socket is the only word",
  );
}

try {
  const only = process.env.PROBE_SCENARIO as Scenario | undefined;
  if (only !== "resumed") await report("launched");
  if (only !== "launched") await report("resumed");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(
  failures.length
    ? `\ninterrupt-background-agent-probe: ${failures.length} check(s) failed`
    : "\ninterrupt-background-agent-probe: all checks passed",
);
process.exit(failures.length ? 1 : 0);
