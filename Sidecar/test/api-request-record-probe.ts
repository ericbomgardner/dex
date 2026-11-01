/**
 * What the request records the CLI writes into a transcript since v2.1.300
 * carry, and why every reader has to gate on a record's `type`.
 *
 *   node test/api-request-record-probe.ts
 *
 * One haiku turn through the SDK in a scratch cwd, with no setting sources, that
 * reads two files with two parallel Read calls. The API takes both results as
 * one user message, and the CLI writes that merged message as an
 * `api-request-blob` beside the two `user` records it was made from. The blob
 * has a `message` with `role` and `content` like a turn, the same
 * `tool_result` blocks, and no `timestamp`, `uuid` or `isSidechain`. A reader
 * that walks `message.content` without asking the record's type reads every
 * merged result twice, the second time unstamped. The transcript is erased
 * afterwards.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { eraseTranscript } from "../src/transcripts.ts";

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

const ASK =
  "In one message, call the Read tool twice in parallel: once on a.txt and once on b.txt. " +
  "Make both calls together, not one after the other. Then reply with the two words they hold.";

async function run(cwd: string): Promise<{ sessionId: string; transcript: string }> {
  let sessionId = "";
  for await (const message of query({
    prompt: ASK,
    options: { cwd, model: "haiku", settingSources: [], allowedTools: ["Read"] },
  })) {
    if (message.type === "system" && message.subtype === "init") sessionId = message.session_id;
  }
  const slug = cwd.replace(/[^A-Za-z0-9]/g, "-");
  const configDir = process.env.CLAUDE_CONFIG_DIR ?? path.join(process.env.HOME ?? "", ".claude");
  return { sessionId, transcript: path.join(configDir, "projects", slug, `${sessionId}.jsonl`) };
}

type Row = { at: number; record: any };

/** Tool-use ids of the calls one assistant message made, keyed by message id. */
function parallelCalls(rows: Row[]): string[] {
  const byMessage = new Map<string, string[]>();
  for (const { record } of rows) {
    if (record.type !== "assistant") continue;
    for (const block of record.message?.content ?? []) {
      if (block?.type !== "tool_use" || block.name !== "Read") continue;
      const ids = byMessage.get(record.message.id) ?? [];
      ids.push(block.id);
      byMessage.set(record.message.id, ids);
    }
  }
  return [...byMessage.values()].find((ids) => ids.length >= 2) ?? [];
}

const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "dex-api-request-")));
const sessions: { sessionId: string; transcript: string }[] = [];
try {
  writeFileSync(path.join(scratch, "a.txt"), "marmalade\n");
  writeFileSync(path.join(scratch, "b.txt"), "periwinkle\n");

  let rows: Row[] = [];
  let calls: string[] = [];
  // The model chooses whether to make the calls together; a second try covers the odd run that doesn't.
  for (let attempt = 0; attempt < 2 && calls.length < 2; attempt++) {
    const session = await run(scratch);
    sessions.push(session);
    check(existsSync(session.transcript), `the transcript is on disk (${path.basename(session.transcript)})`);
    rows = readFileSync(session.transcript, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .map((line, at) => ({ at, record: JSON.parse(line) }));
    calls = parallelCalls(rows);
  }
  check(calls.length >= 2, `the model made parallel Read calls (${calls.length})`);

  const types = new Set(rows.map(({ record }) => record.type));
  for (const type of ["api-request-shape", "api-request-blob", "api-request"]) {
    check(types.has(type), `the transcript has ${type} records`);
  }

  const shape = rows.find(({ record }) => record.type === "api-request-shape")?.record;
  check(shape && Array.isArray(shape.shape?.system) && Array.isArray(shape.shape?.tools), "api-request-shape carries the system prompt and tools");

  const assistants = rows.filter(({ record }) => record.type === "assistant");
  const firstTurn = assistants[0]?.at ?? -1;
  const firstRequest = rows.find(({ record }) => record.type === "api-request")?.at ?? -1;
  check(firstRequest >= 0 && firstRequest < firstTurn, "the request records are written ahead of the turn they produce");

  const withMessage = new Set(
    rows.filter(({ record }) => record.message && typeof record.message === "object").map(({ record }) => record.type),
  );
  const others = [...withMessage].filter((type) => type !== "user" && type !== "assistant");
  console.log(`        types carrying a message: ${[...withMessage].sort().join(", ")}`);
  check(others.includes("api-request-blob"), "api-request-blob carries a message, as a turn does");

  const blobs = rows.filter(({ record }) => record.type === "api-request-blob");
  check(
    blobs.every(({ record }) => typeof record.message?.role === "string" && "content" in record.message),
    "every blob's message has a role and content",
  );
  const stamped = blobs.filter(({ record }) => "timestamp" in record || "uuid" in record || "isSidechain" in record);
  check(stamped.length === 0, `no blob has a timestamp, uuid or isSidechain (${stamped.length} do)`);

  const resultsIn = (record: any) =>
    (Array.isArray(record.message?.content) ? record.message.content : [])
      .filter((block: any) => block?.type === "tool_result")
      .map((block: any) => block.tool_use_id);
  const merged = blobs.find(({ record }) => {
    const ids = resultsIn(record);
    return record.message.role === "user" && calls.every((id) => ids.includes(id));
  });
  check(merged, "one user-role blob repeats the results of both parallel calls");

  const turns = rows.filter(({ record }) => record.type === "user" && resultsIn(record).some((id: string) => calls.includes(id)));
  check(
    calls.every((id) => turns.some(({ record }) => resultsIn(record).includes(id) && typeof record.timestamp === "string")),
    "each result is also its own stamped user record",
  );
  check(
    merged && turns.every(({ at }) => at < merged.at),
    "and the blob comes after them, so a reader that takes the newest takes the blob",
  );

} catch (error: any) {
  failures.push(String(error?.message ?? error));
  console.error(error);
} finally {
  for (const { sessionId, transcript } of sessions) {
    if (sessionId) eraseTranscript(sessionId);
    if (path.basename(path.dirname(transcript)).includes("dex-api-request-")) {
      rmSync(path.dirname(transcript), { recursive: true, force: true });
    }
  }
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length > 0 ? `\n${failures.length} failed` : "\nall passed");
process.exit(failures.length > 0 ? 1 : 0);
