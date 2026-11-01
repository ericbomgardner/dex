/**
 * What a rewritten AskUserQuestion input can carry back.
 *
 *   node test/question-answer-probe.ts
 *
 * The host answers a question by allowing the call with an `updatedInput`, so
 * what the model is told the user said is whatever this writes into it. Three
 * channels, and they are not alternatives to each other — verified against
 * SDK 0.3.227 / CLI v2.1.227 on 2026-08-11:
 *
 *   answers[q]              echoed verbatim, with no check against the labels
 *                           the question offered — which is what lets a typed
 *                           answer be an answer rather than a note about one
 *   annotations[q].notes    reaches the model beside the pick it belongs to
 *   response                said *instead* of answering: the result collapses
 *                           to "The user responded: …" and answers and notes
 *                           sent with it are dropped
 *
 * That last one is the reading worth re-running. It is not in the tool's input
 * schema at all — `AskUserQuestionInput` declares only questions, answers,
 * annotations and metadata, and `response` appears on the *output* — so it
 * works by the CLI's grace rather than by contract, and the day it stops the
 * failure is silent: every pick the card was holding goes to the model as an
 * answer nobody chose, instead of the sentence that was typed in its place.
 *
 * Measured through the tool result and the model's own next turn, since a field
 * the CLI keeps but the model never reads is not a channel. Run in a scratch
 * directory, a CLAUDE.md above the cwd being context that changes the answers.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const FREE_TEXT = "Neither — use a chartreuse gradient";
const NOTE = "and keep it under 40kb";
const RESPONSE = "let's talk about it first";

const ASK =
  "Use the AskUserQuestion tool right now to ask me one question: which " +
  "accent color the button should be, red or blue. Ask it before doing " +
  "anything else. After I answer, repeat back to me, verbatim and in full, " +
  "everything the tool told you I said — the answer and any notes.";

type Mode = "answers" | "response";

interface Run {
  result: string;
  said: string;
}

async function ask(mode: Mode, scratch: string): Promise<Run> {
  let result = "";
  let said = "";

  for await (const message of query({
    prompt: ASK,
    options: {
      cwd: scratch,
      systemPrompt: { type: "preset", preset: "claude_code" },
      canUseTool: async (toolName: string, input: any) => {
        if (toolName !== "AskUserQuestion") {
          return { behavior: "deny", message: "not the tool under test" } as any;
        }
        const question = input.questions[0].question;
        const updatedInput =
          mode === "answers"
            ? {
                questions: input.questions,
                answers: { [question]: FREE_TEXT },
                annotations: { [question]: { notes: NOTE } },
              }
            : {
                questions: input.questions,
                answers: {},
                response: RESPONSE,
              };
        return { behavior: "allow", updatedInput } as any;
      },
    } as any,
  })) {
    if (message.type === "user") {
      for (const block of (message as any).message.content ?? []) {
        if (block.type === "tool_result") result += JSON.stringify(block.content);
      }
    }
    if (message.type === "assistant") {
      for (const block of (message as any).message.content ?? []) {
        if (block.type === "text") said += block.text;
      }
    }
  }

  return { result, said };
}

function check(name: string, held: boolean): boolean {
  console.log(`${held ? "ok  " : "FAIL"}  ${name}`);
  return held;
}

const scratch = mkdtempSync(path.join(tmpdir(), "dex-question-answer-"));
let held = true;

try {
  const answers = await ask("answers", scratch);
  console.log("\n--- answers + annotations ---");
  console.log(answers.result);
  held = check(
    "a typed answer is echoed where a label was expected",
    answers.result.includes("chartreuse"),
  ) && held;
  held = check("notes reach the result beside the answer", answers.result.includes(NOTE)) && held;
  held = check(
    "the model reads the typed answer back",
    answers.said.toLowerCase().includes("chartreuse"),
  ) && held;
  held = check("the model reads the notes back", answers.said.includes("40kb")) && held;

  const response = await ask("response", scratch);
  console.log("\n--- response ---");
  console.log(response.result);
  held = check("a response is what the result carries", response.result.includes(RESPONSE)) && held;
  // The wording is the CLI's and may move; that it says *responded* rather than
  // *answered* is the part that says this is the other channel.
  held = check(
    "a response is recorded as said rather than picked",
    response.result.includes("responded"),
  ) && held;
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

if (!held) {
  console.error(
    "\nA channel the card sends on has moved. Answering may now be reaching the\n" +
      "model as something other than what was written into the card.",
  );
  process.exit(1);
}
console.log("\nAll three channels still carry what the card puts in them.");
