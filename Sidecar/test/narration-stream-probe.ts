/**
 * Why the app does not stream a reply's text: whether it can be streamed
 * consistently.
 *
 *   node test/narration-stream-probe.ts [--display summarized|omitted] [model…]
 *
 * Partial messages carry each text block's `text_delta`s, and the app once drew
 * them as they came. Some replies streamed and some landed whole, and the
 * stream is why. This reads every thinking and text block off the partial
 * messages (how much text arrived, over how long) and decodes each thinking
 * block's kind from the signature it streamed, the way `NarrationSignature`
 * does. Measured on CLI v2.1.314 (SDK 0.3.314), Opus 5.5 and Fable 5.1, under
 * the CLI's own display and under `summarized`:
 *
 *  - **A narration note is never written over time.** Its 150–230 characters
 *    come as 15–30 `thinking_delta`s inside 1–3ms.
 *  - **Text after a narration note in the same turn is held back**, then
 *    comes after seconds of nothing either whole (330–2001 characters in
 *    1–10ms) or in a rush (2517–2794 in 2–3s, ten times or more the pace of
 *    the turn's text before it). Text before any narration, and every reply in a turn with
 *    none, streams at the model's pace.
 *
 * Most working turns narrate, so most final answers would land whole or in a
 * rush and the rest stream. It fails when that changes: text from the first
 * note on arriving at no more than twice the pace of the text before it means
 * streaming could be consistent, and the decision in
 * docs/claude-code/what-a-reply-is-writing.md is worth revisiting. A run with
 * no text before a note and after it measured nothing; retry.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
// `--display summarized|omitted` asks for that instead of the CLI's own default.
const displayAt = args.indexOf("--display");
const DISPLAY = displayAt >= 0 ? (args.splice(displayAt, 2)[1] as "summarized" | "omitted") : undefined;
const MODELS = args.length > 0 ? args : ["claude-opus-5-5", "claude-fable-5-1"];

// Narration-block-probe's ask, which narrates between its tool calls, with a
// final answer long enough that streaming it or not is plain.
const ASK =
  "Work out, carefully and from first principles, how many trailing zeros 2000! has. " +
  "Use Bash with `echo` to record your intermediate count at least twice as you go, " +
  "explaining between the two commands what the first count told you. Do not use " +
  "python or any calculator. Finish with a six-paragraph explanation of the method.";

const LIMIT_MS = 240_000;

/** How much faster than the turn's own pace text can come and still count as written as it went. */
const PACE_SLACK = 2;

function varint(bytes: Uint8Array, start: number): { value: number; next: number } | undefined {
  let value = 0;
  let scale = 1;
  for (let step = 0; step < 10; step++) {
    const at = start + step;
    if (at >= bytes.length) return undefined;
    const byte = bytes[at];
    value += (byte & 127) * scale;
    if ((byte & 128) === 0) return { value, next: at + 1 };
    scale *= 128;
  }
  return undefined;
}

function field(bytes: Uint8Array, wanted: number): Uint8Array | undefined {
  let found: Uint8Array | undefined;
  let at = 0;
  while (at < bytes.length) {
    const tag = varint(bytes, at);
    if (tag === undefined) return undefined;
    const wire = tag.value & 7;
    const number = Math.floor(tag.value / 8);
    at = tag.next;
    if (wire === 0) {
      const skipped = varint(bytes, at);
      if (skipped === undefined) return undefined;
      at = skipped.next;
    } else if (wire === 1) {
      if (at + 8 > bytes.length) return undefined;
      at += 8;
    } else if (wire === 2) {
      const length = varint(bytes, at);
      if (length === undefined || length.value > bytes.length - length.next) return undefined;
      const end = length.next + length.value;
      if (number === wanted) found = bytes.subarray(length.next, end);
      at = end;
    } else if (wire === 5) {
      if (at + 4 > bytes.length) return undefined;
      at += 4;
    } else {
      return undefined;
    }
  }
  return found;
}

function blockKind(signature: string): string | undefined {
  const envelope = field(Buffer.from(signature, "base64"), 2);
  const inner = envelope && field(envelope, 1);
  const kind = inner && field(inner, 8);
  return kind && Buffer.from(kind).toString("utf8");
}

interface Block {
  /** `narration` or `thinking` off the signature, or `text` for a text block. */
  kind?: string;
  deltas: number;
  /** Deltas that carried any text, and when the first and last of them came. */
  textDeltas: number;
  chars: number;
  firstTextAt?: number;
  lastTextAt?: number;
  startedAt: number;
  stoppedAt?: number;
  signature: string;
  /** The block's text on the finished assistant message. */
  finishedChars?: number;
}

