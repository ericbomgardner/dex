/**
 * When a host that has thrown may go: never while a session owes a turn that
 * has not said `running` yet, and only once nothing has happened for a while.
 * Sessions run on a stand-in for the SDK's `query`, so this starts no CLI.
 *
 *   node test/exit-policy-test.ts
 */

import { mayExit, QUIET_BEFORE_EXIT_MS } from "../src/exit-policy.ts";
import { HostedSession, type SessionQuery } from "../src/session.ts";

let failures = 0;
function check(condition: boolean, description: string): void {
  if (!condition) failures++;
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
}

class FakeQuery {
  #queue: unknown[] = [];
  #waiting: ((value: IteratorResult<unknown>) => void) | null = null;

  say(message: unknown): void {
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: message, done: false });
    } else {
      this.#queue.push(message);
    }
  }

  end(): void {
    this.#waiting?.({ value: undefined, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<unknown> {
    return {
      next: () => {
        if (this.#queue.length > 0) return Promise.resolve({ value: this.#queue.shift(), done: false });
        return new Promise((resolve) => (this.#waiting = resolve));
      },
    };
  }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

function idleSession(): { session: HostedSession; fake: FakeQuery } {
  const fake = new FakeQuery();
  const session = new HostedSession(
    { cwd: "/tmp", prompt: "hello", query: () => fake as unknown as SessionQuery },
    () => {},
  );
  session.start();
  fake.say({ type: "system", subtype: "init", session_id: "s", tools: [] });
  fake.say({ type: "result", subtype: "success" });
  return { session, fake };
}

const sessions: HostedSession[] = [];
const quietMs = QUIET_BEFORE_EXIT_MS;

console.log("a background agent's report, before its turn starts");
{
  const { session, fake } = idleSession();
  sessions.push(session);
  await settle();
  check(session.state === "idle", "the session is idle after its first turn");
  fake.say({ type: "system", subtype: "task_started", task_id: "t1", tool_use_id: "call1" });
  await settle();
  fake.say({ type: "system", subtype: "task_notification", task_id: "t1", status: "completed" });
  await settle();
  const at = Date.now();
  check(session.state === "idle" && session.runningTasks().length === 0, "still idle, with no task out");
  check(!mayExit(sessions, at + quietMs * 10), "the host stays, however long it has been quiet");
  fake.say({ type: "stream_event", event: { type: "message_start" }, parent_tool_use_id: null });
  fake.say({ type: "result", subtype: "success" });
  await settle();
  const answered = Date.now();
  check(!mayExit(sessions, answered + 1_000), "once the report is answered, not inside the quiet period");
  check(mayExit(sessions, answered + quietMs), "and does go once it has passed");
  fake.end();
}

console.log("a send to an idle session, before its turn starts");
{
  sessions.length = 0;
  const { session, fake } = idleSession();
  sessions.push(session);
  await settle();
  session.send("are you there?");
  await settle();
  const at = Date.now();
  check(session.state === "idle", "the session still reads idle");
  check(!mayExit(sessions, at + quietMs * 10), "the host stays, however long it has been quiet");
  fake.say({ type: "result", subtype: "success" });
  await settle();
  const answered = Date.now();
  check(!mayExit(sessions, answered + 1_000), "once the send is answered, not inside the quiet period");
  check(mayExit(sessions, answered + quietMs), "and does go once it has passed");
  fake.end();
}

console.log("nothing running from the start");
{
  sessions.length = 0;
  const { session, fake } = idleSession();
  sessions.push(session);
  await settle();
  const at = Date.now();
  check(!mayExit(sessions, at), "a host that just heard something stays even with nothing owed");
  check(mayExit(sessions, at + quietMs), "and goes once the quiet period has passed");
  fake.end();
}

await settle();
console.log(failures ? `\nexit-policy: ${failures} check(s) failed` : "\nexit-policy: all checks passed");
process.exit(failures ? 1 : 0);
