/**
 * What a session's transcript says when the host dies holding a tool call.
 *
 * Since CLI v2.1.236 a SIGTERM'd print/SDK session writes no interruption
 * record and no synthetic tool denials before it goes. Before that it wrote the
 * same `[Request interrupted by user]` a deliberate stop writes, so the file
 * could not tell a death from a stop — and the pane, reading only the file,
 * drew a killed session's last call as running for good.
 *
 * That reading is what `TranscriptItemView`'s `isLive` and `AgentSession`'s
 * `canAnswer` rest on, and until this probe nothing exercised it: `reap-probe`
 * only ever measured sessions that were idle when they went. So this starts a
 * host, gets a session into a tool call that will outlive it, SIGTERMs the host
 * the way quitting the app does, and reads the tail of what was left behind.
 *
 * What it found, which is narrower than the changelog line sounds:
 *   - nothing is written to say the turn was stopped, and no synthetic denials
 *   - but a *shell* call in flight is still resolved. Its child is killed with
 *     it and the exit code becomes the result (`Exit code 137`), so the pane
 *     has no dangling row for one of those
 *
 * So the call that strands is the one whose answer was going to arrive by a
 * route that dies with the host — a background agent's `<task-notification>`,
 * which is what `finishedAgents` waits for and never gets.
 *
 * If the CLI ever goes back to writing an interruption record, this fails and
 * docs/claude-code/how-a-session-dies.md is the thing to fix: the pane would then have a cheaper
 * signal than session liveness, and `canAnswer` would be answering a question
 * the file had already answered.
 *
 *   node test/host-death-probe.ts
 */

import net from "node:net";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startCredential } from "./credential.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostEntry = path.join(here, "..", "src", "host.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "dex-death-"));
const socketPath = path.join(scratch, "host.sock");

const failures: string[] = [];
let nothingMeasured: string | undefined;
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

// Subscription only, same as the other probes: a key here bills a real account
// for a probe nobody asked to pay for.
const credential = startCredential("host-death-probe");

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const host = spawn(process.execPath, [hostEntry], {
  env: { ...process.env, DEX_HOST_SOCKET: socketPath },
  stdio: ["ignore", "pipe", "pipe"],
});
host.stderr.on("data", (chunk) => process.stderr.write(`[host] ${chunk}`));
let hostAlive = true;
host.on("exit", () => {
  hostAlive = false;
});

for (let attempt = 0; attempt < 100 && !existsSync(socketPath); attempt++) await sleep(50);
if (!existsSync(socketPath)) throw new Error("host never created its socket");

const socket = net.connect(socketPath);
await new Promise((resolve) => socket.once("connect", resolve));

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

function expect(match: (event: any) => boolean, what: string, ms = 180_000): Promise<any> {
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
}

let counter = 0;
function request(body: Record<string, unknown>): string {
  const id = `r${++counter}`;
  socket.write(`${JSON.stringify({ id, ...body })}\n`);
  return id;
}

