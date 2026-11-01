import assert from "node:assert/strict";
import { test } from "node:test";

import { parseRequest } from "../../src/requests.ts";

const parse = (value: unknown) => parseRequest(JSON.stringify(value));

test("each public request in its smallest valid shape is taken", () => {
  for (const request of [
    { id: "1", type: "hello", protocol: 1 },
    { id: "1", type: "hello", protocol: 1, launches: true },
    { id: "1", type: "launched", launchId: "l" },
    { id: "1", type: "launched", launchId: "l", key: "k", error: "why" },
    { id: "1", type: "start", cwd: "/a", prompt: "hi" },
    {
      id: "1",
      type: "start",
      cwd: "/a",
      prompt: "hi",
      model: "opus",
      permissionMode: "auto",
      name: "n",
      origin: { watcher: "w", reason: "r", parent: "p" },
      settingSources: [],
      outputStyle: "Explanatory",
      effort: "xhigh",
      resume: "s",
      key: "k",
      apiKey: "sk",
    },
    { id: "1", type: "send", key: "k", text: "hello" },
    { id: "1", type: "answer", askId: "a", kind: "question", answers: { q: "A", r: ["B", "C"] } },
    { id: "1", type: "answer", askId: "a", kind: "question", answers: {}, annotations: { q: {} }, response: "no" },
    { id: "1", type: "answer", askId: "a", kind: "permission", optionId: "allow_once" },
    { id: "1", type: "mode", key: "k", permissionMode: "auto" },
    { id: "1", type: "effort", key: "k", effort: "max" },
    { id: "1", type: "defaults", cwd: "/a" },
    { id: "1", type: "interrupt", key: "k" },
    { id: "1", type: "stop", key: "k" },
    { id: "1", type: "stopTask", key: "k", taskId: "t" },
    { id: "1", type: "mcpReconnect", key: "k", server: "s" },
    { id: "1", type: "mcpLogin", key: "k", server: "s" },
    { id: "1", type: "rename", sessionId: "s", title: "t" },
    { id: "1", type: "side", key: "k", question: "q" },
    { id: "1", type: "side", key: "k", question: "q", history: [{ question: "a", response: "b" }] },
  ]) {
    const parsed = parse(request);
    assert.equal(parsed.ok, true, `${JSON.stringify(request)}: ${parsed.ok ? "" : parsed.error}`);
    assert.deepEqual(parsed.ok && parsed.request, request);
  }
});

test("a rename without a title is refused under its own id, naming the field", () => {
  const parsed = parse({ id: "r7", type: "rename", sessionId: "s" });
  assert.equal(parsed.ok, false);
  assert.equal(!parsed.ok && parsed.id, "r7");
  assert.match(!parsed.ok ? parsed.error : "", /^bad rename request: title: /);
});

test("every problem is named, in one line", () => {
  const parsed = parse({ id: "s1", type: "send", key: 3 });
  assert.equal(parsed.ok, false);
  const error = !parsed.ok ? parsed.error : "";
  assert.match(error, /key: /);
  assert.match(error, /text: /);
  assert.doesNotMatch(error, /\n/);
});

test("wrong types inside a request are refused", () => {
  for (const request of [
    { id: "1", type: "hello", protocol: "1" },
    { id: "1", type: "start", cwd: "/a", prompt: "hi", settingSources: ["everywhere"] },
    { id: "1", type: "start", cwd: "/a", prompt: "hi", origin: { parent: 4 } },
    { id: "1", type: "answer", askId: "a", kind: "question", answers: { q: 1 } },
    { id: "1", type: "answer", askId: "a", kind: "permission" },
    { id: "1", type: "answer", askId: "a", kind: "maybe", optionId: "x" },
    { id: "1", type: "side", key: "k", question: "q", history: [{ question: "a" }] },
    { id: "1", type: "start", cwd: "/a", prompt: "hi", model: null },
  ]) {
    const parsed = parse(request);
    assert.equal(parsed.ok, false, JSON.stringify(request));
    assert.equal(!parsed.ok && parsed.id, "1");
  }
});

test("a request with no id is answered under ?", () => {
  const parsed = parse({ type: "stop", key: "k" });
  assert.deepEqual(parsed.ok ? null : parsed.id, "?");
  assert.equal(parse({ id: 5, type: "stop", key: "k" }).ok, false);
});

test("a line that isn't JSON is unparseable", () => {
  const parsed = parseRequest("{not json");
  assert.equal(parsed.ok, false);
  assert.equal(!parsed.ok && parsed.id, "?");
  assert.match(!parsed.ok ? parsed.error : "", /^unparseable: /);
});

test("a type the host doesn't know is an unknown request, in the words the app reads", () => {
  assert.deepEqual(parse({ id: "u1", type: "teleport" }), { ok: false, id: "u1", error: "unknown request" });
  assert.deepEqual(parse({ id: "u2" }), { ok: false, id: "u2", error: "unknown request" });
  assert.deepEqual(parse({ id: "u3", type: "toString" }), { ok: false, id: "u3", error: "unknown request" });
  assert.deepEqual(parse(null), { ok: false, id: "?", error: "unknown request" });
  assert.deepEqual(parse([1, 2]), { ok: false, id: "?", error: "unknown request" });
  assert.deepEqual(parse("hello"), { ok: false, id: "?", error: "unknown request" });
});

test("fields a newer app sends are let through and dropped", () => {
  const parsed = parse({ id: "1", type: "send", key: "k", text: "hi", sentAt: 12 });
  assert.deepEqual(parsed.ok && parsed.request, { id: "1", type: "send", key: "k", text: "hi" });
});
