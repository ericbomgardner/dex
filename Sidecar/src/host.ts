import { randomUUID } from "node:crypto";
import net from "node:net";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { hostname } from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

import { renameSession } from "@anthropic-ai/claude-agent-sdk";

import type { LaunchRequest } from "./dex-server.ts";
import { removeKeyFiles, sweepKeyFiles } from "./keyfile.ts";
import { HostedSession } from "./session.ts";
import { resolveDefaults } from "./defaults.ts";
import { holdsWork, mayExit, stirred } from "./exit-policy.ts";
import { readLines } from "./lines.ts";
import { log, logTo, why } from "./log.ts";
import { SUPPORT_FOLDER, configDirectory as readConfigDirectory } from "./support.ts";
import {
  CAPABILITIES,
  EFFORT_LEVELS,
  PERMISSION_MODES,
  PROTOCOL,
  isEffortLevel,
  isPermissionMode,
  type Ask,
  type Event,
  type Request,
} from "./protocol.ts";
import { parseRequest } from "./requests.ts";

const HOST_VERSION = "0.1.0";

const configDirectory = readConfigDirectory();

// Overridable so a probe's host keeps away from the real host's state.
const stateDirectory =
  process.env.DEX_HOST_STATE_DIR ||
  path.join(
    configDirectory,
    SUPPORT_FOLDER,
  );
// Overridable so a test can drive a host of its own without evicting the real one.
const socketPath =
  process.env.DEX_HOST_SOCKET ?? path.join(stateDirectory, "host.sock");
logTo(path.join(stateDirectory, "host.log"));

const sessions = new Map<string, HostedSession>();
const clients = new Set<net.Socket>();
// In the order they said hello; a launch goes to the newest.
const launchers: net.Socket[] = [];

interface PendingLaunch {
  socket: net.Socket;
  resolve: (key: string) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}
const launches = new Map<string, PendingLaunch>();
const LAUNCH_TIMEOUT_MS = 30_000;

// The styles the newest session found on disk. Held here rather than asked for
// on demand because the only place the list exists is a running session's
// `initializationResult()`, and the picker that wants it is one you open before
// starting anything. Empty on a host that has never run a session — which is
// why the app keeps its own copy of the last list it heard.
let outputStyles: string[] = [];

let idleSince: number | null = Date.now();
// A host with no sessions and nobody watching has nothing to keep it alive.
// Overridable so a test's host doesn't linger for minutes after it finishes.
const IDLE_EXIT_MS = Number(process.env.DEX_HOST_IDLE_MS ?? 5 * 60_000);
const IDLE_CHECK_MS = Math.max(250, Math.min(30_000, Math.floor(IDLE_EXIT_MS / 4)));

// How long a session nobody has said anything to keeps its CLI. Each one is a
// process of its own carrying its whole conversation — half a gigabyte, and it
// does not shrink between turns — and nothing else here has ever ended one, so
// a day of work was a day of them, resident until the host itself was killed.
// The conversation is not what dies with it: the transcript is on disk and the
// app remembers what to resume it under, so what a reap costs is the re-read
// on the next message to a session that had been left for a day.
const REAP_AFTER_MS = Number(
  process.env.DEX_REAP_AFTER_MS ?? 24 * 60 * 60_000,
);
const REAP_CHECK_MS = Math.max(250, Math.min(5 * 60_000, Math.floor(REAP_AFTER_MS / 4)));

function sdkVersion(): string {
  try {
    // Resolved by walking up from the entry point rather than requiring
    // package.json, which the package's exports map does not expose.
    let directory = path.dirname(
      createRequire(import.meta.url).resolve("@anthropic-ai/claude-agent-sdk"),
    );
    for (let depth = 0; depth < 5; depth++) {
      const candidate = path.join(directory, "package.json");
      if (existsSync(candidate)) {
        const parsed = JSON.parse(readFileSync(candidate, "utf8"));
        if (parsed.name === "@anthropic-ai/claude-agent-sdk") return parsed.version;
      }
      directory = path.dirname(directory);
    }
  } catch {
    // Falls through to unknown.
  }
  return "unknown";
}

// What this process actually loaded, captured at module load — the SDK is
// imported before the body runs, so this is the package.json that answered for
// it. Asked again later the same function answers for the *disk*, which a
// rebuild replaces under a running host.
const LOADED_SDK = sdkVersion();

