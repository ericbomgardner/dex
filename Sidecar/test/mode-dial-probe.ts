/**
 * What the pane's mode dial gets back when it moves a running session.
 *
 *   node test/mode-dial-probe.ts
 *
 * The dial shows the pick at once and never puts one back, so what it shows is
 * only ever as true as what the session says about itself afterwards. Driven
 * over the socket rather than through the SDK, because the app's path is a
 * `mode` request and what comes back on the wire — not `setPermissionMode` on
 * its own.
 *
 * Three readings, against SDK 0.3.227 / CLI v2.1.234 on 2026-08-18:
 *
 *   takes       a `mode` request is taken whatever the session is doing —
 *               parked on an ask, or idle between turns. Which of the two a
 *               request measured is proved where it is issued and printed
 *               there: parked means the ask is still unanswered and unwithdrawn
 *               at that moment, idle means the turn's `session.result` has
 *               arrived, no ask is standing and no further `session.init` has.
 *               Two of the three requests here are parked ones — the first
 *               change and the change back — and reading either as the idle
 *               case leaves that half of the reading unmeasured
 *   reports     the session says the mode back on `session.mode`, with no
 *               further prompt. That is what the dial leans on instead of
 *               putting a refused change back itself
 *   leaves      approving a plan moves the session out of plan mode, and the
 *               same event is the only word for it. Nothing else on this wire
 *               says so before the next turn's `session.init`
 *
 * The last one is what `session.mode` exists for, and the reading to re-run:
 * it is the CLI's own `system` messages restating `permissionMode`, which is
 * not something the SDK promises to keep doing. If it stops, a dial left on
 * plan by an approved plan stays there until the next turn.
 */

import net from "node:net";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startCredential } from "./credential.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostEntry = path.join(here, "..", "src", "host.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "mode-dial-probe-"));
const socketPath = path.join(scratch, "host.sock");

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const credential = startCredential("mode-dial-probe");

const host = spawn(process.execPath, [hostEntry], {
  env: { ...process.env, DEX_HOST_SOCKET: socketPath },
  stdio: ["ignore", "pipe", "pipe"],
});
host.stderr.on("data", (chunk) => process.stderr.write(`[host] ${chunk}`));

for (let attempt = 0; attempt < 100 && !existsSync(socketPath); attempt++) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

const socket = net.connect(socketPath);
await new Promise((resolve) => socket.once("connect", resolve));

const seen: any[] = [];
const answered = new Set<string>();
let waveOff = false;
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
      // Once the plan is approved the session goes and does the work, and a
      // turn parked on an ask nobody answers never reaches the next prompt.
      if (waveOff && event.type === "ask" && !answered.has(event.askId)) {
        answered.add(event.askId);
        request({
          type: "answer",
          askId: event.askId,
          kind: "permission",
          optionId: "reject_once",
          message: "Stop here, the probe has what it needs.",
        });
      }
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

async function setMode(key: string, permissionMode: string): Promise<any> {
  const id = request({ type: "mode", key, permissionMode });
  return expect((e) => e.type === "reply" && e.id === id, `mode reply (${permissionMode})`);
}

