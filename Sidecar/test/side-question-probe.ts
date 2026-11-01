/**
 * What a side question (`/btw`) is, asked through `Query.askSideQuestion`
 * (undocumented; the CLI's `side_question` control request).
 *
 *   - **It sees the conversation** — a word set in a turn comes back.
 *   - **It leaves no record** — the transcript does not grow and never names it.
 *   - **The session never hears it** — a later turn doesn't know its word.
 *   - **`history` carries earlier side answers** into a follow-up.
 *   - **It answers mid-turn** without ending or breaking that turn.
 *   - **It runs no tools** — asked to, it says so rather than reading a file.
 *
 *   node test/side-question-probe.ts
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "side-question-probe-")));
writeFileSync(path.join(dir, "secret.txt"), "MARMALADE\n");

let answered: () => void = () => {};
let turnDone = new Promise<void>((resolve) => (answered = resolve));
let release: (text: string | null) => void = () => {};
let next = new Promise<string | null>((resolve) => (release = resolve));
let lastResult = "";

async function* input() {
  let text: string | null = "Remember the code word PELICAN. Reply with only the word ok.";
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
      lastResult = message.result ?? "";
      answered();
      turnDone = new Promise((resolve) => (answered = resolve));
    }
  }
})();

function turn(text: string): Promise<void> {
  const done = turnDone;
  release(text);
  return done;
}

await turnDone;
await sleep(2_000);
const file = path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
const raw = () => readFileSync(file, "utf8");
const lines = () => raw().trim().split("\n").length;

check(typeof q.askSideQuestion === "function", "Query still has askSideQuestion");

const before = lines();
const first = await q.askSideQuestion("What was the code word? Also, my favourite animal is the ZEBRA. Reply in one short sentence.");
console.log("        ", JSON.stringify(first));
check(first?.response?.includes("PELICAN"), "it sees the conversation");
check(first?.synthetic === false, "an answered side question is not synthetic");
await sleep(2_000);
check(lines() === before, `it leaves no record (${before} → ${lines()} lines)`);
check(!raw().includes("ZEBRA"), "the transcript never names it");

const follow = await q.askSideQuestion("What's my favourite animal? One word.", {
  history: [{ question: "What was the code word? Also, my favourite animal is the ZEBRA.", response: first?.response ?? "" }],
});
console.log("        ", JSON.stringify(follow));
check(/zebra/i.test(follow?.response ?? ""), "history carries earlier side answers");

const tool = await q.askSideQuestion("What is in secret.txt in the working directory? Read it.");
console.log("        ", JSON.stringify(tool));
check(!(tool?.response ?? "").includes("MARMALADE"), "it runs no tools");

await turn("Have I told you my favourite animal? Answer yes or no, then name it if so.");
console.log("        ", JSON.stringify(lastResult));
check(!/zebra/i.test(lastResult), "the session never hears it");

const longTurn = turn("Write a 400-word story about a lighthouse keeper. No preamble.");
await sleep(2_500);
let midResult = "";
const midStart = Date.now();
const mid = await q.askSideQuestion("What was the code word? One word.");
const midMs = Date.now() - midStart;
let turnFinishedFirst = false;
await Promise.race([longTurn.then(() => (turnFinishedFirst = true)), sleep(0)]);
console.log("        ", JSON.stringify(mid), `${midMs}ms`, turnFinishedFirst ? "(turn had already ended)" : "(turn still running)");
check(mid?.response?.includes("PELICAN"), "it answers mid-turn");
await longTurn;
midResult = lastResult;
check(midResult.split(/\s+/).length > 150, `the turn it cut into still finishes (${midResult.split(/\s+/).length} words)`);

release(null);
q.close?.();
await drained.catch(() => {});

rmSync(dir, { recursive: true, force: true });
rmSync(path.dirname(file), { recursive: true, force: true });

console.log(failures.length === 0 ? "\nside-question-probe: all checks passed" : `\nside-question-probe: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
