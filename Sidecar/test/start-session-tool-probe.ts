/**
 * A hosted session can start another through the host's own
 * `start_session` tool, and the call never asks.
 *
 * The tool is an in-process MCP server the host attaches to every
 * session, with its one tool pre-approved. Readings:
 *
 *   - The model finds the tool and calls it, and the launcher is handed the
 *     cwd, prompt and name it gave, with the calling session's key as parent.
 *   - Nothing reaches `canUseTool`: no ask is emitted for it.
 *   - The tool result is what the launcher answered, key included; a launcher
 *     that throws comes back as an error result carrying the reason.
 *   - The server is kept out of the session's MCP readings, which are about
 *     the user's own servers.
 *   - `list_sessions`, beside it, is found, answers off the fleet file, and
 *     doesn't ask either.
 *
 *   node test/start-session-tool-probe.ts
 */

import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { DEX_SERVER, type LaunchRequest } from "../src/dex-server.ts";
import { HostedSession } from "../src/session.ts";
import type { Event } from "../src/protocol.ts";

const failures: string[] = [];

function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const dir = realpathSync(mkdtempSync(path.join(tmpdir(), "start-session-tool-probe-")));
const CHILD_KEY = "probe-child-key-4711";
const REFUSAL = "probe refusal 0815";

function transcript(sessionId: string): string {
  return path.join(homedir(), ".claude/projects", dir.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
}

function toolResults(file: string): { text: string; isError: boolean }[] {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line))
    .filter((record) => record.type === "user" && Array.isArray(record.message?.content))
    .flatMap((record) => record.message.content)
    .filter((block: any) => block?.type === "tool_result")
    .map((block: any) => ({
      text: typeof block.content === "string" ? block.content : JSON.stringify(block.content),
      isError: block.is_error === true,
    }));
}

const deadline = (ms: number) =>
  new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`nothing within ${ms / 1000}s`)), ms));

const asked: LaunchRequest[] = [];
let refuse = false;
const asks: string[] = [];
let mcpNames = null as string[] | null;
let resolveTurn: () => void = () => {};
let turn = new Promise<void>((resolve) => (resolveTurn = resolve));

const instruction = (name: string) =>
  `Use the start_session tool from the ${DEX_SERVER} MCP server (search for it if it is deferred) ` +
  `with cwd ${JSON.stringify(dir)}, prompt "say hi", and name ${JSON.stringify(name)}. ` +
  `Then reply with only the exact text the tool returned.`;

const session = new HostedSession(
  { cwd: dir, prompt: instruction("Probe child"), model: "haiku", settingSources: [] },
  (event: Event) => {
    if (event.type === "ask") asks.push(event.toolName ?? event.kind);
    if (event.type === "session.init" && event.mcpServers) mcpNames = event.mcpServers.map((s) => s.name);
    if (event.type === "session.mcp") mcpNames = event.servers.map((s) => s.name);
    if (event.type === "session.result") {
      resolveTurn();
      turn = new Promise<void>((resolve) => (resolveTurn = resolve));
    }
  },
  async (request) => {
    asked.push(request);
    if (refuse) throw new Error(REFUSAL);
    return CHILD_KEY;
  },
);

let sessionId = "";
try {
  session.start();
  await Promise.race([turn, deadline(180_000)]);
  sessionId = session.sessionId ?? "";

  check(asked.length === 1, `the launcher was called once (${asked.length})`);
  check(asked[0]?.cwd === dir, `with the cwd (${asked[0]?.cwd})`);
  check(asked[0]?.prompt === "say hi", `and the prompt (${JSON.stringify(asked[0]?.prompt)})`);
  check(asked[0]?.name === "Probe child", `and the name (${JSON.stringify(asked[0]?.name)})`);
  check(asked[0]?.parent === session.key, "with the calling session's key as parent");
  check(asks.length === 0, `nothing asked (${JSON.stringify(asks)})`);
  check(mcpNames !== null && !mcpNames.includes(DEX_SERVER), `${DEX_SERVER} is not in the MCP readings (${JSON.stringify(mcpNames)})`);

  await sleep(1_000);
  const started = toolResults(transcript(sessionId)).find((result) => result.text.includes(CHILD_KEY));
  check(started && !started.isError, "the tool result carries the launcher's key");

  refuse = true;
  const done = turn;
  session.send(instruction("Probe child two"));
  await Promise.race([done, deadline(180_000)]);
  await sleep(1_000);
  const refused = toolResults(transcript(sessionId)).find((result) => result.text.includes(REFUSAL));
  check(refused?.isError, "a launcher that throws comes back as an error result with its reason");

  const before = toolResults(transcript(sessionId)).length;
  const listed = turn;
  session.send(
    `Use the list_sessions tool from the ${DEX_SERVER} MCP server (search for it if it is deferred), ` +
      `then reply with only the word done.`,
  );
  await Promise.race([listed, deadline(180_000)]);
  await sleep(1_000);
  const listing = toolResults(transcript(sessionId))
    .slice(before)
    .find((result) => /Message one with SendMessage|No other Dex session|hasn't published/.test(result.text));
  check(listing && !listing.isError, `list_sessions answers with the fleet (${JSON.stringify(listing?.text.slice(0, 80))})`);
  check(asks.length === 0, `still nothing asked (${JSON.stringify(asks)})`);
  session.stop();
} catch (error: any) {
  check(false, `probe ran: ${error?.message ?? error}`);
} finally {
  await sleep(1_000);
  rmSync(dir, { recursive: true, force: true });
  if (sessionId) rmSync(path.dirname(transcript(sessionId)), { recursive: true, force: true });
}

if (failures.length > 0) {
  console.log(`\n${failures.length} failed`);
  process.exit(1);
}
console.log("\nall ok");
process.exit(0);
