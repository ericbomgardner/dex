# Subagent results (CLI v2.1.300, SDK 0.3.300)

Probe: `Scripts/subagent-totals-probe.py`

The counts sit in the result; the report does not — see [A subagent's report arrives as a message, not in its result](a-subagents-report-arrives-as-a-message.md). Two shapes:

- A **foreground** agent's Task result carries `totalToolUseCount`, `totalTokens`, and `totalDurationMs`.
- A **background** agent's Task result is only a launch receipt (`status: "async_launched"`). Completion arrives later as a `<task-notification>` naming the call, with the same three counts in a `<usage>` block. **Don't treat the receipt as completion**, or a four-minute agent appears to finish in two seconds.

Two things about the notification that fail quietly if read the obvious way:

- **It doesn't always arrive as a turn.** If the session is busy with a tool call when the agent finishes, the notification is absorbed into the running turn — as an `attachment` under `commandMode: "task-notification"`, with no user turn written. Reading only `commandMode == "prompt"` drops those and the call stays pending for the rest of the conversation. `bringAgentsBack` reads both.
- **The tally is inside the notification, not after it.** `<usage>` sits *before* `</task-notification>`. Reading only the text after the close tag finds nothing, and every background agent falls back to the two timestamps. Both places are read; the outside form has only ever been seen in the fixture that pinned it.

Since 2.1.299 a notice can name only its task, after an interim one that named the call; see [A subagent's report arrives as a message](a-subagents-report-arrives-as-a-message.md). The probe joins the two the same way, and otherwise a notice that names no call fails it, tally or not. It samples only text that opens with `<task-notification>`, since a prompt quoting the tag in prose turned it red once, and skips a `Monitor event:` notice, which never names a call or carries a tally ([A watcher is a task the CLI cannot tell from a shell](a-watcher-is-a-task-the-cli-cannot-tell-from-a-shell.md)).

The pane's summary line is the app's own formatting (`SubagentTotals.summary`, `Format.elapsed`); an agent that reports no counts falls back to the timestamps of the two turns.

Code: `bringAgentsBack`, `SubagentTotals.summary`, `Format.elapsed`, `TranscriptText.totals`. Tests: `TranscriptDocumentTests`, `FormattingTests`.
