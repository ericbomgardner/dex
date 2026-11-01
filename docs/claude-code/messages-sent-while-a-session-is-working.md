# Messages sent while a session is working (CLI v2.1.283)

Probe: `Scripts/queued-message-probe.py` — drives a real terminal session (needs `pip3 install pyte`), sends a message mid-call and reads the transcript.

Three ways a message lands, decided by what the session is doing when it arrives.

- **During a running tool call**: absorbed into the running turn. An `enqueue` carrying the text, an `attachment` of type `queued_command` with the text under `prompt` and `commandMode: "prompt"`, then a `remove` naming it with reason `absorbed_mid_turn`. **No user turn is written.** The attachment is the only record of the message; `TranscriptDocument.absorbedMessage` reads it. Miss it and the pane shows a model answering something it never drew.
- **While only thinking**, nothing to absorb into: queued. `enqueue` with the text, then a bare `dequeue` when it is taken, and an ordinary user turn at that point. **The text is on the enqueue and nowhere else**, so `TranscriptDocument.queued` reads waiting messages from there; the pane draws them faintly at the end.
- **Idle**: an ordinary user turn, nothing else.

That is the terminal's plain send, which the probe drives. The app's hosted sessions send with `priority: "now"` after backgrounding tasks (see [A message can cut in](a-message-can-cut-in.md)), which lands as the queued shape — `enqueue`, bare `dequeue`, user turn — taken at once, including into what was a running tool call. The absorbed shape still has to be read: terminal sessions and older transcripts write it.

Queue records are not turns. The CLI queues its own task-notifications through the same records; **`commandMode` tells them apart** (`prompt` vs `task-notification`), `origin` does not — it is `{kind: "human"}` on current CLIs, null on older ones, and `{kind: "peer"}` for a message from another session (see [Messaging one session from another](messaging-one-session-from-another.md)). Keep the CLI's entries in the queue and render them as nothing. **Don't drop them**: a `dequeue` removes the head without naming it, so a dropped entry shifts which message every later dequeue removes.

**A bare `dequeue` is not always the head.** A hosted send goes in at `priority: "now"` and the CLI takes it ahead of the task notifications and agent reports already waiting; the `dequeue` still names nothing. Read as the head, the notice came off and the message stayed drawn as waiting under its own turn until the notice's own dequeue, seconds later. Seen in transcripts rather than probed: about 2% of messages where sessions run many background agents (most behind a task notification, some behind an agent report or an earlier message), and almost none where they run few. The turn written after the dequeue says which message it was, so `TranscriptDocument.retake` takes that one off and puts the guessed entry back.

The three absorbed records land in the order enqueue, attachment, remove. That order is why the pane's stand-in for a just-sent message (`SessionPane.saying`) is measured against `TranscriptDocument.heard`, which counts a message **once, at the first record carrying it**, and never counts down. Summed as prompts plus queue, the count reads one high between the attachment and the remove; a high-water mark then keeps it there, and every message sent after only climbs back to the mark — one stale stand-in drawn under its own turn per absorbed message. A queued text that never becomes a turn is common (slash commands answered by `system` records, a Stop discarding the queue), which is why the count can't wait for the turn.

`TranscriptText.midTurnLead` reads the pre-v2.1.220 shape — the message injected into the turn as a `<system-reminder>` — and stays for old transcripts.

Terminal-only shapes the pane still has to draw: a pasted message is wrapped in `<pasted_content id="…">` on the enqueue, attachment and remove alike, and is drawn wrapper and all.

Probe caveats:
- The send must land while the `seq 1 25` call is running. The probe prints the send's distance from the call's start and its result, matched by `tool_use_id`, and refuses a run outside both — a send after the result measures the idle shape, before the call the thinking one, and either passes the assertions it was never asked. A fixed sleep or a wait for a permission prompt that never comes (auto mode) drifts the send past the call.
- The is-it-running gate has to read the CLI's live line (`Bash(…)` over `⎿ Running…`, or the echoed `$` command), not a finished line; `Bash(…)` stays on screen after the call ends.
- The probe refuses any known failure shape: enqueue without text, never dequeued, absorbed without an attachment, absorbed *and* written as a turn, or sent after the call finished.

Code: `TranscriptDocument.absorbedMessage`, `TranscriptDocument.queued`, `TranscriptDocument.retake`, `TranscriptDocument.heard`, `SessionPane.saying`, `TranscriptText.midTurnLead`. Tests: `TranscriptDocumentTests`.