/** The session's own file, found the way `TranscriptLocator` finds it. */
function transcriptFor(sessionId: string): string | undefined {
  const projects = path.join(homedir(), ".claude", "projects");
  if (!existsSync(projects)) return undefined;
  for (const project of readdirSync(projects)) {
    const candidate = path.join(projects, project, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

/** A record's content blocks, which is an array on some records and a string on others. */
function blocksOf(record: any): any[] {
  const content = record?.message?.content;
  return Array.isArray(content) ? content : [];
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

try {
  request({ type: "hello", protocol: 1 });
  await expect((e) => e.type === "welcome", "welcome");

  const startId = request({
    type: "start",
    ...credential,
    cwd: scratch,
    // Long enough that the call is still open when the host goes. Two things
    // this phrasing is working around, both learned the hard way: asked the
    // obvious way the model backgrounds it, which returns a launch receipt at
    // once and leaves nothing pending to kill; and a bare `sleep` is refused
    // outright by the Bash tool, which suggests Monitor instead. A python
    // sleep is neither.
    prompt:
      "Run this shell command in the foreground and wait for it to finish: " +
      "python3 -c 'import time; time.sleep(90)'. " +
      "Do not use run_in_background. Then tell me it finished.",
    settingSources: [],
  });
  await expect((e) => e.type === "reply" && e.id === startId, "start reply");
  const init = await expect((e) => e.type === "session.init", "session.init");
  const sessionId: string = init.sessionId;
  check(typeof sessionId === "string", `session opened (${sessionId})`);

  // Answered if it comes, waited out if it doesn't. Whether a command asks at
  // all is a judgement the CLI makes about that command — `sleep` reads as
  // harmless and goes straight through — and this probe is about what the file
  // says afterwards, not about which commands need permission.
  const ask = await Promise.race([
    expect((e) => e.type === "ask", "an ask", 20_000).catch(() => undefined),
    sleep(20_000).then(() => undefined),
  ]);
  if (ask) {
    request({ type: "answer", askId: ask.askId, kind: "permission", optionId: "allow_once" });
  }
  console.log(`  (the command ${ask ? "asked first" : "ran without asking"})`);

  // Let the call actually get going. Nothing announces "the tool is running",
  // so this waits on the clock rather than on an event — the sleep is 90s and
  // this is well inside it.
  await sleep(8_000);

  const file = transcriptFor(sessionId);
  check(file !== undefined, `the transcript is on disk (${file ?? "not found"})`);
  if (!file) throw new Error("no transcript to read");

  // The precondition, waited for rather than assumed. Everything below measures
  // what a death does to a call that is *open*, so a run that never had one open
  // measures nothing — and says so, instead of passing on an empty file or
  // failing as though the reading had moved.
  const openCall = async () => {
    const calls = new Map<string, string>();
    const answered = new Set<string>();
    for (const record of records(file)) {
      for (const block of blocksOf(record)) {
        if (block?.type === "tool_use") calls.set(block.id, block.name);
        if (block?.type === "tool_result") answered.add(block.tool_use_id);
      }
    }
    return [...calls].find(([id]) => !answered.has(id));
  };

  let open = await openCall();
  for (let attempt = 0; attempt < 40 && !open; attempt++) {
    await sleep(1_000);
    open = await openCall();
  }
  // Recorded rather than exited on: `process.exit` skips `finally`, and the
  // host this spawned would outlive the probe that gave up on it.
  if (!open) {
    nothingMeasured =
      "no call was ever left open — the model likely backgrounded it, which\n" +
      "returns a receipt at once. Nothing to kill mid-call, so nothing measured.";
  }
  const openId = open?.[0];
  if (open) check(true, `a call is open when the host dies (${open[1]})`);
  if (open && openId) {

  // --- the death itself, which is what quitting the app does
  host.kill("SIGTERM");
  for (let attempt = 0; attempt < 100 && hostAlive; attempt++) await sleep(50);
  check(!hostAlive, "the host is gone");

  // The CLI is killed by the SDK's own exit cleanup, which SIGTERMs every child
  // it tracked. Give the file a moment to take whatever last write there is.
  await sleep(3_000);

  const after = records(file);
  const calls = new Map<string, any>();
  const answered = new Set<string>();
  for (const record of after) {
    for (const block of blocksOf(record)) {
      if (block?.type === "tool_use") calls.set(block.id, block);
      if (block?.type === "tool_result") answered.add(block.tool_use_id);
    }
  }
  const stranded = [...calls.keys()].filter((id) => !answered.has(id));

  // Measured, and not what the changelog line reads like on its own. A shell
  // call *is* resolved: its child is killed too, and the exit code becomes the
  // result — `Exit code 137`, an error result like any other. So the pane has
  // no dangling row for one of those, and the stranding case is narrower than
  // "any call in flight": it is a call whose answer was going to arrive by a
  // route that dies with the host, which is a background agent's notification.
  check(
    !stranded.includes(openId),
    `a shell call in flight is resolved, not stranded (${stranded.length} of ${calls.size} left open)`,
  );
  // `content` is a string on some records, so this asks for the array first —
  // the same guard `blocksOf` gives the loop above.
  const closing = after.flatMap((r) =>
    blocksOf(r)
      .filter((b: any) => b?.type === "tool_result" && b.tool_use_id === openId)
      .map((b: any) => ({ isError: b.is_error, text: String(b.content).slice(0, 60) })),
  );
  check(
    closing.some((r) => r.isError),
    `and resolved as an error (${closing.map((r) => r.text).join("; ") || "nothing"})`,
  );

  // The reading. An interruption record here would mean the file can tell a
  // death from a stop on its own, and the pane would not need session liveness.
  const text = after
    .map((r) => {
      const content = r.message?.content;
      if (typeof content === "string") return content;
      return (content ?? []).map((b: any) => b?.text ?? "").join(" ");
    })
    .join("\n");
  check(
    !text.includes("[Request interrupted by user"),
    "nothing was written to say the turn was stopped",
  );
  const synthetic = after.filter((r) => r.message?.model === "<synthetic>").length;
  check(synthetic === 0, `no synthetic denials were written for the pending call (${synthetic})`);

  console.log(
    `\n  the file ends with ${stranded.length} call(s) pending and nothing saying why.`,
  );
  console.log(
    "  a killed shell call closes itself; what strands is a delegation whose\n" +
      "  notification dies with the host, which is why the pane reads liveness.",
  );
  }
} finally {
  socket.destroy();
  if (hostAlive) host.kill("SIGKILL");
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
