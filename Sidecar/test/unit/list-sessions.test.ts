import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { listSessions } from "../../src/fleet.ts";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-list-sessions-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

let folders = 0;

function world(fleet: unknown, records: Record<string, unknown>): { fleetFile: string; registry: string } {
  const root = path.join(scratch, String(folders++));
  const registry = path.join(root, "sessions");
  mkdirSync(registry, { recursive: true });
  const fleetFile = path.join(root, "fleet.json");
  if (fleet !== undefined) writeFileSync(fleetFile, typeof fleet === "string" ? fleet : JSON.stringify(fleet));
  for (const [name, record] of Object.entries(records)) {
    writeFileSync(path.join(registry, name), typeof record === "string" ? record : JSON.stringify(record));
  }
  return { fleetFile, registry };
}

// A pid this test can be sure is not running: past macOS's pid ceiling.
const DEAD = 9_999_999;

test("no fleet file, or one that doesn't parse, points at ListAgents", () => {
  const missing = world(undefined, {});
  assert.match(listSessions(missing.fleetFile, missing.registry, null), /hasn't published.*ListAgents/);
  const broken = world("{", {});
  assert.match(listSessions(broken.fleetFile, broken.registry, null), /hasn't published/);
});

test("a running session is listed by its registry name, with what it is doing", () => {
  const { fleetFile, registry } = world(
    {
      sessions: [
        {
          sessionId: "s1",
          name: "Fix the build",
          state: "running",
          doing: "running tests",
          cwd: "/work/app",
          branch: "fix-build",
          merge: { summary: "2 ahead" },
        },
      ],
    },
    { "101.json": { pid: process.pid, sessionId: "s1", name: "fix-build-agent", cwd: "/work/app" } },
  );
  assert.equal(
    listSessions(fleetFile, registry, null),
    "Message one with SendMessage, passing the name after the dash as `to`.\n\n" +
      "- fix-build-agent\n" +
      "  title: Fix the build\n" +
      "  running · /work/app (branch fix-build) · 2 ahead\n" +
      "  doing: running tests\n" +
      "  session id: s1",
  );
});

test("the asking session leaves itself out", () => {
  const { fleetFile, registry } = world(
    { sessions: [{ sessionId: "me", name: "me", doing: "x", cwd: "/a" }] },
    { "1.json": { pid: process.pid, sessionId: "me", name: "me", cwd: "/a" } },
  );
  assert.equal(listSessions(fleetFile, registry, "me"), "No other Dex session is running.");
});

test("a session whose CLI is gone, or never registered, can't be messaged", () => {
  const { fleetFile, registry } = world(
    {
      sessions: [
        { sessionId: "dead", name: "a", doing: "x", cwd: "/a" },
        { sessionId: "unregistered", name: "b", doing: "x", cwd: "/b" },
        { name: "no id yet", doing: "x", cwd: "/c" },
      ],
    },
    { "2.json": { pid: DEAD, sessionId: "dead", name: "a", cwd: "/a" } },
  );
  assert.equal(
    listSessions(fleetFile, registry, null),
    "No other Dex session is running.\n\n3 more sessions are not running and can't be messaged.",
  );
});

test("a session that moved folder is listed where its CLI says, without the old branch", () => {
  const { fleetFile, registry } = world(
    {
      sessions: [
        { sessionId: "s1", name: "same", waitingFor: "an answer", doing: "asking", cwd: "/old", branch: "main" },
        { sessionId: "s2", name: "other", doing: "idle", cwd: "/c" },
      ],
    },
    {
      "10.json": { pid: process.pid, sessionId: "s1", name: "same", cwd: "/new/worktree" },
      "11.json": { pid: DEAD, sessionId: "s2", name: "other" },
    },
  );
  assert.equal(
    listSessions(fleetFile, registry, null),
    "Message one with SendMessage, passing the name after the dash as `to`.\n\n" +
      "- same\n" +
      "  waiting on an answer · /new/worktree\n" +
      "  doing: asking\n" +
      "  session id: s1\n\n" +
      "1 more session is not running and can't be messaged.",
  );
});

test("registry files that aren't a CLI's record are skipped", () => {
  const { fleetFile, registry } = world(
    { sessions: [{ sessionId: "s1", name: "n", doing: "x", cwd: "/a" }] },
    {
      "notes.json": { pid: process.pid, sessionId: "s1", name: "from notes" },
      "3.json": "not json",
      "4.json": { pid: process.pid, sessionId: "s1", name: "" },
      "5.json": { pid: process.pid, sessionId: "s1", name: "real", cwd: "" },
    },
  );
  const listing = listSessions(fleetFile, registry, null);
  assert.match(listing, /^- real$/m);
  assert.match(listing, /unknown · \/a/);
  assert.doesNotMatch(listing, /from notes/);
});
