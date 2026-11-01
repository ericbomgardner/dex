/**
 * How a rename lands, by each of the two routes the host takes.
 *
 * The app reads a session's name off its transcript: the newest `custom-title`
 * record, ahead of the newest `ai-title`. The host renames a session it is
 * running through `Query.renameSession` (undocumented) and any other through the
 * exported `renameSession`, which appends to the file. Four readings:
 *
 *   - **A live rename is written down** as a `custom-title`, before the next turn.
 *   - **It survives the next turn** and stays the newest `custom-title`.
 *   - **An append while the session runs survives it** — the CLI re-reads the
 *     tail instead of writing its own stale copy back over it.
 *   - **A rename of a session nobody is running lands** with the exported call.
 *
 * And what reaches the CLI's registry (`~/.claude/sessions/<pid>.json`), whose
 * name is all `ListAgents` shows of a session: a live rename does, an append
 * doesn't, a resume takes the newest `custom-title` back, a resume's `title`
 * option names it without writing anything to the transcript, and a session
 * with only the CLI's `ai-title` resumes under a made-up name.
 *
 *   node test/rename-probe.ts
 */

import { query, renameSession } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "rename-probe-")));

let answered: () => void = () => {};
let turnDone = new Promise<void>((resolve) => (answered = resolve));
let release: (text: string | null) => void = () => {};
let next = new Promise<string | null>((resolve) => (release = resolve));

async function* input() {
  let text: string | null = "Reply with only the word ok.";
  while (text !== null) {
    yield { type: "user" as const, message: { role: "user" as const, content: text }, parent_tool_use_id: null };
    text = await next;
    next = new Promise((resolve) => (release = resolve));
  }
}

const q: any = query({ prompt: input(), options: { cwd: dir, model: "haiku", settingSources: [] } });
let sessionId = "";
const drained = (async () => {
  for await (const message of q) {
    if (message.type === "system" && message.subtype === "init") sessionId = message.session_id;
    if (message.type === "result") {
      answered();
      turnDone = new Promise((resolve) => (answered = resolve));
    }
  }
})();

async function turn(text: string): Promise<void> {
  const done = turnDone;
  release(text);
  await done;
}

await turnDone;
await sleep(5_000);
const file = path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
const records = () => readFileSync(file, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const customTitles = () => records().filter((r) => r.type === "custom-title").map((r) => r.customTitle);
const lastCustom = () => customTitles().at(-1);

/** A session's record in the CLI's registry, which is what ListAgents prints. */
function registry(id = sessionId): { name?: string; nameSource?: string } | undefined {
  const sessions = path.join(homedir(), ".claude/sessions");
  for (const name of readdirSync(sessions).filter((n) => /^\d+\.json$/.test(n))) {
    try {
      const record = JSON.parse(readFileSync(path.join(sessions, name), "utf8"));
      if (record.sessionId === id) return record;
    } catch {}
  }
  return undefined;
}
const registered = () => JSON.stringify({ name: registry()?.name, nameSource: registry()?.nameSource });

check(registry()?.nameSource === "derived", `an unnamed session's registry name is made up (${registered()})`);

check(typeof q.renameSession === "function", "Query still has renameSession");
await q.renameSession("Live probe name", sessionId);
check(lastCustom() === "Live probe name", `a live rename is written down at once (${JSON.stringify(customTitles())})`);
await sleep(500);
check(
  registry()?.name === "Live probe name" && registry()?.nameSource === "user",
  `and becomes the registry name (${registered()})`,
);

await turn("Reply with only the word ok, again.");
await sleep(3_000);
check(lastCustom() === "Live probe name", `it survives the next turn (${JSON.stringify(customTitles())})`);

await renameSession(sessionId, "Appended probe name");
await turn("Reply with only the word ok, a third time.");
await sleep(3_000);
check(lastCustom() === "Appended probe name", `an append while running survives the next turn (${JSON.stringify(customTitles())})`);
check(registry()?.name === "Live probe name", `but leaves the registry name alone (${registered()})`);

release(null);
q.close?.();
await drained.catch(() => {});
await sleep(1_000);

/** Runs one turn, resuming `id` if given, and reads the registry while the process is still up. */
async function once(id?: string, title?: string): Promise<{ id: string; record?: { name?: string; nameSource?: string } }> {
  let stop: () => void = () => {};
  const held = new Promise<void>((resolve) => (stop = resolve));
  async function* prompt() {
    yield { type: "user" as const, message: { role: "user" as const, content: "Reply with only the word ok." }, parent_tool_use_id: null };
    await held;
  }
  const r: any = query({
    prompt: prompt(),
    options: { cwd: dir, model: "haiku", settingSources: [], ...(id ? { resume: id } : {}), ...(title ? { title } : {}) },
  });
  let ran = id ?? "";
  let record;
  for await (const message of r) {
    if (message.type === "system" && message.subtype === "init") ran = message.session_id;
    if (message.type !== "result") continue;
    await sleep(1_500);
    record = registry(ran);
    break;
  }
  stop();
  r.close?.();
  await sleep(1_000);
  return { id: ran, record };
}
const resume = async (title?: string) => (await once(sessionId, title)).record;

const newest = lastCustom();
const unresumed = customTitles().length;
const plain = await resume();
check(
  plain?.name === newest && plain?.nameSource === "auto",
  `a resume takes back the newest name it was renamed to, ${JSON.stringify(newest)} (${JSON.stringify(plain?.name)}, ${plain?.nameSource})`,
);
check(customTitles().length === unresumed, `and writes no custom-title of its own (${JSON.stringify(customTitles().slice(unresumed))})`);

const before = customTitles().length;
const titled = await resume("Resumed probe name");
check(
  titled?.name === "Resumed probe name" && titled?.nameSource === "auto",
  `a resume's title option names it in the registry (${JSON.stringify(titled?.name)}, ${titled?.nameSource})`,
);
check(customTitles().length === before, `without writing a custom-title (${JSON.stringify(customTitles().slice(before))})`);

await renameSession(sessionId, "Closed probe name");
check(lastCustom() === "Closed probe name", `a session nobody runs is renamed by the exported call (${JSON.stringify(customTitles())})`);

const untitled = (await once()).id;
await sleep(3_000);
const untitledFile = path.join(path.dirname(file), `${untitled}.jsonl`);
const untitledRecords = () => readFileSync(untitledFile, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const titles = (type: string) => untitledRecords().filter((r) => r.type === type);
const aiTitles = titles("ai-title").map((r) => r.aiTitle);
const unrenamed = titles("custom-title").length === 0;
const aiOnly = (await once(untitled)).record;
check(
  aiTitles.length > 0 && unrenamed && aiOnly?.nameSource === "derived",
  `a resume of a session with only its ai-title is made up again (${JSON.stringify(aiOnly?.name)}, ${aiOnly?.nameSource}; ` +
    `${JSON.stringify(aiTitles)})`,
);

rmSync(dir, { recursive: true, force: true });
rmSync(path.dirname(file), { recursive: true, force: true });

console.log(failures.length === 0 ? "\nrename-probe: all checks passed" : `\nrename-probe: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
