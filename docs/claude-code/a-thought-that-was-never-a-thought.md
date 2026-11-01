# A Thought that was never a Thought (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/narration-block-probe.ts` — one session doing real work; reads each thinking block off the stream's `narration_block_indexes` and off our own signature decode, and requires the two to agree.

Two kinds of block arrive as `thinking`, and one **is not reasoning**. The server tags some with `block_kind: "narration"` — the API's progress updates (`thinking.display: "summarized"`, which Claude Code runs, delivers them beside summarized reasoning): the assistant's short note to the user between tool calls. Drawn as a collapsed Thought, a turn that narrated and then asked a question hides the whole setup for the question. A progress note is short by design and can be wrong about its own turn; it is not a transcript of the work.

**By CLI v2.1.312 the request asks for `display: "updates"`** (seen in a session's `api-request` records, not probed), and reasoning blocks come back with no text at all, only a signature: 250 of 283 thinking blocks in one long Opus session, the rest narration. So a reply with no Thought in the pane is the model's reasoning withheld by the API, not hidden by the app; the empty-text guard below is what keeps those blocks off screen.

Its text arrives in one burst, not over time, and the text after it in the turn is held back and comes whole or in a rush, which is why the app streams no reply text ([What a reply is writing](what-a-reply-is-writing.md)).

How it is drawn: as speech, open, one `ProseText` run (every one seen is a single paragraph, some with inline code, nothing else — so `Narration` skips `MarkdownText`'s block layout while still parsing markdown), with a grey `summarized` label carrying the caveat and the prose at full weight. Terminal Claude Code dims both; the app dims only the label, deliberately.

**The CLI's own answer is unreachable from the file.** `narration_block_indexes` rides on the assistant *stream frame* and is in no transcript, and the pane is built from the file so archived and resumed rows answer too. So `NarrationSignature` decodes the signature envelope, ported from the CLI's decoder: base64 → protobuf field 2 → field 1 → string field 8, a repeated field taking the **last** match, a malformed message aborting the whole walk.

- **Fail closed, and mind the direction.** Anything unparseable reads as ordinary thinking — what every block read as before — whereas drawing reasoning as speech puts words in the model's mouth. Opus 4.6 and most of 4.7 carry legacy envelopes and land there.
- The one exception is padding: `Data(base64Encoded:)` refuses an unpadded string where `atob` accepts one, and failing closed there is a silent revert to the bug, so a short signature is padded and retried.
- **An empty tagged block is ordinary** (the schema says so). The document drops every empty thinking block before asking the kind, which gives this for free; keep that order.
- The only kinds seen are `thinking` and `narration`. `"summarized"` is never a `block_kind` — it is the terminal's label — so a scan that greps readable strings out of the signature gets it wrong.
- Not Fable-only: Opus 4.8 tags narration too. Text-bearing ones so far are Fable 5/5.1.
- `SessionDigest.saidText` counts narration as something said: a turn that narrated and then asked has nothing else to name the row by.

Probe caveats:
- The work has to be hard enough to think about. Thinking is adaptive: a session asked to echo two strings produces no thinking blocks at all and the run measures nothing, and asking for `display: "summarized"` outright doesn't fix it. The probe asks for something it can't shortcut, with `echo` between steps.
- Its three failures mean different things: disagreement means the envelope moved; no frame carrying `narration_block_indexes` means the cross-check is gone; no narration block means the run measured nothing.

Code: `NarrationSignature`, `TranscriptRecord.RawBlock.thinking`, `TranscriptDocument` (`.narration` vs `.thinking`, after the empty-text guard), `TranscriptFlow`, `Narration`, `ProseText`, `SessionDigest.saidText`. Tests: `NarrationSignatureTests` (real signatures per kind — a fixture built to the decoder's expected shape passes with the field path wrong), `TranscriptDocumentTests`, `SessionDigestTests`.
