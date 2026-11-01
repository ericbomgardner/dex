# What a reply is writing (CLI v2.1.312, SDK 0.3.312)

Probe: `Sidecar/test/writing-call-probe.ts` — three sessions writing a long background Agent call, each sent a message two seconds into the call's input.

**The transcript gets a block only once it is finished.** A text reply lands whole, and a call lands when its input is complete, with nothing written while either is being produced. An Agent brief of 5–8K characters takes the main model 20–25s to write. Once the call is written, the launch takes about 2s, worktree included. In a real session (2026-10-30) nothing showed while each brief was written, and the time read as agents slow to start.

**Partial messages say it as it happens.** With `includePartialMessages`, the stream carries `stream_event` frames (raw API stream events, with `parent_tool_use_id` like any other message):

- `content_block_start` with `content_block.type: "tool_use"` names the call's tool and its id, which is the id its transcript row will have, at the moment it starts.
- `input_json_delta` streams the input as unfinished JSON. A brief's `description` comes first and closes its quote within about 95 characters.
- `text_delta` streams a text block. `message_stop` ends the reply.

Thinking under `display: "updates"` streams nothing readable, so the pane says "Thinking…" there.

**The app does not stream a reply's text, because the stream does not do it consistently.** Measured on CLI v2.1.314 (SDK 0.3.314), Opus 5.5 and Fable 5.1, under the CLI's own display and under `summarized` (`Sidecar/test/narration-stream-probe.ts`):

- The short notes between tool calls are `thinking` blocks tagged `narration` ([A Thought that was never a Thought](a-thought-that-was-never-a-thought.md)). Their text comes as `thinking_delta`s, but all at once: 150–230 characters as 15–30 deltas inside 1–3ms. They are never written over time.
- Once a turn has a narration note, the text after it is held back. After seconds of nothing it comes either whole (330–2001 characters in 1–10ms) or in a rush (2517–2794 in 2–3s, ten times or more the pace of the turn's text before the note). Text before any narration, and every reply in a turn with none, streams at the model's pace.

Most working turns narrate, so most final answers would land whole or in a rush and the rest stream. From 2026-10-30 to 2026-10-31 the host sent a `session.writing` level with the reply's text every 150ms, and the pane drew it as a live row that faded in and handed over to the file. Some replies streamed and others appeared all at once, and it was taken out for that. The probe fails if the text from a narration note on starts coming at the turn's own pace, which is when this is worth trying again. Handing over was the hard part: the host's `result` can come before the file is read with the reply in it, so the live row has to stay up until the file has its copy, and the reply that replaces it has to take its height and the reader's place, or a reader partway down it is thrown to the end. A host from before the removal still sends the level. The app reads it as `unrecognised` and ignores it.

**What the host does with partial messages** (`#streamed` in `session.ts`): a call's `content_block_start` tells it whether to hold a cut-in (see below), and `message_start` sets the state. Agent turns (`parent_tool_use_id` set) are ignored.

**Calls being written get no line of their own.** Tried on 2026-10-30 ("Writing brief: …" with a clock) and dropped the same day: with launched agents no longer hiding it (below), "Thinking…" already covers the stretch, and a line per call flashed on nearly every one.

**A reply's `message_start` puts the session to `running`.** Otherwise a turn after a cut-in reads idle until its first block is finished: the cut's `result` set it idle, and nothing echoes the message that started the new turn. A brief longer than 15s then went past the app's quiet-dim and the pane drew nothing at all. A side question streams nothing on the main channel (the smoke checks it leaves the state alone).

**Launched agents are not what the turn waits on.** A background agent's call has no result until its notification, so it is in flight for the whole run, and the pane read every call in flight as the work: "Thinking…" drew only with nothing running, and the strip's Main agent row went whenever everything running was an agent. With agents out, the session's own thinking and writing showed nothing. `ToolCall.isLaunched` (set off the receipt, including one ahead of its call) and `TranscriptFlow.waitedOn` leave them out of both, the same way a backgrounded shell already was; the strip still lists them as out.

The other half, what a cut-in does to a call being written, is in [A message can cut in](a-message-can-cut-in.md).

Code: `#streamed` in `Sidecar/src/session.ts`; `TranscriptFlow.waitedOn`, `ToolCall.isLaunched`, `TranscriptPane`. Tests: `HostProtocolTests` (an older host's level read past), `TranscriptFlowTests`, `TranscriptDocumentTests`, the smoke's side-question check.
