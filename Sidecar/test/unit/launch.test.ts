import assert from "node:assert/strict";
import { test } from "node:test";

import { launchEvent, launchRefusal, startSessionTool, type LaunchRequest } from "../../src/dex-server.ts";

type Args = Parameters<ReturnType<typeof startSessionTool>["handler"]>[0];
const call = { cwd: "/a", prompt: "hi" } as Args;

const request = (extra: Partial<LaunchRequest> = {}): LaunchRequest => ({
  cwd: "/a",
  prompt: "hi",
  parent: "p",
  ...extra,
});

test("a launch in a folder that isn't on this Mac is turned down before the app is asked", () => {
  assert.match(launchRefusal(request({ cwd: "a" }), () => true) ?? "", /not an absolute path/);
  assert.match(launchRefusal(request(), () => false) ?? "", /not a folder on this Mac/);
  assert.equal(launchRefusal(request(), () => true), null);
});

test("the launch event carries what the session asked for, and no name it didn't give", () => {
  assert.deepEqual(launchEvent("l", request()), { type: "launch", launchId: "l", cwd: "/a", prompt: "hi", parent: "p" });
  assert.equal(launchEvent("l", request({ name: "n" })).name, "n");
});

test("start_session hands the launcher the call and answers the key, or the reason as an error", async () => {
  const asked: LaunchRequest[] = [];
  const ok = startSessionTool("p", async (r) => {
    asked.push(r);
    return "k1";
  });
  const result = await ok.handler(call, undefined);
  assert.deepEqual(asked, [{ cwd: "/a", prompt: "hi", name: undefined, parent: "p" }]);
  assert.match(JSON.stringify(result.content), /session k1/);
  assert.notEqual(result.isError, true);

  const refused = startSessionTool("p", async () => {
    throw new Error("no thanks");
  });
  const failed = await refused.handler(call, undefined);
  assert.equal(failed.isError, true);
  assert.match(JSON.stringify(failed.content), /no thanks/);
});