try {
  request({ type: "hello", protocol: 1 });
  await expect((e) => e.type === "welcome", "welcome");

  const startId = request({
    type: "start",
    ...credential,
    cwd: scratch,
    prompt:
      "Plan the creation of a file called probe.txt containing the text OK. " +
      "Present the plan with ExitPlanMode. Do not ask me anything first.",
    permissionMode: "plan",
    settingSources: [],
  });
  const started = await expect((e) => e.type === "reply" && e.id === startId, "start reply");
  const key = started.key;
  const init = await expect((e) => e.type === "session.init", "session.init");
  check(init.permissionMode === "plan", `the session starts in plan (${init.permissionMode})`);

  // --- a session holding out an ask still takes a change
  const firstAsk = await expect((e) => e.type === "ask" && e.key === key, "an ask");

  const standing = (askId: string) =>
    !answered.has(askId) && !seen.some((e) => e.type === "ask.withdrawn" && e.askId === askId);

  function parked(label: string): boolean {
    const still = standing(firstAsk.askId);
    console.log(
      `  ${label}: parked — ask ${firstAsk.askId} (${firstAsk.toolName}) ` +
        `${still ? "still unanswered" : "ALREADY ANSWERED OR WITHDRAWN"}`,
    );
    return still;
  }

  const firstPhase = parked("mode request 1");
  const whileParked = await setMode(key, "auto");
  check(firstPhase, "the first change was issued with that ask still standing (phase)");
  check(whileParked.ok === true, `a parked session takes the change (${whileParked.error ?? "ok"})`);
  const parkedReport = await expect(
    (e) => e.type === "session.mode" && e.key === key && e.permissionMode === "auto",
    "session.mode after the parked change",
    30_000,
  );
  check(parkedReport.permissionMode === "auto", "and says the mode back with no further prompt");

  // --- back to plan, so the plan the session is holding is still a plan
  const secondPhase = parked("mode request 2");
  const backToPlan = await setMode(key, "plan");
  check(secondPhase, "the change back was issued with that same ask still standing (phase)");
  check(
    backToPlan.ok === true,
    `a session parked on an unanswered ask takes a second change (${backToPlan.error ?? "ok"})`,
  );
  await expect(
    (e) => e.type === "session.mode" && e.key === key && e.permissionMode === "plan",
    "session.mode back to plan",
    30_000,
  );

  // --- approving the plan is a mode change nobody asked the host for
  const exitPlan = firstAsk.toolName === "ExitPlanMode"
    ? firstAsk
    : await expect(
        (e) => e.type === "ask" && e.key === key && e.toolName === "ExitPlanMode",
        "an ExitPlanMode ask",
      );
  if (firstAsk.toolName !== "ExitPlanMode") {
    answered.add(firstAsk.askId);
    request({ type: "answer", askId: firstAsk.askId, kind: "permission", optionId: "allow_once" });
  }
  answered.add(exitPlan.askId);
  waveOff = true;
  request({ type: "answer", askId: exitPlan.askId, kind: "permission", optionId: "allow_once" });
  const left = await expect(
    (e) => e.type === "session.mode" && e.key === key && e.permissionMode !== "plan",
    "session.mode leaving plan",
    60_000,
  );
  check(
    left.permissionMode !== "plan",
    `approving the plan left plan mode (${left.permissionMode})`,
  );

  // --- and the next turn agrees
  const before = seen.filter((e) => e.type === "session.init" && e.key === key).length;
  check(before === 1, `session.init arrives once per turn (${before} so far)`);
  await expect((e) => e.type === "session.result" && e.key === key, "the turn ending");

  // --- and the same request between turns, which is the half the two above
  // cannot measure: both were issued with the ask still out.
  const initsNow = seen.filter((e) => e.type === "session.init" && e.key === key).length;
  const asksOut = seen.filter((e) => e.type === "ask" && e.key === key && standing(e.askId));
  console.log(
    `  mode request 3: idle between turns — session.result in, ${asksOut.length} ask(s) standing, ` +
      `${initsNow} session.init so far (${before} before the result)`,
  );
  const whileIdle = await setMode(key, "default");
  check(
    asksOut.length === 0 && initsNow === before,
    "the third change was issued between turns: the result had arrived, nothing was parked, no new turn had begun (phase)",
  );
  check(whileIdle.ok === true, `an idle session takes the change (${whileIdle.error ?? "ok"})`);
  const idleReport = await expect(
    (e) => e.type === "session.mode" && e.key === key && e.permissionMode === "default",
    "session.mode after the idle change",
    30_000,
  );
  check(
    idleReport.permissionMode === "default",
    "and says that one back too, with no turn to carry it",
  );
  const restored = await setMode(key, left.permissionMode);
  check(restored.ok === true, `and takes the mode back to where the plan left it (${left.permissionMode})`);

  request({ type: "send", key, text: "In one word, what permission mode are you in?" });
  const reasserted = await expect(
    (e) =>
      e.type === "session.init" &&
      e.key === key &&
      seen.filter((s) => s.type === "session.init" && s.key === key).length > before,
    "a second session.init",
  );
  check(
    reasserted.permissionMode === left.permissionMode,
    `the next turn's session.init agrees (${reasserted.permissionMode})`,
  );

  // --- a mode the host has never heard of is refused, and says so
  const nonsense = await setMode(key, "zoom");
  check(nonsense.ok === false, "an unknown mode is refused");

  request({ type: "stop", key });
} finally {
  socket.destroy();
  host.kill();
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\n${failures.length} failed` : "\nall ok");
process.exit(failures.length ? 1 : 0);
