/**
 * Whether a session opened with a slash command gets a title.
 *
 * The CLI names a session with an `ai-title` record a second or two after its
 * first prompt. It skips a prompt that is a slash command, arguments or not,
 * and names the session only once a plain prompt follows — so a session that
 * is nothing but `/land` never gets a name. `SessionDigestReader` covers the
 * gap with the command itself, read off the first user record.
 *
 * Four readings:
 *
 *   - **A plain first prompt is titled.** The control: without it, the missing
 *     titles below could be a title step that no longer runs at all.
 *   - **A command first prompt is not**, with or without arguments.
 *   - **The first user record is the command's echo**, `<command-name>` and
 *     `<command-args>`, which is what the fallback reads.
 *   - **A plain prompt after the command gets the session titled.**
 *
 *   node test/command-title-probe.ts
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const failures: string[] = [];
const scratches: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Transcript = { titles: string[]; firstUser: string };

async function run(prompts: string[]): Promise<Transcript> {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "command-title-probe-")));
  scratches.push(dir);
  mkdirSync(path.join(dir, ".claude/skills/hello"), { recursive: true });
  writeFileSync(
    path.join(dir, ".claude/skills/hello/SKILL.md"),
    "---\nname: hello\ndescription: Say hello.\n---\nReply with only the word ok.\n",
  );

  let answered: () => void = () => {};
  const turn = () => new Promise<void>((resolve) => (answered = resolve));
  async function* input() {
    for (const text of prompts) {
      const done = turn();
      yield { type: "user" as const, message: { role: "user" as const, content: text }, parent_tool_use_id: null };
      await done;
    }
    // The title lands a second or two after the prompt, not with the answer.
    await sleep(10_000);
  }

  let sessionId = "";
  for await (const message of query({
    prompt: input(),
    options: { cwd: dir, model: "haiku", settingSources: ["project"] },
  })) {
    if (message.type === "system" && message.subtype === "init") sessionId = message.session_id;
    if (message.type === "result") answered();
  }

  const file = path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
  const records = readFileSync(file, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const first = records.find((r) => r.type === "user" && !r.isMeta);
  const content = first?.message?.content;
  return {
    titles: records.filter((r) => r.type === "ai-title").map((r) => r.aiTitle),
    firstUser: typeof content === "string" ? content : JSON.stringify(content ?? ""),
  };
}

const plain = await run(["Reply with only the word ok."]);
check(plain.titles.length > 0, `a plain first prompt is titled (${JSON.stringify(plain.titles)})`);

const bare = await run(["/hello"]);
check(bare.titles.length === 0, `a bare command first prompt is not titled (${JSON.stringify(bare.titles)})`);
check(bare.firstUser.includes("<command-name>/hello</command-name>"), `its first user record is the command's echo: ${bare.firstUser}`);

const argued = await run(["/hello about the migration of kiwis"]);
check(argued.titles.length === 0, `a command with arguments is not titled either (${JSON.stringify(argued.titles)})`);
check(
  argued.firstUser.includes("<command-args>about the migration of kiwis</command-args>"),
  `its arguments ride in <command-args>: ${argued.firstUser}`,
);

const followed = await run(["/hello", "Now list three facts about kiwi birds, briefly."]);
check(followed.titles.length > 0, `a plain prompt after the command gets it titled (${JSON.stringify(followed.titles)})`);

for (const dir of scratches) rmSync(dir, { recursive: true, force: true });

console.log(failures.length === 0 ? "\ncommand-title-probe: all checks passed" : `\ncommand-title-probe: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
