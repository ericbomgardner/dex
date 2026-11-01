# A subagent's own transcript (CLI v2.1.283)

Probe: `Sidecar/test/nested-agent-result-probe.ts` — a foreground depth-1 agent launches a background depth-2 agent and the probe reads the depth-1 file for the delivery.

A subagent's conversation is written to `<project>/<session-id>/subagents/agent-<agentId>.jsonl`, beside the parent's file. Nested agents land in the same **flat** directory, so a depth-3 agent is found the way a depth-1 one is, and the tree is rebuilt from ids, never from paths. The directory travels with the session (a cwd change moves the whole folder), which is why `SubagentTranscript.directory` derives the path from the transcript actually opened, not from the session id.

Every record in the file is `isSidechain: true`. Reading it as a conversation means keeping what the main conversation drops — `TranscriptDocument(keepsSidechain:)`. Without it the whole file reads as empty.

Linking a file back to its call has four cases and three work:
- Depth 1, either kind: `toolUseResult.agentId` beside the result.
- Deeper, background: `toolUseResult` is null on every spawn, so the id comes only from the receipt's text (`agentId: …`, `TranscriptText.launchedAgentID`).
- Deeper, foreground: no id anywhere. `SubagentTranscript.locate` returns nil rather than guessing from timing or what is left in the directory — a wrong match files one agent's conversation under another's name.

A nested background agent's delivery lands in the **parent subagent's file**, in the absorbed shape: an `attachment` with `commandMode: "task-notification"` and `isSidechain: true`, never a user turn; the main transcript keeps only an `enqueue` and a `remove` (`absorbed_mid_turn`). The notification names the `task_id` and the launching `tool_use_id`, so `bringAgentsBack` settles the depth-2 call one level down with no code of its own. **The sidechain gate runs before the attachment branch**, so a fixture for this must carry `isSidechain: true` on the attachment record itself (written inline, not through the `absorbed(notice:)` helper) or it is dropped before it is read. Files from before this delivery existed hold nothing that settles the call and spin.

The same task id can notify more than once (a finished agent can be resumed). First word wins.

The file ends on a `SubagentHandback` call with the report under `input.message` — see [A subagent's report arrives as a message](a-subagents-report-arrives-as-a-message.md). Reading off disk rather than the socket is deliberate: `forwardSubagentText` puts the same turns on the socket, but the file also answers for archived and resumed sessions.

Code: `SubagentTranscript.directory`, `SubagentTranscript.locate`, `TranscriptDocument(keepsSidechain:)`, `TranscriptDocument.bringAgentsBack`, `TranscriptText.launchedAgentID`, `forwardSubagentText`. Tests: `SubagentTranscriptTests`, `TranscriptDocumentTests`.
