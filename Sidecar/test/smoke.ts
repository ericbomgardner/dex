/**
 * Drives a host of its own over the socket, end to end: hello, start a
 * session, catch the permission ask it raises, answer it, and see the turn
 * finish. A Bash call is used rather than a clarifying question because the
 * model asks it every time, which a question is not guaranteed to be.
 *
 *   node test/smoke.ts
 */

import net from "node:net";
import { spawn } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostEntry = path.join(here, "..", "src", "host.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "dex-smoke-"));
const socketPath = path.join(scratch, "host.sock");

const dumpPath = process.env.DEX_SMOKE_DUMP ?? null;
if (dumpPath) writeFileSync(dumpPath, "");

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const apiKey = process.env.ANTHROPIC_API_KEY;
// What every session start below carries: the key, and haiku, since nothing here measures the model.
let credential: Record<string, string> | null = apiKey ? { apiKey, model: "haiku" } : null;
if (!credential) {
  console.error("smoke: set ANTHROPIC_API_KEY; its sessions run on it");
  process.exit(2);
}
const start = { type: "start", ...credential };

const host = spawn(process.execPath, [hostEntry], {
  env: { ...process.env, DEX_HOST_SOCKET: socketPath },
  stdio: ["ignore", "pipe", "pipe"],
});
host.stderr.on("data", (chunk) => process.stderr.write(`[host] ${chunk}`));

async function waitForSocket(): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (existsSync(socketPath)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("host never created its socket");
}

await waitForSocket();

const socket = net.connect(socketPath);
await new Promise((resolve) => socket.once("connect", resolve));

const seen: any[] = [];
const waiters: { match: (event: any) => boolean; resolve: (event: any) => void }[] = [];

/**
 * Off until the first ask has been inspected, then every ask is allowed.
 * A turn can raise more than one, and a client that answers only the first
 * leaves the session parked on the second forever.
 */
let autoAnswer = false;
const answered = new Set<string>();

let buffer = "";
socket.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let newline = buffer.indexOf("\n");
  while (newline !== -1) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) {
      // DEX_SMOKE_DUMP captures the wire verbatim, so the Swift
      // decoder can be pinned against bytes a real host actually wrote.
      if (dumpPath) appendFileSync(dumpPath, `${line}\n`);
      const event = JSON.parse(line);
      seen.push(event);
      if (autoAnswer && event.type === "ask" && !answered.has(event.askId)) {
        answered.add(event.askId);
        request({ type: "answer", askId: event.askId, kind: "permission", optionId: "allow_once" });
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

/** How much of a session's own transcript is on disk, by the id it is filed under. */
function transcriptLines(sessionId: string): number {
  const projects = path.join(homedir(), ".claude", "projects");
  for (const slug of readdirSync(projects)) {
    const candidate = path.join(projects, slug, `${sessionId}.jsonl`);
    if (!existsSync(candidate)) continue;
    return readFileSync(candidate, "utf8").split("\n").filter(Boolean).length;
  }
  return 0;
}

/**
 * The same count, once the file has stopped growing. A transcript lags the
 * events that produce it — the turn a stopped session finished is still landing
 * when its stop is acknowledged — so a baseline sampled on the acknowledgement
 * undercounts, and the growth it is later compared against undercounts too.
 */
async function settledTranscriptLines(sessionId: string, quietMs = 1_000): Promise<number> {
  const deadline = Date.now() + 20_000;
  let lines = transcriptLines(sessionId);
  let quietSince = Date.now();
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    const now = transcriptLines(sessionId);
    if (now !== lines) {
      lines = now;
      quietSince = Date.now();
      continue;
    }
    if (Date.now() - quietSince >= quietMs) break;
  }
  return lines;
}

/** Waits for a transcript to pass a mark, rather than sampling once and hoping. */
async function awaitTranscriptLines(sessionId: string, above: number): Promise<number> {
  const deadline = Date.now() + 20_000;
  let lines = transcriptLines(sessionId);
  while (lines <= above && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    lines = transcriptLines(sessionId);
  }
  return lines;
}

/** A fresh client's welcome, which is the only place the host says what it is. */
async function handshake(): Promise<{ welcome: any; socket: net.Socket }> {
  const client = net.connect(socketPath);
  await new Promise((resolve) => client.once("connect", resolve));
  const welcome = await new Promise<any>((resolve) => {
    let tail = "";
    client.on("data", (chunk) => {
      tail += chunk.toString("utf8");
      for (const line of tail.split("\n")) {
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "welcome") resolve(event);
      }
    });
    client.write(`${JSON.stringify({ id: "hs", type: "hello", protocol: 1 })}\n`);
  });
  return { welcome, socket: client };
}

