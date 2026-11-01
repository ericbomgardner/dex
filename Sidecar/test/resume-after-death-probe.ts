/**
 * What a resume writes for a call its session died holding.
 *
 *   node test/resume-after-death-probe.ts
 *
 * `host-death-probe` found that a killed shell call closes itself (its child's
 * exit code becomes the result) and nothing else is written. A foreground
 * agent has no child of its own to die, so its call is left with no result at
 * all. The pane draws that `never came back`, off liveness.
 *
 * CLI v2.1.281's changelog: "Fixed resuming a session that ended during a tool
 * call: Claude now sees the call and is told its outcome is unknown, and a
 * manual resume no longer adds a hidden 'Continue' message." This starts a
 * foreground agent, SIGTERMs the host the way quitting the app does, resumes
 * the session on a second host the way the app does, and reads what the
 * resume appended for that call.
 */

import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startCredential } from "./credential.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostEntry = path.join(here, "..", "src", "host.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "dex-resume-death-"));

const credential = startCredential("resume-after-death-probe");

const failures: string[] = [];
let nothingMeasured: string | undefined;
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

interface Host {
  process: ChildProcess;
  alive: () => boolean;
  request(body: Record<string, unknown>): string;
  expect(match: (event: any) => boolean, what: string, ms?: number): Promise<any>;
  close(): void;
}

async function startHost(name: string): Promise<Host> {
  const socketPath = path.join(scratch, `${name}.sock`);
  const child = spawn(process.execPath, [hostEntry], {
    env: { ...process.env, DEX_HOST_SOCKET: socketPath },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stderr!.on("data", (chunk) => process.stderr.write(`[${name}] ${chunk}`));
  let alive = true;
  child.on("exit", () => (alive = false));

  for (let attempt = 0; attempt < 100 && !existsSync(socketPath); attempt++) await sleep(50);
  if (!existsSync(socketPath)) throw new Error(`${name} never created its socket`);
  const socket = net.connect(socketPath);
  await new Promise((resolve) => socket.once("connect", resolve));
  socket.on("error", () => {});

  const seen: any[] = [];
  const waiters: { match: (event: any) => boolean; resolve: (event: any) => void }[] = [];
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline = buffer.indexOf("\n");
    while (newline !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line) {
        const event = JSON.parse(line);
        seen.push(event);
        for (const waiter of [...waiters]) {
          if (waiter.match(event)) {
            waiters.splice(waiters.indexOf(waiter), 1);
            waiter.resolve(event);
          }
        }
      }
      newline = buffer.indexOf("\n");
    }
  });

  let counter = 0;
  return {
    process: child,
    alive: () => alive,
    request(body) {
      const id = `${name}-${++counter}`;
      socket.write(`${JSON.stringify({ id, ...body })}\n`);
      return id;
    },
    expect(match, what, ms = 180_000) {
      const already = seen.find(match);
      if (already) return Promise.resolve(already);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
        waiters.push({
          match,
          resolve: (event) => {
            clearTimeout(timer);
            resolve(event);
          },
        });
      });
    },
    close() {
      socket.destroy();
      if (alive) child.kill("SIGKILL");
    },
  };
}

