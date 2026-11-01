import assert from "node:assert/strict";
import { test } from "node:test";

import { drivesScreen, screenDrive } from "../../src/screen.ts";

const bash = (command: string) => screenDrive("Bash", { command });

test("only Bash and Monitor are read", () => {
  assert.equal(screenDrive("Write", { command: "cliclick c:1,1" }), null);
  assert.equal(drivesScreen("Write", { command: "cliclick c:1,1" }), false);
  assert.equal(screenDrive("Monitor", { command: "cliclick c:1,1" })?.match, "cliclick");
  assert.equal(screenDrive("Monitor", { command: "tail -f /tmp/log" }), null);
});

test("a call with no command is not a drive", () => {
  assert.equal(screenDrive("Bash", {}), null);
  assert.equal(screenDrive("Bash", null), null);
});

test("the mark names its own line", () => {
  assert.deepEqual(bash("DEX_DRIVES_SCREEN=1 /tmp/drive click 100 200"), {
    line: "DEX_DRIVES_SCREEN=1 /tmp/drive click 100 200",
    match: "DEX_DRIVES_SCREEN=1",
  });
  assert.deepEqual(bash("cd /tmp\n  DEX_DRIVES_SCREEN=1 ./drive  \necho done"), {
    line: "DEX_DRIVES_SCREEN=1 ./drive",
    match: "DEX_DRIVES_SCREEN=1",
  });
});

test("the mark wins over a habit on an earlier line", () => {
  assert.deepEqual(bash("cliclick c:1,1\nDEX_DRIVES_SCREEN=1 ./drive"), {
    line: "DEX_DRIVES_SCREEN=1 ./drive",
    match: "DEX_DRIVES_SCREEN=1",
  });
});

test("the mark must be the whole word", () => {
  assert.equal(bash("echo XDEX_DRIVES_SCREEN=1"), null);
  assert.equal(bash("DEX_DRIVES_SCREEN=10 ./drive"), null);
});

test("the old habits are caught", () => {
  const caught: [string, string][] = [
    ["cliclick c:100,200", "cliclick"],
    ["xdotool mousemove 1 1", "xdotool"],
    [`osascript -e 'tell application "System Events" to keystroke "a"'`, `keystroke "`],
    [`osascript -e 'tell application "System Events" to keystroke return'`, "keystroke return"],
    [`osascript -e 'tell application "System Events" to key code 36'`, "key code 3"],
    [`osascript -e 'tell application "Finder" to activate'`, "to activate"],
    ["osascript -e 'activate application \"Safari\"'", "activate application"],
    ["swift post.swift # CGEvent.post(tap: .cghidEventTap)", "cghidEventTap"],
    ["./drive click 100 200", "click 100"],
    ["./drive drag -5 10", "drag -5"],
    ["./drive scroll 3", "scroll 3"],
  ];
  for (const [command, match] of caught) {
    assert.equal(bash(command)?.match, match, command);
  }
});

test("the look-alikes the net is tight against are let through", () => {
  for (const command of [
    "ls -la",
    "source venv/bin/activate",
    "mv drag-handle.svg icons/",
    "git merge goal-drag 2>&1",
    `git commit -m "Handle the keystroke handler's focus"`,
    "swift run poster # CGEvent.postToPid(pid)",
    "echo 'click here'",
    "./drive click 100>out.txt",
  ]) {
    assert.equal(bash(command), null, command);
  }
});