let counter = 0;
function request(body: Record<string, unknown>): string {
  const id = `r${++counter}`;
  socket.write(`${JSON.stringify({ id, ...body })}\n`);
  return id;
}

try {
  // --- the takeover's own word, in-process: which line of a script drives
  // the screen. A session's mark can sit at the very bottom of a heredoc,
  // and the card names this line rather than the command's first.
  {
    const { screenDrive } = await import("../src/screen.ts");
    const script =
      "python3 - <<'EOF'\nprint(1)\nEOF\n" +
      "make check && DEX_DRIVES_SCREEN=1 python3 build.py > /tmp/log 2>&1";
    const drive = screenDrive("Bash", { command: script });
    check(
      drive?.line === "make check && DEX_DRIVES_SCREEN=1 python3 build.py > /tmp/log 2>&1" &&
        drive?.match === "DEX_DRIVES_SCREEN=1",
      "a marked script names the line carrying the mark",
    );
    check(
      screenDrive("Bash", { command: "cliclick c:100,200" })?.match === "cliclick",
      "an unmarked habit names what the net caught",
    );
    check(screenDrive("Bash", { command: "ls -la" }) === null, "a plain command drives nothing");
    check(
      screenDrive("Bash", { command: "git merge --ff-only goal-drag 2>&1 | tail -1" }) === null,
      "a name ending in drag before a redirect drives nothing",
    );
    check(
      screenDrive("Bash", { command: "/tmp/drive drag 100 200" })?.match === "drag 100",
      "a drag to coordinates still drives",
    );
    check(
      screenDrive("Bash", {
        command: "cat > /tmp/press.swift <<'E'\nCGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)!.postToPid(pid)\nE",
      }) === null,
      "a CGEvent sent to a pid drives nothing",
    );
    check(
      screenDrive("Bash", { command: "swift - <<'E'\nev.post(tap: .cghidEventTap)\nE" })?.match === "cghidEventTap",
      "a CGEvent posted to the HID tap still drives",
    );
    check(
      screenDrive("Bash", {
        command: "git commit -q -F - <<'E'\nStop a hidden text view taking keystrokes\n\nThe next keystroke goes to the field.\nE",
      }) === null,
      "keystroke in prose drives nothing",
    );
    check(
      screenDrive("Bash", {
        command: `osascript -e 'tell application "System Events" to keystroke "1" using command down'`,
      })?.match === 'keystroke "',
      "a System Events keystroke still drives",
    );
    check(
      screenDrive("Bash", { command: `osascript -e 'tell application "System Events" to key code 53'` })?.match ===
        "key code 5",
      "a System Events key code still drives",
    );
    check(screenDrive("Read", { command: "cliclick c:1,1" }) === null, "only a shell can drive");
    check(
      screenDrive("Monitor", { command: "DEX_DRIVES_SCREEN=1 /tmp/drive click 1 2" })?.match === "DEX_DRIVES_SCREEN=1",
      "a marked Monitor drives",
    );
    check(screenDrive("Monitor", { command: "tail -f /tmp/log" }) === null, "a plain Monitor drives nothing");
  }

  // --- handshake
  request({ type: "hello", protocol: 1 });
  const welcome = await expect((e) => e.type === "welcome", "welcome");
  check(welcome.protocol === 1, "welcome states protocol 1");
  check(typeof welcome.sdk === "string" && welcome.sdk !== "unknown", `welcome names the sdk (${welcome.sdk})`);
  // Null when the test runs from a checkout (no build.json beside the sidecar) —
  // the point is the key is always present, so the app can tell "no stamp" from
  // "field absent" and never read a checkout host as stale.
  check("build" in welcome, "welcome carries a build stamp field, even if null");
  check(Array.isArray(welcome.sessions) && welcome.sessions.length === 0, "fresh host has no sessions");
  check(welcome.capabilities?.includes("rename"), "welcome says it can rename");
  check(welcome.capabilities?.includes("side"), "welcome says it takes side questions");
  check(
    Array.isArray(welcome.efforts) && welcome.efforts.includes("max"),
    `welcome lists the efforts an \`effort\` request takes (${welcome.efforts?.join(", ")})`,
  );
  // Empty here and not later: the list lives on a running session's
  // `initializationResult()`, so a host that has started nothing has nothing to
  // say. It is why the app keeps its own copy.
  check(
    Array.isArray(welcome.outputStyles) && welcome.outputStyles.length === 0,
    "a fresh host knows no output styles until a session has found them",
  );
  check(
    Array.isArray(welcome.modes) && welcome.modes.includes("plan"),
    `welcome lists the permission modes (${welcome.modes?.length})`,
  );

  // --- what the host loaded, against what is on disk under it
  //
  // Measured by moving the version on disk while the host runs, because that is
  // the situation the pair exists for: the host outlives the app and is not
  // rebuilt with it, so a build lands under a process still running the one
  // before it. Read at welcome time -- which `sdk` used to be -- both halves
  // name the new build and nothing on the wire says the process is behind.
  const manifest = path.join(
    here, "..", "node_modules", "@anthropic-ai", "claude-agent-sdk", "package.json",
  );
  const manifestText = readFileSync(manifest, "utf8");
  let moved: any;
  try {
    writeFileSync(manifest, manifestText.replace(/"version": "[^"]+"/, '"version": "9.9.9"'));
    const second = await handshake();
    moved = second.welcome;
    second.socket.destroy();
  } finally {
    writeFileSync(manifest, manifestText);
  }
  check(
    moved.sdk === welcome.sdk,
    `the sdk a welcome names is frozen at the host's start (${moved.sdk})`,
  );
  check(
    moved.sdkOnDisk === "9.9.9",
    `and the one beside it is read fresh (${moved.sdkOnDisk})`,
  );

  // --- start
  const startId = request({
    ...start,
    cwd: scratch,
    // A file write rather than a shell command: the CLI treats some commands as
    // read-only and approves them without asking, and this test needs an ask.
    prompt: "Create a file called smoke.txt containing the text OK, then stop.",
    // No settings, so no allow rule can pre-approve the Bash call and skip the
    // ask this test exists to catch. The app deliberately does the opposite.
    settingSources: [],
    // Sent the way the app sends them. `settingSources: []` means the style
    // named here is one the CLI cannot find, which is deliberate: what is being
    // measured is that the host takes the field and the session still comes up,
    // not what the model does with it. That half is `output-style-probe.ts`.
    outputStyle: "Concise",
    effort: "low",
  });
  const started = await expect((e) => e.type === "reply" && e.id === startId, "start reply");
  check(started.ok === true && typeof started.key === "string", "start returns a session key");
  const key = started.key;

  const init = await expect((e) => e.type === "session.init", "session.init");
  check(typeof init.sessionId === "string" && init.sessionId.length > 0, `session.init carries a session id (${init.sessionId})`);
  check(init.key === key, "session.init matches the key start returned");
  check(Array.isArray(init.tools) && init.tools.length > 0, `session.init lists tools (${init.tools.length})`);
  check(typeof init.permissionMode === "string", `session.init names the mode (${init.permissionMode})`);
  // The list the CLI will actually dispatch, which is not the list it ships:
  // the ones that only open a panel in a terminal are left out of it, and that
  // absence is the whole of what greys a row in the app's slash menu.
  check(Array.isArray(init.commands) && init.commands.length > 0, `session.init lists commands (${init.commands?.length})`);
  check(init.commands.includes("model"), "session.init names a command a hosted session runs");
  check(!init.commands.includes("help"), "session.init leaves out one it can only open in a terminal");
  // The CLI's own word for what it resolved, which is not always what was
  // asked for — the style above names no file this session can see.
  check(
    "outputStyle" in init,
    `session.init names the style the CLI resolved (${init.outputStyle})`,
  );
  // The level the session was started at, on the one message that says it
  // started. The app hears it nowhere else until the dial moves it: the summary
  // that carries a level rides on the welcome, which an app already connected
  // had long before this session existed.
  check(
    init.effort === "low",
    `session.init names the level it was started at (${JSON.stringify(init.effort)})`,
  );

  // --- the ask
  const ask = await expect((e) => e.type === "ask", "an ask");
  check(ask.kind === "permission", `ask is a permission (tool ${ask.toolName})`);
  check(typeof ask.input === "object" && ask.input !== null, "ask carries typed input");
  check(
    ask.options?.some((o: any) => o.kind === "allow_once") &&
      ask.options?.some((o: any) => o.kind === "reject_once"),
    `ask offers its options (${ask.options?.map((o: any) => o.optionId).join(", ")})`,
  );
  const asking = await expect(
    (e) => e.type === "session.status" && e.state === "asking",
    "status to go to asking",
  );
  check(
    seen.indexOf(ask) < seen.indexOf(asking),
    "the ask arrives before the status that says the session is asking",
  );

  // --- second client sees the parked ask on reconnect
  const { welcome: reconnected, socket: observer } = await handshake();
  check(reconnected.sessions.length === 1, "a reconnecting client is told about the live session");
  check(
    reconnected.pending.some((p: any) => p.askId === ask.askId),
    "a reconnecting client is handed the ask still on screen",
  );
  // Without this the app can only date a session from the moment it connected,
  // which un-dismisses every hosted row it had dismissed in an earlier run.
  const live = reconnected.sessions[0];
  check(
    typeof live?.lastActivityAt === "string" && live.lastActivityAt > live.startedAt,
    `a reconnecting client is told when the session was last busy (${live?.lastActivityAt})`,
  );
  // `init` is emitted once a turn, so without the replay a session idle since
  // before the app connected has nothing to say about what it will run, and
  // every row in its slash menu would read as offerable.
  check(
    Array.isArray(live?.commands) && live.commands.includes("model"),
    `a reconnecting client is told what the session will run (${live?.commands?.length})`,
  );
  observer.destroy();

  // --- answer it, and anything else the turn raises
  autoAnswer = true;
  answered.add(ask.askId);
  request({ type: "answer", askId: ask.askId, kind: "permission", optionId: "allow_once" });
  const result = await expect((e) => e.type === "session.result", "session.result");
  check(answered.size >= 1, `answered ${answered.size} ask(s)`);
  check(result.subtype === "success", `turn finished (${result.subtype})`);
  // Waited for rather than sampled: the host writes the result and the status
  // behind it, and a socket that splits them between two reads would be judged
  // on the half that had arrived.
  await expect(
    (e) => e.type === "session.status" && e.state === "idle",
    "status settling to idle",
    20_000,
  );
  check(
    !seen.some((e) => e.type === "session.status" && e.state === "done"),
    "status settled to idle rather than done",
  );

  // --- the dial's half
  //
  // Only that the wire carries it: whether the next turn actually thinks at the
  // new level is `output-style-probe.ts`, which reads it off `CLAUDE_EFFORT`.
  const effortId = request({ type: "effort", key, effort: "high" });
  const efforted = await expect((e) => e.type === "reply" && e.id === effortId, "effort reply");
  check(efforted.ok === true, `an effort change is taken (${efforted.error ?? "ok"})`);
  const effortEvent = await expect(
    (e) => e.type === "session.effort" && e.key === key,
    "session.effort",
  );
  check(effortEvent.effort === "high", "the host says the level back, since nothing else will");

  // Checked against the host's own list, the way a mode is. A level that
  // launches under one name and moves under another would be refused here.
  const oddId = request({ type: "effort", key, effort: "ludicrous" });
  const odd = await expect((e) => e.type === "reply" && e.id === oddId, "odd effort reply");
  check(odd.ok === false, `an effort the host does not know is refused (${odd.error})`);

  const renameId = request({ type: "rename", sessionId: init.sessionId, title: "  Smoke name  " });
  const renamed = await expect((e) => e.type === "reply" && e.id === renameId, "rename reply");
  check(renamed.ok === true, `a running session is renamed (${renamed.error ?? "ok"})`);
  const titles = readdirSync(path.join(homedir(), ".claude", "projects"))
    .map((slug) => path.join(homedir(), ".claude", "projects", slug, `${init.sessionId}.jsonl`))
    .filter(existsSync)
    .flatMap((file) => readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)))
    .filter((record) => record.type === "custom-title");
  check(titles.at(-1)?.customTitle === "Smoke name", `it lands trimmed as a custom-title (${JSON.stringify(titles.at(-1))})`);
  const blankId = request({ type: "rename", sessionId: init.sessionId, title: "   " });
  const blank = await expect((e) => e.type === "reply" && e.id === blankId, "blank rename reply");
  check(blank.ok === false, `a blank name is refused (${blank.error})`);

  const beforeSide = seen.length;
  const sideId = request({ type: "side", key, question: "Reply with only the word ok." });
  const side = await expect((e) => e.type === "reply" && e.id === sideId, "side question reply");
  check(side.ok === true && typeof side.response === "string", `a side question is answered (${side.error ?? side.response})`);
  check(
    !seen.slice(beforeSide).some((e) => e.type === "session.status" && e.key === key && e.state === "running"),
    "a side question doesn't read as the session working",
  );
  const lostId = request({ type: "side", key: "no-such-key", question: "Anyone?" });
  const lost = await expect((e) => e.type === "reply" && e.id === lostId, "lost side question reply");
  check(lost.ok === false, `a side question to no session is refused (${lost.error})`);

  // What the pickers' Default row is named after. Asked for a folder rather
  // than a session, because the pickers are open before anything is running —
  // and answered in-process, which is what makes it cheap enough to ask again
  // every time the composer changes folder.
  const defaultsId = request({ type: "defaults", cwd: scratch });
  const defaulted = await expect(
    (e) => e.type === "reply" && e.id === defaultsId,
    "defaults reply",
  );
  check(defaulted.ok === true, `the host resolves a folder's defaults (${defaulted.error ?? "ok"})`);
  const resolved = await expect((e) => e.type === "host.defaults", "host.defaults");
  check(resolved.cwd === scratch, "the answer names the folder it was asked about");
  // Null rather than absent where the cascade sets nothing: the picker says
  // Default and stops, rather than naming a level no file asked for.
  check(
    "outputStyle" in resolved && "effort" in resolved && "model" in resolved,
    `all three keys are answered (${JSON.stringify(resolved.outputStyle)} / ${JSON.stringify(resolved.effort)} / ${JSON.stringify(resolved.model)})`,
  );
  // The merged `effort` no longer reaches every model, so the files behind it
  // go too; the app picks the level per model off them.
  check(
    Array.isArray(resolved.efforts) && resolved.efforts.every((f: any) => typeof f.source === "string" && typeof f.models === "object"),
    `each file's effort is sent beside the merged one (${JSON.stringify(resolved.efforts)})`,
  );

  // A folder whose settings pin a model gets that model back — the model chip
  // names a Default launch from this, so the pin has to survive the whole trip
  // and not just resolveSettings. Its own folder, never one a session runs in:
  // a pin where sessions start would move what the rest of this file measures.
  const pinned = path.join(scratch, "pinned-model");
  mkdirSync(path.join(pinned, ".claude"), { recursive: true });
  writeFileSync(path.join(pinned, ".claude", "settings.json"), JSON.stringify({ model: "sonnet" }));
  const pinnedId = request({ type: "defaults", cwd: pinned });
  await expect((e) => e.type === "reply" && e.id === pinnedId, "pinned defaults reply");
  const pinnedDefaults = await expect(
    (e) => e.type === "host.defaults" && e.cwd === pinned,
    "pinned host.defaults",
  );
  check(
    pinnedDefaults.model === "sonnet",
    `a folder's own model pin comes back (${JSON.stringify(pinnedDefaults.model)})`,
  );

  // A folder can move the model without the model key: env.ANTHROPIC_MODEL is
  // honoured by the CLI the session runs. Measured rather than assumed — this
  // is the check that says the resolver's merged answer carries env at all.
  const envPinned = path.join(scratch, "env-pinned-model");
  mkdirSync(path.join(envPinned, ".claude"), { recursive: true });
  writeFileSync(
    path.join(envPinned, ".claude", "settings.json"),
    JSON.stringify({ env: { ANTHROPIC_MODEL: "claude-opus-4-1" } }),
  );
  const envPinnedId = request({ type: "defaults", cwd: envPinned });
  await expect((e) => e.type === "reply" && e.id === envPinnedId, "env-pinned defaults reply");
  const envPinnedDefaults = await expect(
    (e) => e.type === "host.defaults" && e.cwd === envPinned,
    "env-pinned host.defaults",
  );
  check(
    envPinnedDefaults.model === "claude-opus-4-1",
    `an env model pin counts as the folder's pin (${JSON.stringify(envPinnedDefaults.model)})`,
  );

  // Learned from the session rather than known: the app's picker has no table.
  const styles = await expect((e) => e.type === "host.styles", "host.styles");
  check(
    Array.isArray(styles.styles) && styles.styles.length > 0,
    `a session reports the styles the CLI has (${styles.styles?.join(", ")})`,
  );

  // --- stop
  const stopId = request({ type: "stop", key });
  const stopped = await expect((e) => e.type === "reply" && e.id === stopId, "stop reply");
  check(stopped.ok === true, "stop is acknowledged");

  // --- and pick the same conversation up again
  //
  // Keeping the transcript id is the whole of it: a resumed session that forked
  // to a new one would leave every row bound to a file that stops growing.
  const linesBeforeResume = await settledTranscriptLines(init.sessionId);
  check(linesBeforeResume > 0, `the finished session left a transcript (${linesBeforeResume} lines)`);

  const resumeId = request({
    ...start,
    cwd: scratch,
    prompt: "What filename did you just create? Reply with the name alone.",
    settingSources: [],
    resume: init.sessionId,
    // The key the stopped session had, which is how it comes back as the same
    // row rather than as a stranger.
    key,
  });
  const resumeStarted = await expect(
    (e) => e.type === "reply" && e.id === resumeId,
    "resumed start reply",
  );
  check(resumeStarted.ok === true, "a resume is accepted");
  check(resumeStarted.key === key, "a resume comes back under the key it was given");

  const resumedInit = await expect(
    (e) => e.type === "session.init" && e.key === resumeStarted.key,
    "resumed session.init",
  );
  check(
    resumedInit.sessionId === init.sessionId,
    `a resume keeps the transcript id (${resumedInit.sessionId})`,
  );

  await expect(
    (e) => e.type === "session.result" && e.key === resumeStarted.key,
    "resumed session.result",
  );

  const clashId = request({ ...start, cwd: scratch, prompt: "hello", key });
  const clash = await expect((e) => e.type === "reply" && e.id === clashId, "clashing start reply");
  check(clash.ok === false, `a key already running is refused (${clash.error})`);

  // The request reaches a session rather than falling through to "unknown
  // request", which is the half of stopping an agent that lives on this wire.
  // What stopTask does to a running agent is `stop-agent-probe.ts`; this is only
  // that the host still knows the word.
  const stopTaskId = request({
    type: "stopTask",
    key: resumeStarted.key,
    taskId: "no-such-task",
  });
  const stopTask = await expect(
    (e) => e.type === "reply" && e.id === stopTaskId,
    "stopTask reply",
  );
  check(
    stopTask.error !== "unknown request",
    `stopTask reaches the session rather than the host's default arm (${stopTask.error ?? "accepted"})`,
  );

  const strayId = request({ type: "stopTask", key: "no-such-session", taskId: "t" });
  const stray = await expect((e) => e.type === "reply" && e.id === strayId, "stray stopTask reply");
  check(stray.ok === false, `stopping a task on a session that isn't there is refused (${stray.error})`);

  // --- a stop on the opening turn
  //
  // Sent the moment the start is answered, before the CLI has begun the turn.
  // Through v2.1.260 the CLI absorbed an interrupt with no turn behind it and
  // ran the prompt anyway; the pane's Stop over an empty transcript relies on
  // it landing now.
  const hastyId = request({
    ...start,
    cwd: scratch,
    prompt: "Count from 1 to 400, one number per line, then say DONE.",
    settingSources: [],
    effort: "low",
  });
  const hasty = await expect((e) => e.type === "reply" && e.id === hastyId, "opening-stop start reply");
  request({ type: "interrupt", key: hasty.key });
  const hastyResult = await expect(
    (e) => e.type === "session.result" && e.key === hasty.key,
    "session.result for the opening-stop session",
    60_000,
  );
  check(
    hastyResult.subtype !== "success",
    `an interrupt sent before the first turn stops it (${hastyResult.subtype})`,
  );
  request({ type: "stop", key: hasty.key });

  // --- a start that fails on its way up
  //
  // The reply is the app's whole word on a start until a row appears, and an
  // `ok` was all it ever said: a session that died before it could draw one left
  // the app holding a place for it and, twenty seconds later, blaming its own
  // list for being slow. A folder that isn't there is the cheap way to fail a
  // launch — the CLI is found and never runs, so there is no turn and no
  // tokens. What is pinned is that the failure comes back with words on it, and
  // that the key it was given is free again afterwards.
  const deadCwd = path.join(scratch, "no-such-folder");
  const deadKey = "smoke-doomed";
  const deadId = request({
    ...start, cwd: deadCwd, prompt: "hello", settingSources: [], key: deadKey,
  });
  const dead = await expect((e) => e.type === "reply" && e.id === deadId, "doomed start reply");
  // Up front, because this failure is not the synchronous one: the CLI resolves,
  // and only the spawn goes wrong. A host that could not find the CLI at all
  // refuses here instead, which is the other half of the same reading.
  check(dead.ok === true, `a launch that fails at the spawn is not refused up front (${dead.error ?? "ok"})`);
  const deadExit = await expect(
    (e) => e.type === "session.exit" && e.key === deadKey,
    "session.exit for the doomed session",
    60_000,
  );
  check(
    typeof deadExit.reason === "string"
      && deadExit.reason !== "ended" && deadExit.reason !== "retired",
    `it ends with a reason the app can show (${String(deadExit.reason).slice(0, 60)}…)`,
  );

  const retryId = request({ ...start, cwd: deadCwd, prompt: "hello", key: deadKey });
  const retry = await expect((e) => e.type === "reply" && e.id === retryId, "retry reply");
  check(retry.ok === true, `and the key it held is free again (${retry.error ?? "ok"})`);

  // Last, because waiting for it is what makes it true, and everything above
  // is timed: a resumed session's query ends on its own once its turn is done,
  // and the host forgets the key with it, so a wait placed before the clash
  // check would find the key free and read a refusal as a pass.
  const linesAfterResume = await awaitTranscriptLines(init.sessionId, linesBeforeResume);
  check(
    linesAfterResume > linesBeforeResume,
    `the resumed turn was written to the same transcript rather than a new one (${linesBeforeResume} to ${linesAfterResume} lines)`,
  );

  request({ type: "stop", key: resumeStarted.key });
} catch (error: any) {
  check(false, `threw: ${error?.message ?? error}`);
  console.error("\nevents seen:");
  for (const event of seen) {
    console.error(`  ${event.type}${event.state ? `/${event.state}` : ""}${event.subtype ? `/${event.subtype}` : ""}${event.toolName ? ` ${event.toolName}` : ""}`);
  }
} finally {
  socket.destroy();
  host.kill("SIGTERM");
  await new Promise((resolve) => setTimeout(resolve, 300));
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length === 0 ? "\nsmoke: all checks passed" : `\nsmoke: ${failures.length} failed`);
process.exit(failures.length === 0 ? 0 : 1);