// The commit this host's bundle was built from, written by make-app.sh beside
// the sidecar's package.json. A checkout has no stamp and sends null, which the
// app reads as "can't tell" rather than "stale" — the SDK pair above still
// answers for pin moves there.
function buildStamp(): string | null {
  try {
    const parsed = JSON.parse(
      readFileSync(new URL("../build.json", import.meta.url), "utf8"),
    );
    return typeof parsed.commit === "string" ? parsed.commit : null;
  } catch {
    return null;
  }
}
const LOADED_BUILD = buildStamp();

function send(socket: net.Socket, event: Event): void {
  if (socket.destroyed) return;
  socket.write(`${JSON.stringify(event)}\n`);
}

function broadcast(event: Event): void {
  for (const client of clients) send(client, event);
}

/**
 * A session's `start_session`, handed to the app rather than started here: the
 * model, effort and brief a new session gets are decided there, and a session
 * started around them would run on bare CLI defaults.
 */
function launch(request: LaunchRequest): Promise<string> {
  if (!path.isAbsolute(request.cwd) || !existsSync(request.cwd)) {
    return Promise.reject(new Error(`Not started: ${request.cwd} is not a folder on this Mac`));
  }
  const socket = launchers.at(-1);
  if (!socket) return Promise.reject(new Error("Not started: Dex isn't open to start it"));
  const launchId = randomUUID();
  log(`launch ${launchId} from ${request.parent} cwd=${request.cwd}`);
  return new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      launches.delete(launchId);
      reject(new Error("Dex didn't answer within 30s, so it may still have started; look in Dex before asking again"));
    }, LAUNCH_TIMEOUT_MS);
    launches.set(launchId, { socket, resolve, reject, timer });
    send(socket, {
      type: "launch",
      launchId,
      cwd: request.cwd,
      prompt: request.prompt,
      ...(request.name ? { name: request.name } : {}),
      parent: request.parent,
    });
  });
}

function settleLaunch(launchId: string, key: string | undefined, error: string): boolean {
  const pending = launches.get(launchId);
  if (!pending) return false;
  launches.delete(launchId);
  clearTimeout(pending.timer);
  if (key) pending.resolve(key);
  else pending.reject(new Error(error));
  return true;
}

function busy(): boolean {
  return [...sessions.values()].some(holdsWork);
}

function pendingAsks(): Ask[] {
  return [...sessions.values()].flatMap((session) => session.parkedAsks());
}

function sessionFor(key: string): HostedSession | undefined {
  return sessions.get(key);
}

/**
 * Drops a session the host is no longer running. Also reached from the exit a
 * session announces for itself, since one whose query has ended holds no
 * process, cannot be sent to, and — while it stayed in this map — kept its key
 * from ever being resumed under and the host from ever reaching its idle exit.
 */
function forget(key: string): void {
  if (!sessions.delete(key)) return;
  if (sessions.size === 0 && clients.size === 0) idleSince = Date.now();
}

function retire(session: HostedSession, why: string): void {
  log(`${why} ${session.key}`);
  session.stop();
  forget(session.key);
}

type Reply = (ok: boolean, extra?: Record<string, unknown>) => void;

function replyWhenDone<T>(
  reply: Reply,
  failure: string,
  work: Promise<T>,
  extra: (value: T) => Record<string, unknown> = () => ({}),
): void {
  work.then(
    (value) => reply(true, extra(value)),
    (error: unknown) => {
      log(`${failure}: ${why(error)}`);
      reply(false, { error: why(error) });
    },
  );
}

// The longest line a client may send, the same as the app takes from the host;
// anything longer is refused before it is held.
const LINE_CAP = 8 * 1024 * 1024;