function transcriptFor(sessionId: string): string | undefined {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const project of readdirSync(projects)) {
    const candidate = path.join(projects, project, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

function records(file: string): any[] {
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

function blocksOf(record: any): any[] {
  const content = record?.message?.content;
  return Array.isArray(content) ? content : [];
}

function textOf(value: any): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(textOf).join(" ");
  if (typeof value?.text === "string") return value.text;
  if (value?.content !== undefined) return textOf(value.content);
  return "";
}

function summary(record: any): string {
  const flags = ["isMeta", "isSidechain", "isCompactSummary", "isVisibleInTranscriptOnly"]
    .filter((key) => record[key])
    .join(",");
  const content = record.message?.content;
  const body = Array.isArray(content)
    ? content
        .map((b: any) => `${b.type}${b.tool_use_id ? `(${b.tool_use_id.slice(-6)}${b.is_error ? ",error" : ""})` : ""}:${textOf(b).slice(0, 100).replace(/\s+/g, " ")}`)
        .join(" | ")
    : textOf(content ?? record.content ?? record.attachment?.type ?? record.subtype ?? "").slice(0, 100).replace(/\s+/g, " ");
  const model = record.message?.model ? ` model=${record.message.model}` : "";
  const extra = record.toolUseResult !== undefined ? ` toolUseResult=${JSON.stringify(record.toolUseResult).slice(0, 80)}` : "";
  return `${record.type}${record.subtype ? `/${record.subtype}` : ""}${flags ? ` [${flags}]` : ""}${model} ${body}${extra}`;
}

let first: Host | undefined;
let second: Host | undefined;

try {
  first = await startHost("first");
  first.request({ type: "hello", protocol: 1 });
  await first.expect((e) => e.type === "welcome", "welcome");

  const startId = first.request({
    type: "start",
    ...credential,
    cwd: scratch,
    prompt:
      "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
      "description 'count slowly', and run_in_background: false, giving it this task: " +
      "Write out every number from 1 to 400, one per line, spelled in words. Write them " +
      "all — do not summarise or skip ahead. " +
      "Then say done. Do not use any other tool, and do not do the counting yourself.",
    settingSources: [],
  });
  await first.expect((e) => e.type === "reply" && e.id === startId, "start reply");
  const init = await first.expect((e) => e.type === "session.init", "session.init");
  const key: string = init.key;
  const sessionId: string = init.sessionId;
  check(typeof sessionId === "string", `session opened (${sessionId})`);

  let file: string | undefined;
  let agentCall: any;
  for (let attempt = 0; attempt < 120 && !agentCall; attempt++) {
    await sleep(1_000);
    file ??= transcriptFor(sessionId);
    if (!file) continue;
    const all = records(file);
    const answered = new Set(all.flatMap((r) => blocksOf(r)).filter((b) => b?.type === "tool_result").map((b) => b.tool_use_id));
    agentCall = all
      .filter((r) => !r.isSidechain)
      .flatMap((r) => blocksOf(r))
      .find((b) => b?.type === "tool_use" && (b.name === "Agent" || b.name === "Task") && !answered.has(b.id));
  }
  if (!file || !agentCall) {
    nothingMeasured = "no foreground agent call was ever open — nothing to kill mid-call.";
  } else if (agentCall.input?.run_in_background === true) {
    nothingMeasured = "the model backgrounded the agent, which answers at once with a receipt — nothing stranded.";
  } else {
    check(true, `a foreground agent call is open (${agentCall.id})`);
    // Into its counting, not still starting up.
    await sleep(8_000);

    first.process.kill("SIGTERM");
    for (let attempt = 0; attempt < 100 && first.alive(); attempt++) await sleep(50);
    check(!first.alive(), "the first host is gone");
    await sleep(3_000);

    const atDeath = records(file);
    const resultsFor = (all: any[]) =>
      all.flatMap((r) => blocksOf(r).filter((b) => b?.type === "tool_result" && b.tool_use_id === agentCall.id).map((b) => ({ record: r, block: b })));
    check(resultsFor(atDeath).length === 0, "the agent call is stranded: no result after the death");

    second = await startHost("second");
    second.request({ type: "hello", protocol: 1 });
    await second.expect((e) => e.type === "welcome", "welcome");
    const resumeId = second.request({
      type: "start",
      ...credential,
      cwd: scratch,
      resume: sessionId,
      key,
      prompt: "What happened to the agent you launched? Answer in one sentence, and do not launch it again or use any tool.",
      settingSources: [],
    });
    await second.expect((e) => e.type === "reply" && e.id === resumeId, "resume reply");
    const resumedInit = await second.expect((e) => e.type === "session.init", "resumed session.init");
    check(resumedInit.sessionId === sessionId, "the resume continues the same transcript");
    const result = await second.expect((e) => e.type === "session.result" && e.key === key, "the resumed turn's result", 300_000);
    console.log(`  (resumed turn ended ${result.subtype})`);
    await sleep(2_000);

    const after = records(file);
    const appended = after.slice(atDeath.length);
    console.log("\n  records the resume appended:");
    for (const record of appended) console.log(`    ${summary(record)}`);

    const closing = resultsFor(after);
    console.log(
      `\n  results for the stranded call: ${closing.length}` +
        closing.map(({ block }) => `\n    is_error=${block.is_error} "${textOf(block.content).slice(0, 200).replace(/\s+/g, " ")}"`).join(""),
    );

    // What `ToolResult.isUnrecorded` reads. If the wording moves, the pane
    // goes back to counting the call as a failure that took hours.
    check(closing.length === 1, "the resume writes one result for the stranded call");
    check(
      closing[0]?.block.is_error === true &&
        textOf(closing[0]?.block.content).trim().startsWith(
          "[Tool call interrupted: the session ended before this call's result was recorded",
        ),
      "as an error that opens with the unrecorded-outcome line",
    );
    const resultAt = appended.findIndex((r) => resultsFor([r]).length > 0);
    const prompted = appended.findIndex((r) => r.type === "user" && /What happened to the agent/.test(textOf(r.message?.content)));
    check(resultAt !== -1 && prompted !== -1 && resultAt < prompted, "written before the resumed prompt");

    const continues = appended.filter(
      (r) => r.type === "user" && !r.isMeta && /^\s*continue\.?\s*$/i.test(textOf(r.message?.content)),
    );
    check(continues.length === 0, "no bare 'Continue' user message is written on resume");

    const reply = appended
      .filter((r) => r.type === "assistant" && !r.isSidechain)
      .map((r) => blocksOf(r).filter((b) => b.type === "text").map((b) => b.text).join(" "))
      .join(" ")
      .trim();
    console.log(`\n  the model said: "${reply.slice(0, 300)}"`);
  }
} finally {
  first?.close();
  second?.close();
  rmSync(scratch, { recursive: true, force: true });
}

if (nothingMeasured) {
  console.error(`\n${nothingMeasured}`);
  process.exit(2);
}
if (failures.length) {
  console.error(`\n${failures.length} failed:`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log("\nall checks passed");
