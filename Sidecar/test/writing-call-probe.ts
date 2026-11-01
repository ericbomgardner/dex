/**
 * What a message sent while the model is still writing a tool call does to
 * that call, and what the stream says about a call before it is finished.
 *
 *   node test/writing-call-probe.ts
 *
 * The transcript gets a call only once it is written, and a long Agent brief
 * takes the model 20s and more to write. A hosted send cuts in with
 * `priority: "now"`, and in real sessions every finished call in the reply it
 * cut came back `Error calling tool (Agent): ` with nothing after the colon.
 * Three runs, each sending two seconds into a background Agent call's input:
 *
 *  1. `"now"`, as the host sent it: is the call thrown away. Measured on CLI
 *     v2.1.312: the reply ends within 15ms and the half-written call is dropped
 *     with no result at all.
 *  2. A plain send: does the call launch, and how long does the message wait.
 *  3. Held until the reply's `message_stop`, then `backgroundTasks()` and
 *     `"now"`, the host's cut-in: does the call launch, and how long.
 *
 * Every run also reads what partial messages carry: the call's name and id at
 * `content_block_start`, and how far into its input the `description` is.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-writing-call-"));

const WORD = "PINEAPPLE";
const INTERJECTION = `Reply with exactly the word ${WORD} and nothing else, then carry on.`;
const DESCRIPTION = "count in words";
const LIMIT_MS = 240_000;
const SEND_AFTER_MS = 2_000;

const ASK =
  "Use the Agent tool exactly once, with subagent_type 'general-purpose', " +
  `description '${DESCRIPTION}', and run_in_background: true. Its prompt must be ` +
  "every number from one to two hundred spelled out in words, one per line, followed by " +
  "the line 'Reply with the word done.' Write all two hundred lines into the prompt — do not " +
  "summarise or skip ahead. Do not use any other tool. After the call comes back, say launched.";

type Lever = "now" | "plain" | "hold";

interface Run {
  callStartedAt?: number;
  callId?: string;
  callName?: string;
  /** Characters of input streamed before the description could be read. */
  descriptionAfterChars?: number;
  description?: string;
  inputChars: number;
  callWrittenAt?: number;
  replyEndedAt?: number;
  sentAt?: number;
  pushedAt?: number;
  answeredAt?: number;
  toolResult?: string;
  toolResultIsError?: boolean;
  taskStarted: boolean;
  results: { subtype: string; at: number }[];
  textDeltas: number;
}

function conversation(first: string) {
  const pending: unknown[] = [];
  let wake: () => void = () => {};
  let closed = false;
  const message = (content: string, priority?: "now") => ({
    type: "user",
    message: { role: "user", content },
    parent_tool_use_id: null,
    ...(priority ? { priority } : {}),
  });

  async function* stream(): AsyncGenerator<unknown> {
    yield message(first);
    while (!closed) {
      if (pending.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
        continue;
      }
      yield pending.shift();
    }
  }

  return {
    stream: stream(),
    send(text: string, priority?: "now") {
      pending.push(message(text, priority));
      wake();
    },
    close() {
      closed = true;
      wake();
    },
  };
}

function textOf(block: any): string {
  if (typeof block?.text === "string") return block.text;
  if (typeof block?.content === "string") return block.content;
  if (Array.isArray(block?.content)) return block.content.map(textOf).join(" ");
  return "";
}

const DESCRIPTION_FIELD = /"description"\s*:\s*"((?:[^"\\]|\\.)*)"/;