function handle(socket: net.Socket, request: Request): void {
  const reply: Reply = (ok, extra = {}) =>
    send(socket, { type: "reply", id: request.id, ok, ...extra });

  stirred();

  // Anything said to a session is news of it, and the reaper reads the same
  // clock as the rows do. Only what a session says moves that clock on its own,
  // so a message handed to one idle long enough to be reaped would leave it
  // reading as stale as ever — and the next tick would end the turn it had just
  // been given, after the send had been answered `ok`.
  if ("key" in request && request.key) sessionFor(request.key)?.touched();

  switch (request.type) {
    case "hello": {
      if (request.protocol !== PROTOCOL) {
        reply(false, {
          error: `protocol ${request.protocol} unsupported, host speaks ${PROTOCOL}`,
        });
        return;
      }
      let mayLaunch = request.launches === true;
      if (mayLaunch && !launchers.includes(socket)) launchers.push(socket);
      send(socket, {
        type: "welcome",
        protocol: PROTOCOL,
        host: HOST_VERSION,
        sdk: LOADED_SDK,
        sdkOnDisk: sdkVersion(),
        build: LOADED_BUILD,
        // Whether anything would be lost if this host went now, read off the
        // in-memory sessions rather than the wire — so the app deciding to
        // replace a stale host doesn't race the `session.tasks` levels sent
        // right after this welcome. A session mid-turn, holding a question, or
        // with a background agent or shell still out all count.
        busy: busy(),
        capabilities: [
          ...CAPABILITIES,
        ],
        configDir: configDirectory,
        hostname: hostname(),
        modes: [...PERMISSION_MODES],
        efforts: [...EFFORT_LEVELS],
        outputStyles,
        pid: process.pid,
        sessions: [...sessions.values()].map((session) => session.summary()),
        pending: pendingAsks(),
      });
      reply(true);

      // What is already out, for the same reason the welcome carries the asks
      // already on screen: the host outlives the app, and this set is only sent
      // when it changes. An agent that started before you connected and
      // finishes after only ever produces the edge that *removes* it, so
      // without this its row would offer no way to end it for its whole run.
      for (const session of sessions.values()) {
        const tasks = session.runningTasks();
        if (tasks.length > 0) {
          send(socket, { type: "session.tasks", key: session.key, tasks });
        }
      }
      return;
    }

    case "launched": {
      return reply(
        settleLaunch(request.launchId, request.key, `Not started: ${request.error ?? "Dex gave no reason"}`),
      );
    }

    case "start": {
      // Two sessions under one key is one of them unreachable: `send`, `answer`
      // and `stop` all find a session by it.
      if (request.key && sessions.has(request.key)) {
        return reply(false, { error: `key ${request.key} is already running` });
      }
      const session = new HostedSession(
        {
          cwd: request.cwd,
          prompt: request.prompt,
          model: request.model,
          permissionMode: request.permissionMode,
          name: request.name,
          origin: request.origin,
          settingSources: request.settingSources,
          outputStyle: request.outputStyle,
          effort: request.effort,
          resume: request.resume,
          key: request.key,
          apiKey: request.apiKey,
        },
        (event) => {
          if (event.type === "session.exit") {
            const current = sessions.get(event.key);
            // A retired session's exit can land after a newer one took its key.
            if (current && current !== session) return;
            forget(event.key);
          }
          // Kept so a client connecting later gets the list on its welcome,
          // rather than only the clients that happened to be watching when a
          // session started.
          if (event.type === "host.styles") outputStyles = event.styles;
          broadcast(event);
        },
        launch,
      );
      sessions.set(session.key, session);
      idleSince = null;
      log(
        `start ${session.key} cwd=${request.cwd}${request.resume ? ` resume=${request.resume}` : ""}`,
      );
      // Answered once the session is away, rather than before it. `query()`
      // throws where it cannot find the CLI — which is what a host outliving
      // the bundle it was spawned from does — and an `ok` sent ahead of that
      // left the throw with nowhere to go but the socket's own catch, which
      // answers `id: "?"`: a reply nothing is waiting on, a key the app is now
      // watching for a row that will never come, and the reason for it in this
      // log alone. Safe because the drain emits nothing before its first await,
      // so the app still hears the key before any news of the session.
      try {
        session.start();
      } catch (error) {
        const failure = why(error);
        forget(session.key);
        log(`start failed for ${session.key}: ${failure}`);
        return reply(false, { error: failure });
      }
      reply(true, { key: session.key });
      return;
    }

    case "send": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      session.send(request.text);
      return reply(true);
    }

    case "answer": {
      const session = [...sessions.values()].find((candidate) =>
        candidate.parkedAsks().some((ask) => ask.askId === request.askId),
      );
      if (!session) return reply(false, { error: "no such ask" });
      return reply(session.answer(request));
    }

    case "mode": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      if (!isPermissionMode(request.permissionMode)) {
        return reply(false, { error: `unknown mode ${request.permissionMode}` });
      }
      // Answered once the SDK has taken the mode rather than once it has been
      // asked for it. The app shows the change as picked and puts it back on a
      // refusal, so a reply sent before the await can only ever say yes — and
      // nothing afterwards would correct the mode it left on screen.
      return replyWhenDone(reply, `mode failed for ${request.key}`, session.setMode(request.permissionMode));
    }

    case "effort": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      if (!isEffortLevel(request.effort)) {
        return reply(false, { error: `unknown effort ${request.effort}` });
      }
      // Answered on the SDK taking it rather than on being asked, as `mode` is.
      // The dial shows the pick at once and nothing puts one back, so a reply
      // sent before the await could only ever say yes.
      return replyWhenDone(reply, `effort failed for ${request.key}`, session.setEffort(request.effort));
    }

    // What the pickers' Default row is named after. Answered in-process — the
    // CLI's own merge engine, no session and no subprocess — which is what makes
    // it cheap enough to ask again every time the composer changes folder.
    //
    // A failure is answered rather than thrown: the resolver is marked alpha and
    // an SDK without it should cost the app a subtitle, not a picker.
    case "defaults": {
      resolveDefaults(request.cwd).then(
        (defaults) => {
          reply(true);
          send(socket, { type: "host.defaults", cwd: request.cwd, ...defaults });
        },
        (error: unknown) => {
          log(`defaults failed for ${request.cwd}: ${why(error)}`);
          reply(false, { error: why(error) });
        },
      );
      return;
    }

    case "interrupt": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      return replyWhenDone(reply, `interrupt failed for ${request.key}`, session.interrupt());
    }

    case "stopTask": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      // Answered on the SDK taking it rather than on being asked, as `mode` is:
      // the row goes when the transcript says the agent stopped, so a refusal
      // that was replied to as a yes would leave the agent running under a row
      // that had already given up saying so.
      return replyWhenDone(reply, `stopTask failed for ${request.key}`, session.stopTask(request.taskId));
    }

    case "mcpReconnect": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      return replyWhenDone(reply, `mcpReconnect failed for ${request.key}`, session.reconnectMcp(request.server));
    }

    case "mcpLogin": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      return replyWhenDone(reply, `mcpLogin failed for ${request.key}`, session.loginMcp(request.server), (login) => login);
    }

    case "rename": {
      const title = request.title.trim();
      if (!title) return reply(false, { error: "a name can't be empty" });
      const live = [...sessions.values()].find(
        (candidate) => candidate.sessionId === request.sessionId,
      );
      const renaming = live?.canRename
        ? live.rename(title)
        : renameSession(request.sessionId, title);
      return replyWhenDone(reply, `rename failed for ${request.sessionId}`, renaming);
    }

    case "side": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      const question = request.question.trim();
      if (!question) return reply(false, { error: "a question can't be empty" });
      return replyWhenDone(
        reply,
        `side question failed for ${request.key}`,
        session.askSideQuestion(question, request.history ?? []),
        (response) => ({ response }),
      );
    }

    case "stop": {
      const session = sessionFor(request.key);
      if (!session) return reply(false, { error: "no such session" });
      retire(session, "stop");
      return reply(true);
    }

    default: {
      return reply(false, { error: `unknown request` });
    }
  }
}

