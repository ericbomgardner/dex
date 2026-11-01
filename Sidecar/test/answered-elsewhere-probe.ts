/**
 * Whether a question answered from one app comes down off every other app on
 * the same host.
 *
 *   node test/answered-elsewhere-probe.ts
 *
 * A host can be shared: every app connected to it holds a socket of its own,
 * and the ask goes to each. The answering app takes its card down on its own
 * word; every other app only knows from the host. Until the host said
 * `ask.withdrawn` on an answer too, a question answered in one app stayed up
 * in the other for as long as it stayed connected.
 *
 * Two clients, one question, answered from the first with a typed `response`
 * (the shape that turned it up). The second must hear `ask.withdrawn` for it.
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
const scratch = mkdtempSync(path.join(tmpdir(), "answered-elsewhere-probe-"));
const socketPath = path.join(scratch, "host.sock");

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const credential = startCredential("answered-elsewhere-probe");

const host = spawn(process.execPath, [hostEntry], {
  env: { ...process.env, DEX_HOST_SOCKET: socketPath },
  stdio: ["ignore", "pipe", "pipe"],
});
host.stderr.on("data", (chunk) => process.stderr.write(`[host] ${chunk}`));

for (let attempt = 0; attempt < 100 && !existsSync(socketPath); attempt++) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

class Client {
  readonly seen: any[] = [];
  #socket: net.Socket;
  #waiters: { match: (event: any) => boolean; resolve: (event: any) => void }[] = [];
  #buffer = "";
  #counter = 0;

  readonly name: string;

  constructor(name: string, socket: net.Socket) {
    this.name = name;
    this.#socket = socket;
    socket.on("data", (chunk) => {
      this.#buffer += chunk.toString("utf8");
      let newline = this.#buffer.indexOf("\n");
      while (newline !== -1) {
        const line = this.#buffer.slice(0, newline).trim();
        this.#buffer = this.#buffer.slice(newline + 1);
        if (line) {
          const event = JSON.parse(line);
          this.seen.push(event);
          for (const waiter of [...this.#waiters]) {
            if (waiter.match(event)) {
              this.#waiters.splice(this.#waiters.indexOf(waiter), 1);
              waiter.resolve(event);
            }
          }
        }
        newline = this.#buffer.indexOf("\n");
      }
    });
  }

  static async connect(name: string): Promise<Client> {
    const socket = net.connect(socketPath);
    await new Promise((resolve) => socket.once("connect", resolve));
    return new Client(name, socket);
  }

  expect(match: (event: any) => boolean, what: string, ms = 180_000): Promise<any> {
    const already = this.seen.find(match);
    if (already) return Promise.resolve(already);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`${this.name} timed out waiting for ${what}`)),
        ms,
      );
      this.#waiters.push({
        match,
        resolve: (event) => {
          clearTimeout(timer);
          resolve(event);
        },
      });
    });
  }

  request(body: Record<string, unknown>): string {
    const id = `${this.name}${++this.#counter}`;
    this.#socket.write(`${JSON.stringify({ id, ...body })}\n`);
    return id;
  }

  close(): void {
    this.#socket.destroy();
  }
}

const answering = await Client.connect("a");
const watching = await Client.connect("b");

try {
  for (const client of [answering, watching]) {
    client.request({ type: "hello", protocol: 1 });
    await client.expect((e) => e.type === "welcome", `${client.name} welcome`);
  }

  const startId = answering.request({
    type: "start",
    ...credential,
    cwd: scratch,
    prompt:
      "Use the AskUserQuestion tool right now to ask me one question: red or blue. " +
      "Ask it before doing anything else. After I answer, reply with one word.",
    model: "haiku",
    permissionMode: "auto",
    settingSources: [],
  });
  const started = await answering.expect(
    (e) => e.type === "reply" && e.id === startId,
    "start reply",
  );
  const key = started.key;

  const ask = await watching.expect(
    (e) => e.type === "ask" && e.key === key && e.toolName === "AskUserQuestion",
    "the question, on the watching client",
  );
  await answering.expect(
    (e) => e.type === "ask" && e.askId === ask.askId,
    "the same question, on the answering client",
  );

  const answerId = answering.request({
    type: "answer",
    askId: ask.askId,
    kind: "question",
    answers: {},
    response: "neither, let's talk first",
  });
  const answered = await answering.expect(
    (e) => e.type === "reply" && e.id === answerId,
    "answer reply",
  );
  check(answered.ok === true, "the host takes the answer");

  const withdrawn = await watching
    .expect(
      (e) => e.type === "ask.withdrawn" && e.askId === ask.askId,
      "ask.withdrawn on the watching client",
      30_000,
    )
    .catch(() => null);
  check(withdrawn !== null, "the client that didn't answer hears the ask is gone");

  await answering.expect((e) => e.type === "session.result" && e.key === key, "the turn ending");
  answering.request({ type: "stop", key });
} finally {
  answering.close();
  watching.close();
  host.kill();
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\n${failures.length} failed` : "\nall ok");
process.exit(failures.length ? 1 : 0);
