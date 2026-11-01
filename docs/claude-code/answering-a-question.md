# Answering a question (CLI v2.1.300, SDK 0.3.300)

Probe: `Sidecar/test/question-answer-probe.ts` — one session, asks a question and answers it through each channel.

A hosted `AskUserQuestion` is answered by allowing the call with a rewritten `updatedInput`. Three things can go in it:

- `answers` — echoed to the model verbatim and **never checked against the offered options**. A typed sentence is a valid answer on its own; the card's free-text row depends on this.
- `annotations[question].notes` — notes beside a pick, keyed on the question text. The CLI appends a sentence of its own on the way through (`Read the answers carefully — they may request clarification…`).
- `response` — **replaces answering entirely**. The result collapses to `The user responded: …` and any answers or notes sent beside it are dropped. It is the composer's channel, not a fuller answer. `decisionFor` keeps the two apart so a card can't build a payload the CLI would half-discard.

**`response` is the fragile one and the reading to re-run.** It is not in the tool's input schema at all — `AskUserQuestionInput` declares `questions`, `answers`, `annotations`, `metadata`; `response` is an *output* field — so it works only because the CLI passes it through, and nothing will announce it if that stops. The failure is quiet: held picks would reach the model as answers nobody chose. CLI 2.1.300 began validating a hook's `updatedInput` like Claude's own and dropping unknown keys; the probe still passed on it, so that validation doesn't reach the `canUseTool` answer the host gives. It is the change to expect, though.

Probe caveats: verify `response` through **both** the tool result and the model's next turn — a field the CLI keeps but the model never reads is not a channel. Run in a scratch directory; a `CLAUDE.md` above the cwd changes the answers.

The transcript keeps it beside the result as `toolUseResult.response` (seen in CLI v2.1.287 files), with `answers` empty, so the question card draws it in place of answers.

Code: `decisionFor` in `permissions.ts`, `updatedInput`; `RawToolResult.response` and `QuestionCard` for the reading. Tests: the probe; `testPicksUpAReplyTypedInsteadOfAnswering`.