function admitted(socket: net.Socket): void {
  clients.add(socket);
  idleSince = null;
}

function accept(socket: net.Socket, admit?: (hello: Request | null) => boolean): void {
  if (!admit) admitted(socket);

  readLines(socket, {
    cap: () => {
      let lineCap = LINE_CAP;
      return lineCap;
    },
    admit: admit
      ? (line) => {
          const hello = parseRequest(line);
          if (!admit(hello.ok ? hello.request : null)) return false;
          admitted(socket);
          return true;
        }
      : undefined,
    line: (line) => {
      const parsed = parseRequest(line);
      if (!parsed.ok) {
        log(`bad request ${parsed.id}: ${parsed.error}`);
        send(socket, { type: "reply", id: parsed.id, ok: false, error: parsed.error });
        return;
      }
      try {
        handle(socket, parsed.request);
      } catch (error) {
        log(`${parsed.request.type} ${parsed.request.id} threw: ${why(error)}`);
        send(socket, { type: "reply", id: parsed.request.id, ok: false, error: why(error) });
      }
    },
    overflow: (cap) => log(`dropping a client whose line passed ${cap} bytes`),
  });

  const drop = () => {
    clients.delete(socket);
    const at = launchers.indexOf(socket);
    if (at !== -1) launchers.splice(at, 1);
    for (const [launchId, pending] of launches) {
      if (pending.socket === socket) settleLaunch(launchId, undefined, "Dex closed before saying whether it started; look in Dex before asking again");
    }
    // Sessions outlive their audience; that is the point of the host being detached.
    if (sessions.size === 0 && clients.size === 0) idleSince = Date.now();
  };
  socket.on("close", drop);
  socket.on("error", drop);
}

