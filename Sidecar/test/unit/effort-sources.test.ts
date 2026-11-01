import assert from "node:assert/strict";
import { test } from "node:test";

import type { ResolvedSettings } from "@anthropic-ai/claude-agent-sdk";

import { effortSources } from "../../src/defaults.ts";

type Sources = ResolvedSettings["sources"];

test("nothing to read is no sources", () => {
  assert.deepEqual(effortSources(undefined), []);
  assert.deepEqual(effortSources([]), []);
  assert.deepEqual(effortSources("not a list" as unknown as Sources), []);
});

test("highest precedence first, and a file naming no effort is left out", () => {
  const sources: Sources = [
    { source: "user", settings: { effortLevel: "high" } },
    { source: "project", settings: { model: "opus" } },
    { source: "local", settings: { effortLevel: "low" } },
  ];
  assert.deepEqual(effortSources(sources), [
    { source: "local", effort: "low", models: {} },
    { source: "user", effort: "high", models: {} },
  ]);
});

test("per-model levels are kept beside a file's own", () => {
  const sources: Sources = [
    {
      source: "user",
      settings: { modelSettings: { "claude-opus-5": { effortLevel: "xhigh" }, "claude-haiku-5-5": {} } },
    },
  ];
  assert.deepEqual(effortSources(sources), [{ source: "user", effort: null, models: { "claude-opus-5": "xhigh" } }]);
});

test("a level that isn't a string is not a level", () => {
  const sources = [
    { source: "user", settings: { effortLevel: 3, modelSettings: { opus: { effortLevel: null } } } },
    { source: "flag", settings: null },
    null,
  ] as unknown as Sources;
  assert.deepEqual(effortSources(sources), []);
});
