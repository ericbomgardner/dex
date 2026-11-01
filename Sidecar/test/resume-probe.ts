/**
 * What the SDK's `resume` does to a session's identity, and what it needs to
 * come up.
 *
 * Three readings, each one a thing the app would otherwise have to assume:
 *
 *   - **Whether a resumed session keeps its transcript id.** The app binds a row
 *     to its file by session id, so a resume that forks to a new one is a row
 *     pointing at a transcript that stops growing.
 *   - **Whether it comes up with nothing to say.** A session reopened so you can
 *     read it must reach `system/init` without being handed a prompt, or the
 *     row cannot exist until you have already typed at it. A silence only
 *     counts if the session was alive to keep it: the wait has to have run its
 *     full length with no result, no error and the reader still reading, or a
 *     query that died on the way up passes the reading in no time at all.
 *   - **Whether it remembers.** The point of the exercise.
 *   - **Whether its records say the SDK ran it, and where.** Find in Sessions
 *     keeps to transcripts whose `entrypoint` starts `sdk`, and opens one in
 *     the app its first `cwd` names.
 *
 * Runs two sessions of its own and asks the second what the first was told, so
 * nothing here depends on a conversation that already exists.
 *
 *   node test/resume-probe.ts
 */

import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "resume-probe-"));
const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

class PushStream {
  #queue: SDKUserMessage[] = [];
  #waiting: ((value: IteratorResult<SDKUserMessage, undefined>) => void) | null = null;
  #closed = false;

  push(text: string): void {
    const message: SDKUserMessage = {
      type: "user",
      message: { role: "user", content: text },
      parent_tool_use_id: null,
    };
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: message, done: false });
      return;
    }
    this.#queue.push(message);
  }

  close(): void {
    this.#closed = true;
    if (this.#waiting) {
      const resolve = this.#waiting;
      this.#waiting = null;
      resolve({ value: undefined, done: true });
    }
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    while (true) {
      const queued = this.#queue.shift();
      if (queued) {
        yield queued;
        continue;
      }
      if (this.#closed) return;
      const next = await new Promise<IteratorResult<SDKUserMessage, undefined>>((resolve) => {
        this.#waiting = resolve;
      });
      if (next.done) return;
      yield next.value;
    }
  }
}

function transcriptFor(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

// --- the session being resumed

const first = new PushStream();
const original = query({
  prompt: first,
  options: {
    cwd: scratch,
    systemPrompt: { type: "preset", preset: "claude_code" },
    settingSources: [],
  },
});

first.push("Remember the word GRAPEFRUIT. Reply with just: noted.");

let originalId: string | null = null;
for await (const message of original as any) {
  if (message.type === "system" && message.subtype === "init") originalId = message.session_id;
  if (message.type === "result") break;
}
first.close();

check(typeof originalId === "string", `the first session has an id (${originalId})`);
check(transcriptFor(originalId!) !== null, "the first session wrote a transcript");

// --- resumed with nothing to say

const second = new PushStream();
const resumed = query({
  prompt: second,
  options: {
    cwd: scratch,
    systemPrompt: { type: "preset", preset: "claude_code" },
    settingSources: [],
    resume: originalId!,
  },
});

const isInit = (m: any) => m.type === "system" && m.subtype === "init";

// One reader for the whole session: a loop raced against a timeout goes on
// consuming after it loses, and eats the init the next read is waiting for.
const seen: any[] = [];
let finished = false;
let readError: string | null = null;
let initAt: number | null = null;
const reading = (async () => {
  try {
    for await (const message of resumed as any) {
      seen.push(message);
      if (isInit(message) && initAt === null) initAt = Date.now();
      if (message.type === "result") break;
    }
  } catch (error: any) {
    readError = error?.message ?? String(error);
  }
  finished = true;
})();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// The elapsed time is half the answer. The wait also returns the moment the
// session stops reading, so a silence read off the return value alone is a dead
// session passing the reading in 0ms.
async function waitFor(
  match: (m: any) => boolean,
  ms: number,
): Promise<{ found: any | null; elapsed: number }> {
  const started = Date.now();
  const deadline = started + ms;
  while (Date.now() < deadline && !finished) {
    const found = seen.find(match);
    if (found) return { found, elapsed: Date.now() - started };
    await sleep(200);
  }
  return { found: seen.find(match) ?? null, elapsed: Date.now() - started };
}

// Asserted the way it actually behaves, so a change to it fails here rather
// than in the app: a resumed session sits silent until it is handed something
// to say, which is why a reopened row cannot be live before you type at it. If
// this ever starts arriving early, the row could go live on being opened. The
// silence only counts if the session was alive to keep it — so the wait has to
// have run its full length with nothing ending it.
const quiet = await waitFor(isInit, 45_000);
const resultsWhileQuiet = seen.filter((m) => m.type === "result").length;
check(
  quiet.found === null &&
    quiet.elapsed >= 45_000 &&
    !finished &&
    readError === null &&
    resultsWhileQuiet === 0,
  "a resumed session stays silent until it is handed a prompt " +
    `(${(quiet.elapsed / 1000).toFixed(1)}s, ${seen.length} message(s), ` +
    `${resultsWhileQuiet} result(s), ${readError ? `read error: ${readError}` : "still reading"})`,
);

const promptAt = Date.now();
second.push("What word did I ask you to remember? Reply with just that word.");
const init = quiet.found ?? (await waitFor(isInit, 120_000)).found;
console.log(
  `\n  silent for ${(quiet.elapsed / 1000).toFixed(1)}s, then init ` +
    `${initAt === null ? "never" : `${initAt - promptAt}ms`} after the prompt`,
);
const resumedId = init?.session_id ?? null;
console.log(`\n  resumed session id: ${resumedId}`);
console.log(`  original session id: ${originalId}`);
check(
  typeof resumedId === "string",
  resumedId === originalId
    ? "a resume continues the same transcript id"
    : `a resume FORKS to a new transcript id (${resumedId})`,
);

await Promise.race([reading, sleep(180_000)]);
let said = "";
for (const message of seen) {
  if (message.type !== "assistant") continue;
  for (const block of message.message?.content ?? []) {
    if (block.type === "text") said += block.text;
  }
}
second.close();

check(said.toUpperCase().includes("GRAPEFRUIT"), `the resumed session remembers (said "${said.trim()}")`);

const turns = readFileSync(transcriptFor(originalId!)!, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line))
  .filter((record) => record.type === "user" || record.type === "assistant");
const entrypoints = [...new Set(turns.map((record) => record.entrypoint))];
check(
  turns.length > 0 && entrypoints.every((value) => typeof value === "string" && value.startsWith("sdk")),
  `every turn, resumed or not, is marked as the SDK's (${entrypoints.join(", ")})`,
);
check(
  turns[0]?.cwd === scratch || turns[0]?.cwd === realpathSync(scratch),
  `the first turn names the folder it ran in (${turns[0]?.cwd})`,
);

if (resumedId && resumedId !== originalId) {
  check(
    transcriptFor(resumedId) !== null,
    "the forked id has a transcript of its own",
  );
  console.log(
    `\n  NOTE: a row bound to ${originalId} would stop growing; the work moves to ${resumedId}.`,
  );
}

console.log(failures.length === 0 ? "\nresume-probe: all checks passed" : `\nresume-probe: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
