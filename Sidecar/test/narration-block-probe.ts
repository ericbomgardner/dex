/**
 * Whether a `thinking` block's signature still says what kind of block it is,
 * and whether our reading of it agrees with the CLI's own.
 *
 *   node test/narration-block-probe.ts
 *
 * Two kinds of block arrive as `thinking`. One is the model's reasoning. The
 * other, tagged `narration`, is **not reasoning at all** — the CLI's schema
 * calls it a "server summary of the prose between tool calls", which is to say
 * it is the assistant talking to you. The pane used to fold both away behind a
 * collapsed Thought, so a turn that narrated and then asked a question hid the
 * whole setup for that question and the question read as a non-sequitur.
 *
 * The CLI hands its own renderer the answer as `narration_block_indexes` on the
 * assistant frame, in its words "so a renderer can label them as summaries
 * without decoding the signature envelope". **That field is on the stream and
 * never in the transcript.** The pane is built from the file, so that archived
 * and resumed rows answer too, so `NarrationSignature` decodes the envelope
 * instead: base64 → protobuf field 2 → field 1 → string field 8.
 *
 * Which is a path through an opaque blob that nothing documents and nothing
 * would announce moving. **This probe is the only alarm.** It reads the same
 * blocks two ways — the CLI's field off the stream, our decode off the
 * signature — and requires them to agree.
 *
 * Three ways it can fail, and they mean different things:
 *
 *  1. **They disagree.** The envelope moved. `NarrationSignature` is wrong and
 *     the pane is mislabelling blocks right now — the loud case.
 *  2. **No `narration_block_indexes` on any frame.** The CLI stopped saying, so
 *     the cross-check is gone and this probe can no longer speak for the
 *     decoder. Not itself a bug in the app; it is the loss of the alarm.
 *  3. **No narration block produced.** The run measured nothing. Narration is a
 *     Fable behaviour and it is not guaranteed on any given turn, so this asks
 *     for prose between two tool calls, which is where it shows up. Retry
 *     before believing it.
 *
 * Failing closed is the design and is worth keeping that way round: anything
 * unparseable reads as ordinary thinking, which is what every block read as
 * before this existed. Drawing reasoning as speech would be the bad direction —
 * it would put words in the model's mouth.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const scratch = mkdtempSync(path.join(tmpdir(), "dex-narration-"));

// Narration is the prose *between tool calls*, so the turn has to have some.
// Fable, because that is where blocks with text in them come from — Opus 4.8
// tags narration too, but its blocks have come back empty.
const MODEL = "claude-fable-5-1";

// **The work has to be hard enough to think about.** Thinking is adaptive, so a
// session asked to echo two strings does the whole turn without a thinking block
// at all, and a run with no thinking blocks measures nothing. This asks for
// reasoning it cannot shortcut, and for prose between the tool calls, which is
// the only place narration lives.
const ASK =
  "Work out, carefully and from first principles, how many trailing zeros 2000! has. " +
  "Use Bash with `echo` to record your intermediate count at least twice as you go, " +
  "explaining between the two commands what the first count told you and why the " +
  "next step follows. Do not use python or any calculator — reason it out.";

const LIMIT_MS = 240_000;

/** The varint walk the CLI uses, ported here the same way Swift ports it. */
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

/** The last length-delimited field with this number, or undefined if the bytes
 *  are not a protobuf message at all. Undefined is the fail-closed answer. */
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
  let raw: Buffer;
  try {
    raw = Buffer.from(signature, "base64");
  } catch {
    return undefined;
  }
  const envelope = field(raw, 2);
  if (envelope === undefined) return undefined;
  const inner = field(envelope, 1);
  if (inner === undefined) return undefined;
  const kind = field(inner, 8);
  if (kind === undefined) return undefined;
  return Buffer.from(kind).toString("utf8");
}

type Seen = {
  index: number;
  hasText: boolean;
  ours: string | undefined;
  theirs: boolean;
};

async function main() {
  const seen: Seen[] = [];
  let framesWithField = 0;
  let thinkingBlocks = 0;

  const run = query({
    prompt: ASK,
    options: {
      model: MODEL,
      cwd: scratch,
      permissionMode: "bypassPermissions",
      systemPrompt: { type: "preset", preset: "claude_code" },
      allowedTools: ["Bash"],
    },
  });

  const deadline = setTimeout(() => {
    throw new Error(`no result inside ${LIMIT_MS}ms`);
  }, LIMIT_MS);

  for await (const message of run) {
    if (message.type !== "assistant") continue;

    // `@internal`, so it is not on the SDK's declared type. It is on the wire.
    const listed = (message as unknown as { narration_block_indexes?: number[] })
      .narration_block_indexes;
    if (listed !== undefined) framesWithField += 1;
    const tagged = new Set(listed ?? []);

    const content = (message.message?.content ?? []) as unknown as Array<Record<string, unknown>>;
    content.forEach((block, index) => {
      if (block.type !== "thinking") return;
      thinkingBlocks += 1;
      const signature = typeof block.signature === "string" ? block.signature : "";
      seen.push({
        index,
        hasText: String(block.thinking ?? "").trim().length > 0,
        ours: signature ? blockKind(signature) : undefined,
        theirs: tagged.has(index),
      });
    });
  }

  clearTimeout(deadline);

  const narration = seen.filter((s) => s.ours === "narration");
  const withText = narration.filter((s) => s.hasText);
  const disagreed = seen.filter((s) => (s.ours === "narration") !== s.theirs);

  console.log(`model                        ${MODEL}`);
  console.log(`thinking blocks              ${thinkingBlocks}`);
  console.log(`  kinds                      ${JSON.stringify(tally(seen.map((s) => s.ours)))}`);
  console.log(`  narration                  ${narration.length} (${withText.length} with text)`);
  console.log(`frames carrying the field    ${framesWithField}`);
  console.log(`disagreements                ${disagreed.length}`);

  if (disagreed.length > 0) {
    for (const one of disagreed) {
      console.log(`  block ${one.index}: we read ${String(one.ours)}, the CLI listed ${one.theirs}`);
    }
    throw new Error(
      "our decode and the CLI's own reading disagree — the signature envelope has " +
        "moved and Sources/DexCore/Transcript/NarrationSignature.swift is wrong"
    );
  }

  if (thinkingBlocks === 0) {
    throw new Error("no thinking blocks at all — the run measured nothing, retry");
  }

  if (framesWithField === 0) {
    throw new Error(
      "no frame carried narration_block_indexes — the CLI stopped saying, so this " +
        "probe can no longer speak for NarrationSignature. The decoder is not " +
        "necessarily wrong; the alarm is gone."
    );
  }

  if (withText.length === 0) {
    throw new Error(
      "no narration block with text in it — the case the pane exists to draw was " +
        "never produced. Narration is not guaranteed on a given turn; retry before " +
        "believing the CLI stopped writing them."
    );
  }

  console.log("\nagreed on every block.");
}

function tally(kinds: Array<string | undefined>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const kind of kinds) {
    const key = kind ?? "unreadable";
    out[key] = (out[key] ?? 0) + 1;
  }
  return out;
}

main()
  .catch((error) => {
    console.error(`\n${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  })
  .finally(() => rmSync(scratch, { recursive: true, force: true }));
