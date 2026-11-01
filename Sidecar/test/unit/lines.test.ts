import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { test } from "node:test";

import { ADMISSION_CAP, readLines, type LineOptions } from "../../src/lines.ts";

class FakeSocket extends EventEmitter {
  destroyed = false;
  destroy(): void {
    this.destroyed = true;
  }
  say(...chunks: (string | Buffer)[]): void {
    for (const chunk of chunks) this.emit("data", Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
}

function reader(options: Partial<LineOptions> = {}) {
  const socket = new FakeSocket();
  const lines: string[] = [];
  const overflows: number[] = [];
  readLines(socket, {
    cap: () => 1024,
    line: (line) => lines.push(line),
    overflow: (cap) => overflows.push(cap),
    ...options,
  });
  return { socket, lines, overflows };
}

test("lines come out whole however the bytes were split", () => {
  const { socket, lines } = reader();
  socket.say('{"a":', '1}\n{"b"', ":2}\n{", '"c":3}\n');
  assert.deepEqual(lines, ['{"a":1}', '{"b":2}', '{"c":3}']);
});

test("several lines in one chunk, and an unfinished one held for the next", () => {
  const { socket, lines } = reader();
  socket.say("one\ntwo\nthr");
  assert.deepEqual(lines, ["one", "two"]);
  socket.say("ee\n");
  assert.deepEqual(lines, ["one", "two", "three"]);
});

test("lines are trimmed and blank ones skipped", () => {
  const { socket, lines } = reader();
  socket.say("  padded  \r\n\n   \n\r\nlast\n");
  assert.deepEqual(lines, ["padded", "last"]);
});

test("a character split across chunks is put back together", () => {
  const { socket, lines } = reader();
  const bytes = Buffer.from("café ☕\n");
  socket.say(bytes.subarray(0, 4), bytes.subarray(4, 6), bytes.subarray(6));
  assert.deepEqual(lines, ["café ☕"]);
});

test("an unfinished line past the cap drops the client", () => {
  const { socket, lines, overflows } = reader({ cap: () => 10 });
  socket.say("0123456789");
  assert.equal(socket.destroyed, false, "a line at the cap is held");
  socket.say("a");
  assert.equal(socket.destroyed, true);
  assert.deepEqual(overflows, [10]);
  assert.deepEqual(lines, []);
});

test("the cap is on what is held, not on what came in one chunk", () => {
  const { socket, lines } = reader({ cap: () => 10 });
  socket.say("a long line that is over the cap\nshort");
  assert.equal(socket.destroyed, false);
  assert.deepEqual(lines, ["a long line that is over the cap"]);
});

test("the cap is asked again after each chunk", () => {
  let cap = 100;
  const { socket } = reader({ cap: () => cap });
  socket.say("x".repeat(50));
  assert.equal(socket.destroyed, false);
  cap = 60;
  socket.say("x".repeat(20));
  assert.equal(socket.destroyed, true);
});

test("without admit every line is taken", () => {
  const { socket, lines } = reader();
  socket.say("first\n");
  assert.deepEqual(lines, ["first"]);
});

test("an admitted first line is read like any other", () => {
  const asked: string[] = [];
  const { socket, lines } = reader({ admit: (line) => (asked.push(line), true) });
  socket.say("hello\nnext\n");
  assert.deepEqual(asked, ["hello"]);
  assert.deepEqual(lines, ["hello", "next"]);
});

test("a refused first line drops the client and nothing after it is read", () => {
  const { socket, lines } = reader({ admit: () => false });
  socket.say("\nintruder\nrequest\n");
  assert.equal(socket.destroyed, true);
  assert.deepEqual(lines, []);
});

test("before admission a client may hold no more than the admission cap", () => {
  let asked = false;
  const { socket, lines } = reader({
    cap: () => 10 * ADMISSION_CAP,
    admit: () => (asked = true),
  });
  socket.say("x".repeat(ADMISSION_CAP));
  assert.equal(socket.destroyed, false);
  socket.say("x");
  assert.equal(socket.destroyed, true);
  assert.equal(asked, false);
  assert.deepEqual(lines, []);
});

test("past admission the admission cap no longer applies", () => {
  const { socket, lines } = reader({ cap: () => 10 * ADMISSION_CAP, admit: () => true });
  socket.say("hello\n", "x".repeat(2 * ADMISSION_CAP));
  assert.equal(socket.destroyed, false);
  socket.say("\n");
  assert.equal(lines.length, 2);
});

test("over a real socket", async () => {
  // Under /tmp: a socket path has to fit in 104 bytes.
  const folder = mkdtempSync(path.join("/tmp", "dex-lines-"));
  const lines: string[] = [];
  let resolve!: () => void;
  const done = new Promise<void>((settle) => (resolve = settle));
  const server = net.createServer((socket) => {
    readLines(socket, {
      cap: () => 1024,
      line: (line) => {
        lines.push(line);
        if (lines.length === 3) resolve();
      },
    });
  });
  try {
    server.listen(path.join(folder, "s.sock"));
    await once(server, "listening");
    const client = net.connect(path.join(folder, "s.sock"));
    await once(client, "connect");
    client.write('{"id":"1"');
    client.write('}\n{"id":"2"}\n');
    client.end('{"id":"3"}\n');
    await done;
    assert.deepEqual(lines, ['{"id":"1"}', '{"id":"2"}', '{"id":"3"}']);
  } finally {
    server.close();
    rmSync(folder, { recursive: true, force: true });
  }
});
