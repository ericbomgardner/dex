/**
 * When a session's transcript shows up, relative to the moment the app first
 * hears the session's id.
 *
 * The list learns a hosted session's id from `system/init` — the host's
 * `session.init` — and that is where it goes looking for the file, to read the
 * row's title and second line out of it. If the file is not there yet, the read
 * comes back empty and nothing looks again until the next host event, which for
 * a session thinking its way through a first turn is the reconcile half a
 * minute later. So the interesting reading is not "does the CLI write a
 * transcript" but "is it there when we first ask", and how long after.
 *
 * Three readings:
 *
 *   - **Whether the file exists at `system/init`.** Measured false is the whole
 *     reason the app retries; measured true would mean the delay is elsewhere.
 *   - **How long after init it appears.** What the retry has to outlast.
 *   - **How long after init the CLI names the session.** The row's title comes
 *     from the `ai-title` record, so this is when a re-read would find one.
 *
 *   node test/transcript-arrival-probe.ts
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "transcript-arrival-probe-"));
const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

function transcriptFor(sessionId: string): string | null {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function hasTitle(file: string): boolean {
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line) continue;
    try {
      if (JSON.parse(line).type === "ai-title") return true;
    } catch {}
  }
  return false;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// The app's own poll rate: what it does between hearing an id and finding the
// file. Fast enough that the row is right before you have read it, slow enough
// that a session whose file never arrives is not a directory scan on a spin.
const poll = 100;

const session = query({
  prompt: "Reply with just: ok.",
  options: {
    cwd: scratch,
    systemPrompt: { type: "preset", preset: "claude_code" },
    settingSources: [],
  },
});

let sessionId: string | null = null;
let initAt = 0;
let existedAtInit: boolean | null = null;

const reading = (async () => {
  for await (const message of session as any) {
    if (message.type === "system" && message.subtype === "init") {
      sessionId = message.session_id;
      initAt = Date.now();
      // Asked in the same breath as the id arrives, which is what the app does.
      existedAtInit = transcriptFor(sessionId!) !== null;
    }
    if (message.type === "result") break;
  }
})();

const initBy = Date.now() + 120_000;
while (sessionId === null) {
  if (Date.now() > initBy) {
    console.error("FAIL: the session never sent system/init within 120s");
    process.exit(1);
  }
  await sleep(20);
}

console.log(`\n  session id: ${sessionId}`);
check(
  existedAtInit === false,
  existedAtInit
    ? "the transcript already exists at system/init — a read there would answer"
    : "the transcript does not exist yet at system/init (a read there comes back empty)",
);

let file: string | null = null;
while (file === null && Date.now() - initAt < 60_000) {
  file = transcriptFor(sessionId!);
  if (file === null) await sleep(poll);
}
const appearedAfter = Date.now() - initAt;
check(file !== null, `the transcript appears (${appearedAfter}ms after init)`);

let titled = false;
while (!titled && Date.now() - initAt < 120_000) {
  titled = hasTitle(file!);
  if (!titled) await sleep(poll);
}
const titledAfter = Date.now() - initAt;
check(titled, `the CLI names the session (${titledAfter}ms after init)`);

// The reading the retry is sized against. A wait that gives up before this is
// a row that sits on its placeholder until the next host event.
console.log(
  `\n  a row that stopped looking ${appearedAfter}ms after init would find nothing;` +
    ` its title lands at ${titledAfter}ms.`,
);

await Promise.race([reading, sleep(60_000)]);

console.log(
  failures.length === 0
    ? "\ntranscript-arrival-probe: all checks passed"
    : `\ntranscript-arrival-probe: ${failures.length} failed`,
);
process.exit(failures.length === 0 ? 0 : 1);
