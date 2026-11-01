import assert from "node:assert/strict";
import { test } from "node:test";

import type { Event } from "../../src/protocol.ts";
import { HostedSession, type SessionQuery } from "../../src/session.ts";

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

function started(resume?: string): { session: HostedSession; fake: FakeQuery; events: Event[] } {
  const fake = new FakeQuery();
  const events: Event[] = [];
  const session = new HostedSession(
    { cwd: "/tmp", prompt: "/compact", resume, query: () => fake as unknown as SessionQuery },
    (event) => events.push(event),
  );
  session.start();
  return { session, fake, events };
}

const inits = (events: Event[]) => events.filter((event) => event.type === "session.init");

test("a resume that compacts first is announced before the compaction ends", async () => {
  const { session, fake, events } = started("abc");
  await settle();
  assert.equal(inits(events).length, 0, "nothing is said before the CLI says anything");

  fake.say({ type: "system", subtype: "status", status: "compacting" });
  await settle();
  const early = inits(events);
  assert.equal(early.length, 1);
  assert.equal(early[0].type === "session.init" && early[0].sessionId, "abc");
  assert.equal(early[0].type === "session.init" && early[0].model, null, "the model is not guessed");
  assert.equal(early[0].type === "session.init" && early[0].commands, null, "nor the commands");
  const announcedAt = events.indexOf(early[0]);
  const compacting = events.findIndex((e) => e.type === "session.status" && e.state === "compacting");
  assert.ok(announcedAt < compacting, "announced before the compacting state, so the app has a row to put it on");
  assert.equal(session.state, "compacting");

  fake.say({ type: "system", subtype: "status", status: null, compact_result: "success" });
  fake.say({ type: "system", subtype: "init", session_id: "abc", model: "claude-opus-5-5", tools: ["Bash"], slash_commands: ["compact"] });
  await settle();
  const later = inits(events);
  assert.equal(later.length, 2, "the CLI's own init still follows");
  assert.equal(later[1].type === "session.init" && later[1].model, "claude-opus-5-5");
  fake.end();
});

test("a resume whose init comes first is announced once", async () => {
  const { fake, events } = started("abc");
  fake.say({ type: "system", subtype: "init", session_id: "abc", tools: [] });
  fake.say({ type: "result", subtype: "success" });
  await settle();
  assert.equal(inits(events).length, 1);
  fake.end();
});

test("a new session is not announced before its init", async () => {
  const { fake, events } = started();
  fake.say({ type: "system", subtype: "status", status: "compacting" });
  await settle();
  assert.equal(inits(events).length, 0, "a new session has no id until the CLI names one");
  fake.end();
});
