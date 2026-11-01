/**
 * A session's `start_session` goes through the host to one local app and back.
 *
 * A real host on a socket of its own, and two clients standing in for apps:
 * one that offers to take launches and one that doesn't.
 * Readings:
 *
 *   - With no app taking launches, the tool says Dex isn't open.
 *   - With one, the launch reaches it alone, naming the asking session as
 *     parent, and the key it answers is what the tool result says.
 *   - A folder that isn't there is refused before any app hears of it.
 *
 *   node test/launch-relay-probe.ts
 */

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import net from "node:net";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { startCredential } from "./credential.ts";

const credential = startCredential("launch-relay-probe");
const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "launch-relay-probe-")));
const socketPath = path.join(dir, "host.sock");
const CHILD_KEY = "relay-child-key-4711";

const host = spawn(process.execPath, [new URL("../src/host.ts", import.meta.url).pathname], {
  env: {
    ...process.env,
    DEX_HOST_SOCKET: socketPath,
    DEX_HOST_ANNOUNCE: "1",
  },
  stdio: ["ignore", "pipe", "inherit"],
});
await new Promise<void>((resolve) => host.stdout!.on("data", () => resolve()));

class Client {
  readonly events: any[] = [];
  #socket: net.Socket;
  #next = 0;
  #listeners: ((event: any) => void)[] = [];

  constructor(launches: boolean) {
    this.#socket = net.connect(socketPath);
    let buffer = "";
    this.#socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline: number;
      while ((newline = buffer.indexOf("\n")) !== -1) {
        const event = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        this.events.push(event);
        for (const listener of this.#listeners) listener(event);
      }
    });
    this.send({ type: "hello", protocol: 1, ...(launches ? { launches: true } : {}) });
  }

  send(request: Record<string, unknown>): string {
    const id = `r${++this.#next}`;
    this.#socket.write(`${JSON.stringify({ id, ...request })}\n`);
    return id;
  }

  on(listener: (event: any) => void): void {
    this.#listeners.push(listener);
  }

  close(): void {
    this.#socket.destroy();
  }
}

function waitFor(client: Client, match: (event: any) => boolean, ms: number): Promise<any> {
  const found = client.events.find(match);
  if (found) return Promise.resolve(found);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`nothing within ${ms / 1000}s`)), ms);
    client.on((event) => {
      if (match(event)) {
        clearTimeout(timer);
        resolve(event);
      }
    });
  });
}

const call = (cwd: string, name: string) =>
  `Use the start_session tool from the dex MCP server (search for it if it is deferred) ` +
  `with cwd ${JSON.stringify(cwd)}, prompt "say hi", and name ${JSON.stringify(name)}. ` +
  `Then reply with only the exact text the tool returned.`;

let sessionId = "";
const transcript = () =>
  path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);

function lastToolResult(): string {
  if (!sessionId || !existsSync(transcript())) return "";
  const texts = readFileSync(transcript(), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line))
    .filter((record) => record.type === "user" && Array.isArray(record.message?.content))
    .flatMap((record) => record.message.content)
    .filter((block: any) => block?.type === "tool_result")
    .map((block: any) => (typeof block.content === "string" ? block.content : JSON.stringify(block.content)));
  return texts.at(-1) ?? "";
}

const results = (client: Client, key: string) =>
  client.events.filter((event) => event.type === "session.result" && event.key === key);

async function moreResults(than: number, what: string, ms = 180_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (results(bystander, parentKey).length === than) {
    if (Date.now() > deadline) throw new Error(`gave up after ${ms / 1000}s waiting for ${what}`);
    await sleep(500);
  }
}

const bystander = new Client(false);
let parentKey = "";
try {
  const startId = bystander.send({ type: "start", ...credential, cwd: dir, prompt: call(dir, "Nobody home"), model: "haiku", settingSources: [] });
  parentKey = (await waitFor(bystander, (event) => event.type === "reply" && event.id === startId, 30_000)).key;
  sessionId = (await waitFor(bystander, (event) => event.type === "session.init" && event.key === parentKey, 60_000)).sessionId;
  await waitFor(bystander, (event) => event.type === "session.result" && event.key === parentKey, 180_000);
  await sleep(1_000);
  check(/isn't open/.test(lastToolResult()), `with no app taking launches the tool says so (${JSON.stringify(lastToolResult())})`);

  const app = new Client(true);
  await waitFor(app, (event) => event.type === "welcome", 10_000);
  app.on((event) => {
    if (event.type === "launch") app.send({ type: "launched", launchId: event.launchId, key: CHILD_KEY });
  });
  const before = results(bystander, parentKey).length;
  bystander.send({ type: "send", key: parentKey, text: call(dir, "Child") });
  const launch = await waitFor(app, (event) => event.type === "launch", 180_000);
  check(launch.cwd === dir && launch.prompt === "say hi" && launch.name === "Child", "the launch carries the call's cwd, prompt and name");
  check(launch.parent === parentKey, "and the asking session as parent");
  check(!bystander.events.some((event) => event.type === "launch"), "a client that didn't offer never hears it");
  await moreResults(before, "the turn that launched Child to finish");
  await sleep(1_000);
  check(lastToolResult().includes(CHILD_KEY), `the tool result carries the app's key (${JSON.stringify(lastToolResult())})`);

  const launches = app.events.filter((event) => event.type === "launch").length;
  const beforeMissing = results(bystander, parentKey).length;
  bystander.send({ type: "send", key: parentKey, text: call(path.join(dir, "not-here"), "Missing") });
  await moreResults(beforeMissing, "the turn that asked for a missing folder to finish");
  await sleep(1_000);
  check(app.events.filter((event) => event.type === "launch").length === launches, "a missing folder never reaches the app");
  check(/not a folder/.test(lastToolResult()), `and the tool says why (${JSON.stringify(lastToolResult())})`);
  app.close();
} catch (error: any) {
  check(false, `probe ran: ${error?.message ?? error}`);
} finally {
  if (parentKey) bystander.send({ type: "stop", key: parentKey });
  await sleep(1_000);
  bystander.close();
  host.kill("SIGTERM");
  rmSync(dir, { recursive: true, force: true });
  if (sessionId) rmSync(path.dirname(transcript()), { recursive: true, force: true });
}

if (failures.length > 0) {
  console.log(`\n${failures.length} failed`);
  process.exit(1);
}
console.log("\nall ok");
process.exit(0);
