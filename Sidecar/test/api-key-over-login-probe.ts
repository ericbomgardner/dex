/**
 * Whether an API key outranks the CLI's stored claude.ai login, and whether it
 * can reach the CLI without reaching what the CLI runs.
 *
 *   node test/api-key-over-login-probe.ts
 *
 * The public build runs sessions on an API key only, which it hands the host
 * with each start. That keeps it off subscriptions only if the CLI uses the key
 * on a machine that is also logged in through claude.ai, so this needs that
 * login to measure anything, and without one it doesn't run.
 *
 * The key is a dummy, so a run that used it fails to authenticate and costs
 * nothing. One that answered would have used the login. Every run has a
 * UserPromptSubmit hook and a stdio MCP server that write out their
 * environment, since both start whether or not the turn authenticates.
 * Readings:
 *   - with no key, init says `apiKeySource: "none"` and the login answers
 *     (the control, a few tokens of haiku)
 *   - ANTHROPIC_API_KEY outranks the login, but the hook and the MCP server
 *     inherit it, and so would Bash, which is why the host doesn't use it
 *   - `apiKeyHelper` at the flag layer reading a `KeyFile`, with
 *     `keylessEnvironment`, outranks the login too: init says `apiKeyHelper`,
 *     the turn fails `authentication_failed`, and neither child sees the key
 *   - a helper that fails fails the turn rather than falling back to the login
 *   - a `HostedSession` started with `apiKey` starts its CLI with that helper
 *     and no key in its argv or environment, and its key file is gone once
 *     it ends
 *   - a host SIGTERMed with a keyed session running leaves no key file, and
 *     the sweep removes a folder whose pid is gone or was reused
 *
 * Never logs out and never reads or writes the stored login: the precondition
 * is `claude auth status`, and every session runs in a scratch cwd.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, utimesSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { KeyFile, keylessEnvironment, sweepKeyFiles } from "../src/keyfile.ts";
import { HostedSession } from "../src/session.ts";
import type { Event } from "../src/protocol.ts";
import { SKIPPED } from "./credential.ts";

const DUMMY_KEY = `sk-ant-api03-dexprobe${"0".repeat(80)}-AAAAAA`;
const RUN_TIMEOUT_MS = 330_000;

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const packages = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../node_modules/@anthropic-ai");
const platform = readdirSync(packages).find((name) => name.startsWith("claude-agent-sdk-darwin-"));
const cli = platform ? path.join(packages, platform, "claude") : null;
if (!cli || !existsSync(cli)) {
  console.error(`FAIL: no bundled CLI under ${packages}`);
  process.exit(1);
}

const base = keylessEnvironment();

const status = spawnSync(cli, ["auth", "status", "--json"], { env: base, encoding: "utf8" });
let login: any = null;
try {
  login = JSON.parse(status.stdout);
} catch {}
if (login?.loggedIn !== true || login?.authMethod !== "claude.ai") {
  console.log("skipped: no claude.ai login is stored, and this measures a key's precedence over one");
  process.exit(SKIPPED);
}
console.log(`  ok  logged in through claude.ai (${login.subscriptionType ?? "no subscription named"})`);

const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "dex-api-key-probe-")));

interface Run {
  source: string | null;
  version: string | null;
  error: string | null;
  text: string;
  model: string | null;
  isError: boolean | null;
  cost: number | null;
  /** Null where the child never wrote its environment. */
  hookSawKey: boolean | null;
  mcpSawKey: boolean | null;
  /** The status of each request the CLI retried. */
  retries: number[];
}

let runs = 0;

