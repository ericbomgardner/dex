import assert from "node:assert/strict";
import { test } from "node:test";

import { holdsWork, mayExit, QUIET_BEFORE_EXIT_MS, stirred, type Holder } from "../../src/exit-policy.ts";

function holder(state: string, extra: Partial<Holder> = {}): Holder {
  return { state, turnOwed: false, runningTasks: () => [], ...extra };
}

test("a session mid-turn, asking or compacting holds work", () => {
  for (const state of ["starting", "running", "compacting", "asking"]) {
    assert.equal(holdsWork(holder(state)), true, state);
  }
});

test("a settled session holds none", () => {
  for (const state of ["idle", "done", "error"]) {
    assert.equal(holdsWork(holder(state)), false, state);
  }
});

test("an idle session still holds work while a turn is owed or a task is out", () => {
  assert.equal(holdsWork(holder("idle", { turnOwed: true })), true);
  assert.equal(holdsWork(holder("idle", { runningTasks: () => [{ taskId: "t" }] })), true);
});

test("the host may go only once nothing holds work and the quiet has passed", () => {
  const at = 1_000_000;
  stirred(at);
  assert.equal(mayExit([], at + QUIET_BEFORE_EXIT_MS - 1), false);
  assert.equal(mayExit([], at + QUIET_BEFORE_EXIT_MS), true);
  assert.equal(mayExit([holder("idle"), holder("done")], at + QUIET_BEFORE_EXIT_MS), true);
  assert.equal(mayExit([holder("idle"), holder("running")], at + QUIET_BEFORE_EXIT_MS * 100), false);
});

test("anything that happens starts the quiet again", () => {
  stirred(0);
  assert.equal(mayExit([], 10_000, 5_000), true);
  stirred(9_000);
  assert.equal(mayExit([], 10_000, 5_000), false);
  assert.equal(mayExit([], 14_000, 5_000), true);
});
