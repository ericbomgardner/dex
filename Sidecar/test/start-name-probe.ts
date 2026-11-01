/**
 * A name sent with `start` becomes the session's title, and an origin rides
 * along on the init.
 *
 * Background watchers name the sessions they start ("CI fail: feature/foo"),
 * and the app reads a row's name off the transcript, where the CLI's own
 * `ai-title` lands a second or two in. So the host writes the start's name as a
 * `custom-title`, which outranks it. Three readings:
 *
 *   - `session.init` carries the start's name and origin, since an app already
 *     connected never sees the summary of a session another client started.
 *   - The transcript's newest `custom-title` is the name, after the `ai-title`
 *     has landed and after a second turn.
 *   - A resume with a name writes no `custom-title`: the app resumes with the
 *     name it last read, and writing it would freeze the CLI's title.
 *
 *   node test/start-name-probe.ts
 */

import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { HostedSession } from "../src/session.ts";
import type { Event } from "../src/protocol.ts";

const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "start-name-probe-")));
const NAME = "CI fail: feature/foo";
const ORIGIN = { watcher: "probe-watch", reason: "tests failed on PR #12" };

function transcript(sessionId: string): string {
  return path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
}

function titles(file: string, type: string, field: string): string[] {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line))
    .filter((record) => record.type === type)
    .map((record) => record[field]);
}

function run(options: { name: string; resume?: string; origin?: typeof ORIGIN }) {
  let init: any = null;
  let resolveTurn: () => void = () => {};
  let turn = new Promise<void>((resolve) => (resolveTurn = resolve));
  const session = new HostedSession(
    { cwd: dir, prompt: "Reply with only the word ok.", model: "haiku", settingSources: [], ...options },
    (event: Event) => {
      if (event.type === "session.init") init ??= event;
      if (event.type === "session.result") {
        resolveTurn();
        turn = new Promise<void>((resolve) => (resolveTurn = resolve));
      }
    },
  );
  return {
    session,
    init: () => init,
    nextTurn: () => turn,
  };
}

const deadline = (ms: number) =>
  new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`nothing within ${ms / 1000}s`)), ms));

let sessionId = "";
try {
  const first = run({ name: NAME, origin: ORIGIN });
  first.session.start();
  await Promise.race([first.nextTurn(), deadline(120_000)]);
  sessionId = first.session.sessionId ?? "";

  check(first.init()?.name === NAME, "session.init carries the start's name");
  check(
    JSON.stringify(first.init()?.origin) === JSON.stringify(ORIGIN),
    "session.init carries the start's origin",
  );
  check(JSON.stringify(first.session.summary().origin) === JSON.stringify(ORIGIN), "so does the summary");

  const file = transcript(sessionId);
  await sleep(6_000);
  const aiTitles = titles(file, "ai-title", "aiTitle");
  console.log(`  ai-title: ${JSON.stringify(aiTitles.at(-1))}`);
  check(titles(file, "custom-title", "customTitle").at(-1) === NAME, "the transcript's newest custom-title is the name");

  const done = first.nextTurn();
  first.session.send("Reply with only the word ok, again.");
  await Promise.race([done, deadline(120_000)]);
  await sleep(3_000);
  const custom = titles(file, "custom-title", "customTitle");
  check(custom.at(-1) === NAME, `it is still the newest after another turn (${JSON.stringify(custom)})`);
  first.session.stop();
  await sleep(2_000);

  const before = custom.length;
  const resumed = run({ name: "Some ai title the app read", resume: sessionId });
  resumed.session.start();
  await Promise.race([resumed.nextTurn(), deadline(120_000)]);
  await sleep(3_000);
  const after = titles(file, "custom-title", "customTitle");
  check(
    !after.includes("Some ai title the app read"),
    `a resume's name is not written down (${JSON.stringify(after.slice(before))})`,
  );
  resumed.session.stop();
} catch (error: any) {
  check(false, `probe ran: ${error?.message ?? error}`);
} finally {
  await sleep(1_000);
  rmSync(dir, { recursive: true, force: true });
  if (sessionId) rmSync(path.dirname(transcript(sessionId)), { recursive: true, force: true });
}

if (failures.length > 0) {
  console.log(`\n${failures.length} failed`);
  process.exit(1);
}
console.log("\nall ok");
process.exit(0);