async function probe(model: string): Promise<Block[]> {
  const scratch = mkdtempSync(path.join(tmpdir(), "dex-narration-stream-"));
  const blocks: Block[] = [];
  let open = new Map<number, Block>();
  try {
    const run = query({
      prompt: ASK,
      options: {
        model,
        cwd: scratch,
        permissionMode: "bypassPermissions",
        systemPrompt: { type: "preset", preset: "claude_code" },
        allowedTools: ["Bash"],
        includePartialMessages: true,
        ...(DISPLAY ? { thinking: { type: "adaptive" as const, display: DISPLAY } } : {}),
      },
    });
    const deadline = setTimeout(() => run.interrupt(), LIMIT_MS);

    for await (const message of run) {
      if (message.type === "stream_event") {
        if (message.parent_tool_use_id) continue;
        const event = message.event as any;
        const now = Date.now();
        if (event.type === "message_start") open = new Map();
        const type = event.content_block?.type;
        if (event.type === "content_block_start" && (type === "thinking" || type === "text")) {
          const block: Block = {
            kind: type === "text" ? "text" : undefined, deltas: 0, textDeltas: 0, chars: 0, startedAt: now, signature: "",
          };
          open.set(event.index, block);
          blocks.push(block);
        }
        const block = open.get(event.index);
        if (!block) continue;
        if (event.type === "content_block_delta") {
          block.deltas += 1;
          const text = event.delta?.type === "thinking_delta" ? event.delta.thinking
            : event.delta?.type === "text_delta" ? event.delta.text : undefined;
          if (text) {
            block.textDeltas += 1;
            block.chars += text.length;
            block.firstTextAt ??= now;
            block.lastTextAt = now;
          } else if (event.delta?.type === "signature_delta") {
            block.signature += event.delta.signature ?? "";
          }
        }
        if (event.type === "content_block_stop") {
          block.stoppedAt = now;
          if (block.kind !== "text") block.kind = block.signature ? blockKind(block.signature) : undefined;
        }
      } else if (message.type === "assistant" && !message.parent_tool_use_id) {
        for (const part of (message.message?.content ?? []) as any[]) {
          if (part.type !== "thinking") continue;
          const match = blocks.find((b) => b.signature && b.signature === part.signature);
          if (match) match.finishedChars = String(part.thinking ?? "").length;
        }
      }
    }
    clearTimeout(deadline);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return blocks;
}

function spread(block: Block): number {
  return (block.lastTextAt ?? 0) - (block.firstTextAt ?? 0);
}

/** Characters a second, a block that came all at once counted as over 1ms. */
function pace(block: Block): number {
  return (block.chars * 1000) / Math.max(spread(block), 1);
}

async function main() {
  let measured = false;
  let streamed = 0;
  for (const model of MODELS) {
    const blocks = await probe(model);
    console.log(`\n${model}${DISPLAY ? `, display ${DISPLAY}` : ""}: ${blocks.length} thinking and text blocks`);
    for (const b of blocks) {
      const span = b.firstTextAt && b.lastTextAt ? `${spread(b)}ms` : "-";
      const open = b.stoppedAt ? `${b.stoppedAt - b.startedAt}ms` : "?";
      const at = `+${((b.startedAt - blocks[0].startedAt) / 1000).toFixed(2)}s`;
      const rate = b.chars > 0 ? `, ${Math.round(pace(b))} chars/s` : "";
      console.log(
        `  ${at.padStart(8)} ${(b.kind ?? "unreadable").padEnd(10)} deltas ${String(b.deltas).padStart(3)}, ` +
          `with text ${String(b.textDeltas).padStart(3)}, ${String(b.chars).padStart(5)} chars ` +
          `over ${span.padStart(6)} (open ${open})${rate}`
      );
    }
    const first = blocks.findIndex((b) => b.kind === "narration" && b.chars > 0);
    // The turn's own pace, off text written before any narration: models and
    // machines differ, so a fixed rate would judge the model rather than the stream.
    const before = blocks.slice(0, Math.max(first, 0)).filter((b) => b.kind === "text" && b.chars >= 50 && spread(b) > 0);
    const after = first < 0 ? [] : blocks.slice(first).filter((b) => b.chars > 0 && b.kind !== "thinking");
    if (before.length === 0 || !after.some((b) => b.kind === "text")) {
      console.log("  no text both before a narration note and after it — measured nothing for this model");
      continue;
    }
    measured = true;
    const own = before.reduce((sum, b) => sum + b.chars, 0) * 1000 / before.reduce((sum, b) => sum + spread(b), 0);
    const streams = after.filter((b) => pace(b) <= own * PACE_SLACK);
    streamed += streams.length;
    console.log(
      `  the turn's own pace ${Math.round(own)} chars/s; from the first note on, ${after.length} blocks, ` +
        `${streams.length} within ${PACE_SLACK}x of it`
    );
  }
  if (!measured) throw new Error("no run had text both before a narration note and after it — retry before believing it");
  if (streamed > 0) {
    throw new Error(
      "text from a narration note on now comes at the turn's own pace — streaming could be consistent; " +
        "see docs/claude-code/what-a-reply-is-writing.md"
    );
  }
}

main().catch((error) => {
  console.error(`\n${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
