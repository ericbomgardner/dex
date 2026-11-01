# A session could go and collect an agent instead of waiting for it (CLI v2.1.259 through v2.1.269; gone by CLI v2.1.278, SDK 0.3.278)

No probe: one measured it until the tool went and was then deleted, since a probe can only confirm an absence it was already told about.

**The tool is gone but the records are not.** The SDK's types say `TaskOutput` was removed, so a current CLI cannot write one of these — but every transcript that recorded a collection still opens in the pane. Everything below is a reader of old files and **must not be removed as dead code**: an Agent call settled by a collection would otherwise spin for the rest of the file.

`TaskOutput(task_id, block: true)` returned a background agent's result the moment the agent was done — a third way an agent came back, beside the notification's two doors in [Subagent results](subagent-results.md) — and **the notification was not reliably written when it happened**. The collection is the reliable word, structured beside the result: `toolUseResult.retrieval_status` with `task.{task_id, task_type, status, output}`.

- **`task_id` is the receipt's `agentId`**, and that join is the only way in — `TaskOutput` never names the call it settles. `TranscriptDocument.agentCalls` keeps the reverse of `callSites`, written in `note(agentID:on:)` **before** the call is looked up, since a receipt arriving ahead of its call waits in `early` and would otherwise lose the id for the whole run.
- **A collection can be read before the receipt that names its agent.** One that finds no agent waits in `earlyCollections`, keyed by agent id rather than `tool_use_id` because the receipt joining the two is exactly what hasn't been read. Dropped there it would spin for good.
- **Two gates, each safe only one way round.** A retrieval taken while the agent works answers `not_ready`/`running`, and a blocking call that hits its timeout reports that in `retrieval_status` while the agent carries on — so a task is decoded only under `success`, never on "the retrieval worked". And `CollectedTask.isOver` holds a **listed** set (`completed`, `failed`, `killed`, `cancelled`) rather than "anything not `running`": both go wrong on a status the CLI adds, and only the listed one goes wrong by leaving a finished row running.
- **First word wins.** A notification carries the CLI's tally and a collection carries none, so `bringAgentBack` skips a call that already has a result; settled by a collection, the row falls back to the two timestamps.
- **The id is the whole safety of it.** Only an agent this conversation launched settles. Transcripts get read back into sessions, and a result that merely quotes a `task_id` must land on nothing.

The socket half was never affected: `task_notification` still fires there, so `session.tasks` empties and the sidebar row is fine. The stuck one was the call inside the pane.

Code: `TranscriptDocument.agentCalls`, `earlyCollections`, `note(agentID:on:)`, `CollectedTask.isOver`, `bringAgentBack`, `RawToolResult`. Tests: `TranscriptDocumentTests`.