async function run(env: Record<string, string>, settings: Record<string, unknown> = {}): Promise<Run> {
  const out: Run = {
    source: null, version: null, error: null, text: "", model: null, isError: null, cost: null,
    hookSawKey: null, mcpSawKey: null, retries: [],
  };
  runs += 1;
  const hookFile = path.join(scratch, `hook-${runs}.env`);
  const mcpFile = path.join(scratch, `mcp-${runs}.env`);
  // A turn that neither answers nor fails says nothing either way, so it fails the reading it was for.
  const abortController = new AbortController();
  const timer = setTimeout(() => abortController.abort(), RUN_TIMEOUT_MS);
  try {
    for await (const message of query({
      prompt: "Reply with exactly: OK",
      options: {
        abortController,
        cwd: scratch,
        model: "haiku",
        maxTurns: 1,
        allowedTools: [],
        settingSources: [],
        env,
        settings: {
          ...settings,
          hooks: { UserPromptSubmit: [{ hooks: [{ type: "command", command: `env > '${hookFile}'` }] }] },
        },
        mcpServers: { envdump: { type: "stdio", command: "/bin/sh", args: ["-c", `env > '${mcpFile}'`] } },
      } as any,
    })) {
      if (message.type === "system" && message.subtype === "init") {
        out.source = message.apiKeySource;
        out.version = message.claude_code_version;
      }
      if (message.type === "assistant") {
        out.error ??= message.error ?? null;
        out.model ??= message.message.model ?? null;
        for (const block of message.message.content ?? []) if (block.type === "text") out.text += block.text;
      }
      if (message.type === "system" && message.subtype === "api_retry") out.retries.push(message.error_status ?? 0);
      if (message.type === "result") {
        out.isError = message.is_error;
        out.cost = message.total_cost_usd;
      }
    }
  } catch {
    // The SDK throws on an error result, after the messages this reads.
  } finally {
    clearTimeout(timer);
  }
  if (abortController.signal.aborted) console.log(`note  run ${runs} gave no result in ${RUN_TIMEOUT_MS / 1000}s`);
  const saw = (file: string) => (existsSync(file) ? readFileSync(file, "utf8").includes(DUMMY_KEY) : null);
  out.hookSawKey = saw(hookFile);
  out.mcpSawKey = saw(mcpFile);
  return out;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

try {
  const control = await run(base);
  check(control.source === "none", `with no key, apiKeySource is "none" (got ${control.source})`);
  check(control.isError === false && /OK/.test(control.text), `with no key, the login answers (got ${JSON.stringify(control.text)})`);
  check(control.hookSawKey === false && control.mcpSawKey === false, "the hook and the MCP server both wrote their environment");

  const inEnv = await run({ ...base, ANTHROPIC_API_KEY: DUMMY_KEY });
  check(inEnv.source === "ANTHROPIC_API_KEY", `a key in the environment is what the CLI uses (got ${inEnv.source})`);
  check(inEnv.error === "authentication_failed", `and the dummy fails to authenticate (got ${inEnv.error}: ${inEnv.text})`);
  check(inEnv.hookSawKey === true && inEnv.mcpSawKey === true, `but the hook and the MCP server inherit it (hook ${inEnv.hookSawKey}, mcp ${inEnv.mcpSawKey})`);

  const keyFile = new KeyFile(DUMMY_KEY);
  try {
    check((statSync(keyFile.path).mode & 0o777) === 0o600, "the key file is the owner's alone");
    check((statSync(path.dirname(keyFile.path)).mode & 0o777) === 0o700, "and so is its folder");
    const helped = await run(base, { apiKeyHelper: keyFile.helper });
    check(helped.source === "apiKeyHelper", `apiKeyHelper is what the CLI uses (got ${helped.source})`);
    check(helped.error === "authentication_failed", `the dummy key fails to authenticate (got ${helped.error}: ${helped.text})`);
    check(helped.model === "<synthetic>" && helped.isError === true && helped.cost === 0, "nothing answered and nothing was spent");
    check(
      helped.retries.every((status) => status === 401),
      `every retry on the way was the key refused, not the login (${helped.retries.length}: ${helped.retries.join(", ")})`,
    );
    check(helped.hookSawKey === false, `a hook doesn't see the key (${helped.hookSawKey})`);
    check(helped.mcpSawKey === false, `a stdio MCP server doesn't see the key (${helped.mcpSawKey})`);
  } finally {
    keyFile.remove();
  }

  const failing = await run(base, { apiKeyHelper: keyFile.helper });
  check(failing.source === "apiKeyHelper", `a helper that fails is still the source (got ${failing.source})`);
  check(
    failing.isError === true && failing.cost === 0 && !/OK/.test(failing.text),
    `and the turn fails rather than falling back to the login (got ${failing.error}: ${failing.text})`,
  );

  const before = new Set(readdirSync(tmpdir()).filter((name) => name.startsWith("dex-key-")));
  let resolveExit: () => void = () => {};
  const exit = new Promise<void>((resolve) => (resolveExit = resolve));
  const session = new HostedSession(
    { cwd: scratch, prompt: "Reply with exactly: OK", model: "haiku", settingSources: [], apiKey: DUMMY_KEY },
    (event: Event) => {
      if (event.type === "session.exit") resolveExit();
    },
  );
  session.start();
  const during = readdirSync(tmpdir()).filter((name) => name.startsWith("dex-key-") && !before.has(name));
  check(during.length === 1, `a keyed HostedSession writes one key file (${during.length})`);
  const written = during.length === 1 ? path.join(tmpdir(), during[0], "key") : "";
  // Its CLI's own argv and environment, as `ps eww` shows them for a process of ours.
  let launched = "";
  for (let tries = 0; tries < 50 && !(written && launched.includes(written)); tries++) {
    await sleep(200);
    const children = spawnSync("pgrep", ["-P", String(process.pid)], { encoding: "utf8" }).stdout.split("\n");
    launched =
      children
        .filter(Boolean)
        .map((pid) => spawnSync("ps", ["eww", "-o", "command=", "-p", pid], { encoding: "utf8" }).stdout)
        .find((line) => written && line.includes(written)) ?? "";
  }
  check(
    written && launched.includes(`"apiKeyHelper":"/bin/cat '${written}'"`),
    "the session's CLI is started with apiKeyHelper reading that file",
  );
  check(launched && !launched.includes(DUMMY_KEY), "and neither its argv nor its environment holds the key");
  await session.interrupt().catch(() => {});
  session.stop();
  await Promise.race([exit, sleep(30_000)]);
  await sleep(500);
  check(
    during.every((name) => !existsSync(path.join(tmpdir(), name))),
    "the key file is gone once the session has ended",
  );

  // A host stopped by a signal, as the app's auto-replace and a logout stop it,
  // exits before any session's drain ends, so it has to take the files itself.
  const hostTemp = realpathSync(mkdtempSync(path.join(tmpdir(), "dex-api-key-host-")));
  // Under /tmp: a socket path has to fit in 104 bytes.
  const hostState = mkdtempSync("/tmp/dex-api-key-host-");
  const socketPath = path.join(hostState, "host.sock");
  const hostEnv: Record<string, string> = {
    ...base,
    TMPDIR: hostTemp,
    DEX_HOST_STATE_DIR: hostState,
    DEX_HOST_SOCKET: socketPath,
    DEX_HOST_IDLE_MS: "600000",
  };
  const host = spawn("node", ["src/host.ts"], { cwd: path.resolve(packages, "../.."), env: hostEnv, stdio: "ignore" });
  const hostExit = new Promise<void>((resolve) => host.once("exit", () => resolve()));
  const keyFolders = () => readdirSync(hostTemp).filter((name) => name.startsWith("dex-key-"));
  try {
    for (let tries = 0; tries < 100 && !existsSync(socketPath); tries++) await sleep(100);
    const client = net.connect(socketPath);
    await new Promise<void>((resolve, reject) => client.once("connect", resolve).once("error", reject));
    const start = { id: "probe-start", type: "start", cwd: scratch, prompt: "Reply with exactly: OK", model: "haiku", settingSources: [], apiKey: DUMMY_KEY };
    client.write(`${JSON.stringify({ id: "probe-hello", type: "hello", protocol: 1 })}\n${JSON.stringify(start)}\n`);
    for (let tries = 0; tries < 100 && keyFolders().length === 0; tries++) await sleep(100);
    check(keyFolders().length === 1, `a host given a keyed start writes its key file (${keyFolders().length})`);
    await sleep(1000);
    const sessionCLIs = spawnSync("pgrep", ["-P", String(host.pid)], { encoding: "utf8" }).stdout.split("\n").filter(Boolean);
    client.destroy();
    host.kill("SIGTERM");
    await Promise.race([hostExit, sleep(15_000)]);
    check(host.exitCode !== null || host.signalCode !== null, "the host exits on SIGTERM");
    check(keyFolders().length === 0, `and leaves no key file behind (${keyFolders().join(", ")})`);
    for (const pid of sessionCLIs) spawnSync("kill", [pid]);
  } finally {
    if (host.exitCode === null && host.signalCode === null) host.kill("SIGKILL");
    rmSync(hostTemp, { recursive: true, force: true });
    rmSync(hostState, { recursive: true, force: true });
  }

  // A pid that is gone, or alive again as something started after its folder, holds nothing.
  const sweepable = realpathSync(mkdtempSync(path.join(tmpdir(), "dex-api-key-sweep-")));
  try {
    const mine = path.join(sweepable, `dex-key-${process.pid}-mine`);
    const gone = path.join(sweepable, "dex-key-99999999-gone");
    const reused = path.join(sweepable, "dex-key-1-reused");
    for (const folder of [mine, gone, reused]) mkdirSync(folder);
    utimesSync(reused, new Date("2001-01-01"), new Date("2001-01-01"));
    sweepKeyFiles(sweepable);
    check(existsSync(mine), "the sweep keeps a live host's key folder");
    check(!existsSync(gone), "and removes one whose host is gone");
    check(!existsSync(reused), "and one whose pid now belongs to a process started after it");
  } finally {
    rmSync(sweepable, { recursive: true, force: true });
  }

  console.log(`\nCLI ${version(control, inEnv)}`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

function version(...runs: Run[]): string {
  return runs.map((run) => run.version).find(Boolean) ?? "unknown";
}

if (failures.length > 0) {
  console.error(`\n${failures.length} failed. If the key doesn't win, or reaches what the CLI runs, the public build's gate doesn't hold.`);
  process.exit(1);
}
console.log("ok  an API key through apiKeyHelper outranks the stored claude.ai login and stays out of the session's children");