async function alreadyRunning(): Promise<boolean> {
  if (!existsSync(socketPath)) return false;
  return await new Promise<boolean>((resolve) => {
    const probe = net.connect(socketPath);
    probe.once("connect", () => {
      probe.destroy();
      resolve(true);
    });
    probe.once("error", () => {
      probe.destroy();
      resolve(false);
    });
  });
}

function inode(file: string): number | null {
  try {
    return lstatSync(file).ino;
  } catch {
    return null;
  }
}

function keepPrivate(directory: string): void {
  try {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    if ((statSync(directory).mode & 0o077) !== 0) chmodSync(directory, 0o700);
  } catch (error) {
    log(`couldn't make ${directory} private: ${why(error)}`);
  }
}

async function main(): Promise<void> {
  // Whoever can reach the socket can start a session in any folder and hand it a key.
  keepPrivate(stateDirectory);

  let ours: number | null = null;
  let poisoned = false;

  const shutdown = (reason: string) => {
    log(`shutting down: ${reason}`);
    for (const session of sessions.values()) session.stop();
    removeKeyFiles();
    try {
      if (ours !== null && inode(socketPath) === ours) unlinkSync(socketPath);
    } catch {
      // Nothing useful to do if the socket is already gone.
    }
    process.exit(0);
  };

  // One host holds every session the app is running, and Node's default for an
  // unhandled rejection is to exit — which would take all of them down over one
  // bad request, silently, with only the dropped socket to show for it.
  process.on("unhandledRejection", (reason) => {
    log(`unhandled rejection: ${why(reason)}`);
  });
  // A thrown exception leaves the process in a state nobody vouches for, so the
  // host goes and the app spawns a fresh one — but not while that would kill a
  // turn, an ask or a background agent outright: a host's exit takes its CLIs
  // with it, and what was in flight is never answered.
  process.on("uncaughtException", (error) => {
    log(`uncaught exception: ${error?.stack ?? error}`);
    if (poisoned) return;
    poisoned = true;
    if (mayExit(sessions.values())) return shutdown("uncaught exception");
    log("staying up until nothing has run for a while");
    setInterval(() => {
      if (mayExit(sessions.values())) shutdown("uncaught exception, now that nothing is running");
    }, 5_000).unref();
  });

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  const stale = inode(socketPath);
  if (await alreadyRunning()) {
    log("another host holds the socket; exiting");
    process.exit(0);
  }
  // Only the file found dead: a host starting beside this one may have bound a
  // live one there since, and the listen below then loses to it.
  if (stale !== null && inode(socketPath) === stale) unlinkSync(socketPath);

  const server = net.createServer(accept);
  server.on("error", (error: NodeJS.ErrnoException) => {
    if (server.listening) {
      log(`server error: ${why(error)}`);
      return;
    }
    if (error?.code === "EADDRINUSE") {
      log("another host bound the socket first; exiting");
      process.exit(0);
    }
    log(`couldn't listen on ${socketPath}: ${why(error)}`);
    process.exit(1);
  });
  server.listen(socketPath, () => {
    try {
      chmodSync(socketPath, 0o600);
    } catch (error) {
      log(`couldn't make ${socketPath} private: ${why(error)}`);
    }
    ours = inode(socketPath);
    log(`listening on ${socketPath} (host ${HOST_VERSION}, sdk ${sdkVersion()})`);
    sweepKeyFiles();
    if (process.env.DEX_HOST_ANNOUNCE) {
      process.stdout.write(`listening ${socketPath}\n`);
    }
    serve(shutdown);
  });
}

function serve(shutdown: (reason: string) => void): void {

  setInterval(() => {
    const now = Date.now();
    for (const session of [...sessions.values()]) {
      let after = REAP_AFTER_MS;
      if (session.reapable(now, after)) retire(session, "reaping idle");
    }
  }, REAP_CHECK_MS).unref();

  setInterval(() => {
    if (idleSince === null) return;
    if (sessions.size > 0 || clients.size > 0) {
      idleSince = null;
      return;
    }
    if (Date.now() - idleSince > IDLE_EXIT_MS) shutdown("idle");
  }, IDLE_CHECK_MS).unref();
}

void main();
