/**
 * What the host lets go of on its own, and what it doesn't.
 *
 * Drives a host of its own with the thresholds turned down to seconds: parks a
 * session on an ask and leaves it there well past the reap window, answers it,
 * and watches the session that is now merely old be let go. The reading the
 * reaper rests on is the last one — that closing a session's input stream ends
 * its CLI, so the host's own account of what it is running and the processes on
 * the machine say the same thing. A stream that closed without taking the
 * process with it would leak one per reap, off the host's books and so out of
 * reach of anything that could count them.
 *
 *   node test/reap-probe.ts
 */

import net from "node:net";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startCredential } from "./credential.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostEntry = path.join(here, "..", "src", "host.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "dex-reap-"));
const socketPath = path.join(scratch, "host.sock");

const REAP_AFTER_MS = 4_000;
const IDLE_EXIT_MS = 4_000;

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const credential = startCredential("reap-probe");

const host = spawn(process.execPath, [hostEntry], {
  env: {
    ...process.env,
    DEX_HOST_SOCKET: socketPath,
    DEX_REAP_AFTER_MS: String(REAP_AFTER_MS),
    DEX_HOST_IDLE_MS: String(IDLE_EXIT_MS),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
host.stderr.on("data", (chunk) => process.stderr.write(`[host] ${chunk}`));
let hostAlive = true;
host.on("exit", () => {
  hostAlive = false;
});

/** The CLIs this host is running, counted off the machine rather than its books. */
function sessionProcesses(): number {
  const listing = execFileSync("ps", ["-eo", "ppid=,command="], { encoding: "utf8" });
  return listing.split("\n").filter((line) => {
    const [ppid] = line.trim().split(/\s+/);
    return ppid === String(host.pid) && line.includes("claude-agent-sdk");
  }).length;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const startedAt = Date.now();

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
      if (process.env.REAP_TRACE) {
        console.log(`    [+${Date.now() - startedAt}ms] ${event.type}${event.state ? "/" + event.state : ""}`);
      }
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

/**
 * The nth event of a kind rather than any, since by the second turn the session
 * has already produced one of everything and `expect` answers off what it saw.
 */
function expectAnother(
  match: (event: any) => boolean,
  what: string,
  ms = 180_000,
): Promise<any> {
  const already = seen.filter(match).length;
  let arrived = 0;
  return expect((event) => match(event) && ++arrived > already, what, ms);
}

/**
 * The nth-and-after of a kind, counted from a baseline the caller took before
 * the thing that produces it. `expectAnother` cannot do this: it counts when it
 * is called, which is already too late for anything that arrives alongside the
 * event that got us here.
 */
function expectSince(
  match: (event: any) => boolean,
  baseline: number,
  what: string,
  ms = 180_000,
): Promise<any> {
  const already = seen.filter(match);
  if (already.length > baseline) return Promise.resolve(already[baseline]);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
    // Counted off the waiter, which only ever sees new events — the history was
    // counted once, above.
    let count = already.length;
    waiters.push({
      match: (event) => match(event) && ++count > baseline,
      resolve: (event) => {
        clearTimeout(timer);
        resolve(event);
      },
    });
  });
}

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

/** What a fresh client is told the host is running, which is the map itself. */
async function heldSessions(): Promise<any[]> {
  const observer = net.connect(socketPath);
  await new Promise((resolve) => observer.once("connect", resolve));
  const welcome = await new Promise<any>((resolve) => {
    let tail = "";
    observer.on("data", (chunk) => {
      tail += chunk.toString("utf8");
      for (const line of tail.split("\n")) {
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "welcome") resolve(event);
      }
    });
    observer.write(`${JSON.stringify({ id: "obs", type: "hello", protocol: 1 })}\n`);
  });
  observer.destroy();
  return welcome.sessions;
}

/** The host's own clock for a session, which is what the reaper reads. */
async function clockFor(key: string): Promise<string | undefined> {
  return (await heldSessions()).find((session) => session.key === key)?.lastActivityAt;
}

try {
  request({ type: "hello", protocol: 1 });
  await expect((e) => e.type === "welcome", "welcome");

  const startId = request({
    type: "start",
    ...credential,
    cwd: scratch,
    // A file write rather than a shell command, for the reason smoke.ts gives:
    // some commands are treated as read-only and approved without an ask.
    prompt: "Create a file called reap.txt containing the text OK, then stop.",
    settingSources: [],
  });
  const started = await expect((e) => e.type === "reply" && e.id === startId, "start reply");
  const key = started.key;
  const init = await expect((e) => e.type === "session.init", "session.init");
  check(typeof init.sessionId === "string", `session opened (${init.sessionId})`);

  check(sessionProcesses() >= 1, `the session is a CLI of its own (${sessionProcesses()} running)`);

  // --- parked on an ask, and left there past the window
  const ask = await expect((e) => e.type === "ask", "an ask");
  await sleep(REAP_AFTER_MS * 2);
  check(
    !seen.some((e) => e.type === "session.exit"),
    "a session parked on an ask is spared however long it is left",
  );
  check((await heldSessions()).length === 1, "the host still holds it");

  // --- answered, finished, and now merely old
  request({ type: "answer", askId: ask.askId, kind: "permission", optionId: "allow_once" });
  for (const later of [1, 2, 3]) {
    const raised = seen.filter((e) => e.type === "ask");
    if (raised.length >= later + 1) {
      request({
        type: "answer",
        askId: raised[later].askId,
        kind: "permission",
        optionId: "allow_once",
      });
    }
  }
  await expect((e) => e.type === "session.result", "session.result");
  await expect(
    (e) => e.type === "session.status" && e.state === "idle",
    "status settling to idle",
    20_000,
  );
  check(
    !seen.some((e) => e.type === "session.exit"),
    "an idle session is not reaped the moment its turn ends",
  );

  // --- spoken to, and so no longer idle, whatever the clock said a moment ago
  //
  // Read rather than raced: nothing echoes an inbound message back, so a `send`
  // that left this clock alone would read as stale for as long as the turn took
  // to produce its first output — and the tick inside that window would end the
  // turn it had just been handed.
  const idle = (e: any) => e.type === "session.status" && e.state === "idle";
  // Counted here, before the send, and not where it is waited on. The status
  // lands in the same millisecond as the result the wait above returns on, so
  // a baseline taken afterwards already includes it and the wait is for a
  // third that never comes — which reads as the session never settling.
  const idlesBeforeSend = seen.filter(idle).length;

  const beforeSend = await clockFor(key);
  request({ type: "send", key, text: "Reply with the word ok and nothing else." });
  const afterSend = await clockFor(key);
  check(
    beforeSend !== undefined && afterSend !== undefined && afterSend > beforeSend,
    `being sent to dates a session (${beforeSend} -> ${afterSend})`,
  );
  await expectAnother(
    (e) => e.type === "session.result" && e.key === key,
    "the sent turn finishing",
    60_000,
  );
  check(
    !seen.some((e) => e.type === "session.exit"),
    "the turn it was handed finished rather than being cut off",
  );
  await expectSince(
    idle,
    idlesBeforeSend,
    "status settling to idle again",
    20_000,
  );

  // The same for a request that changes nothing: the mode it is already in is
  // still someone reaching for the session.
  const beforeMode = await clockFor(key);
  const lastTouchedAt = Date.now();
  const modeId = request({ type: "mode", key, permissionMode: init.permissionMode });
  await expect((e) => e.type === "reply" && e.id === modeId, "mode reply");
  const afterMode = await clockFor(key);
  check(
    beforeMode !== undefined && afterMode !== undefined && afterMode > beforeMode,
    `a mode request dates a session even when it moves nothing (${beforeMode} -> ${afterMode})`,
  );

  const exit = await expect((e) => e.type === "session.exit" && e.key === key, "the reap", 60_000);
  const waited = Date.now() - lastTouchedAt;
  check(waited >= REAP_AFTER_MS, `it was left alone for the whole window first (${waited}ms)`);
  check(exit.key === key, "the reap is announced as an exit, which is what retires the row");
  check((await heldSessions()).length === 0, "the host no longer holds it");

  // Housekeeping, and it has to read as housekeeping. `done` is the app's word
  // for a turn that has just ended: said here it posts a Finished notification
  // and lifts a row you dismissed yesterday back to the top of the list, for a
  // session that had said nothing for a day.
  const finished = (e: any) =>
    e.type === "session.status" && e.key === key && e.state === "done";
  check(!seen.some(finished), "a reap says nothing about the session's state");
  check(exit.reason === "retired", `the exit says who ended it (${exit.reason})`);

  // The reading everything above rests on. Polled rather than sampled once: the
  // exit is announced when the session's stream ends, and the CLI is torn down
  // around that moment rather than before it.
  const announcedAt = Date.now();
  let remaining = sessionProcesses();
  for (let attempt = 0; attempt < 50 && remaining > 0; attempt++) {
    await sleep(100);
    remaining = sessionProcesses();
  }
  check(
    remaining === 0,
    `the reaped session's CLI is gone with it (${remaining} left, ${Date.now() - announcedAt}ms after the exit)`,
  );

  // --- and the row can be picked up again under the key it was reaped under
  const resumeId = request({
    type: "start",
    ...credential,
    cwd: scratch,
    prompt: "What filename did you just create? Reply with the name alone.",
    settingSources: [],
    resume: init.sessionId,
    key,
  });
  const resumed = await expect((e) => e.type === "reply" && e.id === resumeId, "resume reply");
  check(resumed.ok === true, `a reaped session's key is free to resume under (${resumed.error ?? ""})`);
  const resumedInit = await expect(
    (e) => e.type === "session.init" && e.key === key,
    "resumed session.init",
  );
  check(
    resumedInit.sessionId === init.sessionId,
    "the resumed conversation is the one that was reaped",
  );

  request({ type: "stop", key });
  const stopped = await expect(
    (e) => e.type === "session.exit" && e.key === key && e !== exit,
    "stop's exit",
    30_000,
  );
  check(!seen.some(finished), "nor does a stop asked for from the app");
  check(stopped.reason === "retired", `which is the same retirement (${stopped.reason})`);

  // --- with nothing left to hold and nobody watching, the host retires itself
  //
  // Unreachable before any of this: the idle exit asks for an empty session map,
  // and nothing ever emptied it, so a host lived until it was killed by hand.
  socket.destroy();
  for (let attempt = 0; attempt < 100 && hostAlive; attempt++) await sleep(100);
  check(!hostAlive, "a host with nothing left to run lets itself go");
} catch (error: any) {
  check(false, `threw: ${error?.message ?? error}`);
  console.error("\nevents seen:");
  for (const event of seen) {
    console.error(
      `  ${event.type}${event.state ? `/${event.state}` : ""}${event.subtype ? `/${event.subtype}` : ""}`,
    );
  }
} finally {
  socket.destroy();
  host.kill("SIGTERM");
  await sleep(300);
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length === 0 ? "\nreap: all checks passed" : `\nreap: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
