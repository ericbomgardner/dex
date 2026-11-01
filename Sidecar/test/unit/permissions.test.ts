import assert from "node:assert/strict";
import { test } from "node:test";

import type { PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";

import type { Answer } from "../../src/protocol.ts";
import { decisionFor, permissionOptions } from "../../src/permissions.ts";

const local: PermissionUpdate = {
  type: "addRules",
  rules: [{ toolName: "WebFetch", ruleContent: "domain:example.com" }],
  behavior: "allow",
  destination: "localSettings",
};
const project: PermissionUpdate = {
  type: "addRules",
  rules: [{ toolName: "Bash", ruleContent: "npm test" }],
  behavior: "allow",
  destination: "projectSettings",
};
const directory: PermissionUpdate = { type: "addDirectories", directories: ["/tmp"], destination: "session" };
const denyRule: PermissionUpdate = { ...project, behavior: "deny" };

const input = { command: "npm test" };
const parked = { input, suggestions: [local, project, directory, denyRule] };

function permission(optionId: string, message?: string): Answer {
  return { id: "1", type: "answer", askId: "a", kind: "permission", optionId, ...(message ? { message } : {}) };
}

const questions = [{ question: "Which?", header: "Pick", options: [{ label: "A" }, { label: "B" }] }];

test("a picked answer goes back with the questions, and notes only when there are some", () => {
  const answer: Answer = { id: "1", type: "answer", askId: "a", kind: "question", answers: { "Which?": "A" } };
  assert.deepEqual(decisionFor(answer, { input: { questions }, suggestions: [] }), {
    behavior: "allow",
    updatedInput: { questions, answers: { "Which?": "A" } },
  });
  const noted: Answer = { ...answer, annotations: { "Which?": { notes: "the first" } } };
  assert.deepEqual(decisionFor(noted, { input: { questions }, suggestions: [] }), {
    behavior: "allow",
    updatedInput: { questions, answers: { "Which?": "A" }, annotations: { "Which?": { notes: "the first" } } },
  });
});

test("a response replaces the answers rather than joining them", () => {
  const answer: Answer = {
    id: "1",
    type: "answer",
    askId: "a",
    kind: "question",
    answers: { "Which?": "A" },
    annotations: { "Which?": { notes: "dropped" } },
    response: "neither, do C",
  };
  assert.deepEqual(decisionFor(answer, { input: { questions }, suggestions: [] }), {
    behavior: "allow",
    updatedInput: { questions, answers: {}, response: "neither, do C" },
  });
});

test("a question whose input has no questions still answers with a list", () => {
  const answer: Answer = { id: "1", type: "answer", askId: "a", kind: "question", answers: {} };
  const decision = decisionFor(answer, { input: {}, suggestions: [] });
  assert.equal(decision.behavior, "allow");
  assert.deepEqual(decision.behavior === "allow" && decision.updatedInput?.questions, []);
});

test("allow_once allows the call as it was, remembering nothing", () => {
  assert.deepEqual(decisionFor(permission("allow_once"), parked), { behavior: "allow", updatedInput: input });
});

test("allow_always remembers only the suggestions bound for local settings", () => {
  assert.deepEqual(decisionFor(permission("allow_always"), parked), {
    behavior: "allow",
    updatedInput: input,
    updatedPermissions: [local],
  });
});

test("allow_session keeps each suggested allow rule for the session only", () => {
  assert.deepEqual(decisionFor(permission("allow_session"), parked), {
    behavior: "allow",
    updatedInput: input,
    updatedPermissions: [
      { ...local, destination: "session" },
      { ...project, destination: "session" },
    ],
  });
});

test("allow_always with nothing to remember is a plain allow", () => {
  assert.deepEqual(decisionFor(permission("allow_always"), { input, suggestions: [project] }), {
    behavior: "allow",
    updatedInput: input,
  });
});

test("anything not a known allow is a denial", () => {
  assert.deepEqual(decisionFor(permission("reject_once"), parked), { behavior: "deny", message: "Denied from Dex" });
  assert.deepEqual(decisionFor(permission("allow_forever"), parked), { behavior: "deny", message: "Denied from Dex" });
  assert.deepEqual(decisionFor(permission("reject_once", "use pnpm"), parked), { behavior: "deny", message: "use pnpm" });
});

test("redirect is a denial in the host's words unless the app sent its own", () => {
  const decision = decisionFor(permission("redirect"), parked);
  assert.equal(decision.behavior, "deny");
  assert.match(decision.behavior === "deny" ? decision.message : "", /^Refused by Dex: this would drive the user's pointer/);
  assert.deepEqual(decisionFor(permission("redirect", "not now"), parked), { behavior: "deny", message: "not now" });
});

test("a grantable ask offers the session allow first, sent under the older allow_always kind", () => {
  assert.deepEqual(permissionOptions([], true), [
    { optionId: "allow_session", name: "Allow for this session", kind: "allow_always" },
    { optionId: "reject_once", name: "Deny", kind: "reject_once" },
  ]);
});

test("an ask that can't be granted offers a single allow", () => {
  assert.deepEqual(permissionOptions([project], false), [
    { optionId: "allow_once", name: "Allow", kind: "allow_once" },
    { optionId: "reject_once", name: "Deny", kind: "reject_once" },
  ]);
});

test("Allow every time appears only when a suggestion is bound for local settings", () => {
  assert.deepEqual(
    permissionOptions([local], true).map((option) => option.optionId),
    ["allow_session", "allow_always", "reject_once"],
  );
  assert.deepEqual(
    permissionOptions([project, directory], true).map((option) => option.optionId),
    ["allow_session", "reject_once"],
  );
});
