import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { createInterface } from "node:readline";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

const sidecar = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
// Under /tmp: a socket path has to fit in 104 bytes. Never the real state directory or socket.
const scratch = mkdtempSync(path.join("/tmp", "dex-host-test-"));
const socketPath = path.join(scratch, "host.sock");

const env: NodeJS.ProcessEnv = {
  ...process.env,
  CLAUDE_CONFIG_DIR: path.join(scratch, "claude"),
  DEX_HOST_STATE_DIR: path.join(scratch, "state"),
  DEX_HOST_SOCKET: socketPath,
  DEX_HOST_IDLE_MS: "60000",
  DEX_HOST_ANNOUNCE: "1",
};
delete env.DEX_HOST_PROFILE;

const host = spawn(process.execPath, ["src/host.ts"], { cwd: sidecar, env, stdio: ["ignore", "pipe", "inherit"] });
let client: net.Socket;
let replies: AsyncIterator<string>;

async function next(): Promise<Record<string, unknown>> {
  const { value, done } = await replies.next();
  assert.equal(done, false, "the host closed the socket");
  return JSON.parse(value);
}

async function ask(line: string): Promise<Record<string, unknown>> {
  client.write(`${line}\n`);
  return next();
}

before(async () => {
  const announced = createInterface({ input: host.stdout! })[Symbol.asyncIterator]();
  const { value } = await announced.next();
  assert.equal(value, `listening ${socketPath}`);
  client = net.connect(socketPath);
  await once(client, "connect");
  replies = createInterface({ input: client })[Symbol.asyncIterator]();
  client.write('{"id":"h","type":"hello","protocol":1}\n');
  assert.equal((await next()).type, "welcome");
  assert.deepEqual(await next(), { type: "reply", id: "h", ok: true });
});

after(async () => {
  client?.destroy();
  if (host.exitCode === null) {
    host.kill("SIGTERM");
    await once(host, "exit");
  }
  rmSync(scratch, { recursive: true, force: true });
});

test("a malformed request is refused under its own id, and the host carries on", async () => {
  const refused = await ask('{"id":"r1","type":"rename","sessionId":"s"}');
  assert.equal(refused.type, "reply");
  assert.equal(refused.id, "r1");
  assert.equal(refused.ok, false);
  assert.match(String(refused.error), /^bad rename request: title: /);

  const empty = await ask('{"id":"r2","type":"rename","sessionId":"s","title":"  "}');
  assert.deepEqual(empty, { type: "reply", id: "r2", ok: false, error: "a name can't be empty" });
});

test("a line that isn't JSON is answered under ?", async () => {
  const refused = await ask("{nope");
  assert.equal(refused.id, "?");
  assert.equal(refused.ok, false);
  assert.match(String(refused.error), /^unparseable: /);
});

test("an unknown request is answered as one", async () => {
  assert.deepEqual(await ask('{"id":"u1","type":"teleport"}'), {
    type: "reply",
    id: "u1",
    ok: false,
    error: "unknown request",
  });
});

test("a well-formed request still reaches its handler", async () => {
  assert.deepEqual(await ask('{"id":"s1","type":"send","key":"nobody","text":"hi"}'), {
    type: "reply",
    id: "s1",
    ok: false,
    error: "no such session",
  });
  assert.deepEqual(await ask('{"id":"e1","type":"effort","key":"nobody","effort":"max"}'), {
    type: "reply",
    id: "e1",
    ok: false,
    error: "no such session",
  });
});