async function probe(lever: Lever): Promise<Run> {
  const run: Run = { inputChars: 0, taskStarted: false, results: [], textDeltas: 0 };
  const input = conversation(ASK);
  const session: any = query({
    prompt: input.stream as any,
    options: {
      cwd: scratch,
      model: "sonnet",
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: "bypassPermissions",
      includePartialMessages: true,
    } as any,
  });

  const deadline = setTimeout(() => {
    input.close();
    session.close?.();
  }, LIMIT_MS);

  let callIndex: number | undefined;
  let callInput = "";
  let held = false;
  let streamedSinceSend = "";

  async function cutIn(): Promise<void> {
    run.pushedAt = Date.now();
    try {
      await session.backgroundTasks?.();
    } catch {}
    input.send(INTERJECTION, "now");
  }

  function interject(): void {
    setTimeout(() => {
      run.sentAt = Date.now();
      streamedSinceSend = "";
      if (lever === "now") {
        run.pushedAt = run.sentAt;
        input.send(INTERJECTION, "now");
      } else if (lever === "plain") {
        run.pushedAt = run.sentAt;
        input.send(INTERJECTION);
      } else if (run.replyEndedAt !== undefined) {
        void cutIn();
      } else {
        held = true;
      }
    }, SEND_AFTER_MS);
  }

  try {
    for await (const message of session as AsyncIterable<any>) {
      if (message.type === "stream_event" && message.parent_tool_use_id == null) {
        const event = message.event;
        if (event?.type === "content_block_start" && event.content_block?.type === "tool_use" && run.callId === undefined) {
          run.callStartedAt = Date.now();
          run.callId = event.content_block.id;
          run.callName = event.content_block.name;
          callIndex = event.index;
          interject();
        }
        if (event?.type === "content_block_delta" && event.index === callIndex && event.delta?.type === "input_json_delta") {
          callInput += event.delta.partial_json ?? "";
          run.inputChars = callInput.length;
          if (run.description === undefined) {
            const found = DESCRIPTION_FIELD.exec(callInput);
            if (found) {
              run.description = JSON.parse(`"${found[1]}"`);
              run.descriptionAfterChars = callInput.length;
            }
          }
        }
        if (event?.type === "content_block_stop" && event.index === callIndex && run.callWrittenAt === undefined) {
          run.callWrittenAt = Date.now();
        }
        if (event?.type === "message_stop" && run.callId !== undefined && run.replyEndedAt === undefined) {
          run.replyEndedAt = Date.now();
          if (held) void cutIn();
        }
        if (event?.type === "content_block_delta" && event.delta?.type === "text_delta") {
          run.textDeltas += 1;
          if (run.sentAt !== undefined) {
            streamedSinceSend += event.delta.text;
            if (run.answeredAt === undefined && streamedSinceSend.includes(WORD)) run.answeredAt = Date.now();
          }
        }
      }

      if (message.type === "user" && message.parent_tool_use_id == null && run.callId !== undefined) {
        for (const block of message.message?.content ?? []) {
          if (block?.type === "tool_result" && block.tool_use_id === run.callId && run.toolResult === undefined) {
            run.toolResult = textOf(block).trim().slice(0, 160);
            run.toolResultIsError = block.is_error === true;
          }
        }
      }

      if (message.type === "system" && message.subtype === "task_started" && message.tool_use_id === run.callId) {
        run.taskStarted = true;
      }

      if (message.type === "result") {
        run.results.push({ subtype: message.subtype, at: Date.now() });
        if (run.answeredAt !== undefined && run.toolResult !== undefined) break;
      }
    }
  } finally {
    clearTimeout(deadline);
    input.close();
    session.close?.();
  }
  return run;
}

const failures: string[] = [];
function check(condition: unknown, description: string): void {
  console.log(`${condition ? "  ok" : "FAIL"}  ${description}`);
  if (!condition) failures.push(description);
}

function since(at: number | undefined, from: number | undefined): string {
  return at !== undefined && from !== undefined ? `${at - from}ms` : "never";
}

function describe(name: string, run: Run): void {
  console.log(`\n${name}`);
  console.log(`  call: ${run.callName} ${run.callId ?? "(none)"}, ${run.inputChars} chars of input`);
  console.log(`  description "${run.description ?? "(never read)"}" readable after ${run.descriptionAfterChars ?? "?"} chars`);
  console.log(`  sent ${since(run.sentAt, run.callStartedAt)} into the call; call written ${since(run.callWrittenAt, run.callStartedAt)} in; reply ended ${since(run.replyEndedAt, run.callStartedAt)} in`);
  console.log(`  pushed ${since(run.pushedAt, run.sentAt)} after sending; answered ${since(run.answeredAt, run.sentAt)} after sending`);
  console.log(`  call's result (${run.toolResultIsError ? "error" : "ok"}): ${run.toolResult?.replace(/\s+/g, " ") ?? "none"}`);
  console.log(`  task_started for the call: ${run.taskStarted}; text deltas: ${run.textDeltas}`);
  console.log(`  results: ${run.results.map((result) => `${result.subtype} at ${since(result.at, run.sentAt)}`).join(", ") || "none"}`);
}

function sentWhileWriting(run: Run): boolean {
  return (
    run.sentAt !== undefined &&
    run.callStartedAt !== undefined &&
    (run.callWrittenAt === undefined || run.sentAt < run.callWrittenAt)
  );
}

try {
  const cut = await probe("now");
  describe("priority now, sent while the call is being written", cut);
  check(sentWhileWriting(cut), "now: sent before the call was finished");
  check(cut.callName === "Agent", "partial messages name the call at content_block_start");
  check(cut.description === DESCRIPTION, "the description is readable off the streaming input");
  check(cut.results[0]?.subtype === "error_during_execution", "now: the reply is cut, ending on a result of its own");
  check(cut.toolResultIsError !== false && !cut.taskStarted, "now: the call being written never launches");

  const plain = await probe("plain");
  describe("plain send, sent while the call is being written", plain);
  check(sentWhileWriting(plain), "plain: sent before the call was finished");
  check(plain.toolResultIsError === false && plain.taskStarted, "plain: the call launches");
  check(plain.answeredAt !== undefined, "plain: the message is answered");

  const hold = await probe("hold");
  describe("held to the reply's end, then backgroundTasks and now", hold);
  check(sentWhileWriting(hold), "hold: sent before the call was finished");
  check(hold.toolResultIsError === false && hold.taskStarted, "hold: the call launches");
  check(hold.answeredAt !== undefined, "hold: the message is answered");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(failures.length ? `\nwriting-call: ${failures.length} check(s) failed` : "\nwriting-call: all checks passed");
process.exit(failures.length ? 1 : 0);
