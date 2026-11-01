# How a session dies (CLI v2.1.283, SDK 0.3.283)

Probes: `Sidecar/test/host-death-probe.ts` — kills a host holding an open tool call and reads the end of the transcript. `Sidecar/test/resume-after-death-probe.ts` — kills one holding a foreground agent, resumes the session on a second host, and reads what the resume appended.

Two kinds of death, and the transcript tells them apart:

- A stop the user asked for goes through `interrupt` and writes `[Request interrupted by user]`.
- A host that goes away kills its sessions with SIGTERM — `shutdown()` calls `process.exit(0)`, and the SDK's own `process.on("exit")` cleanup kills every child CLI. Print/SDK mode writes no interruption record and no fake tool denials before it goes. So **a file that ends mid-tool-call with nothing after it is a session that died with its host.**

The damage is narrower than it sounds. A **shell** call in flight still gets resolved, because its child process is killed too and the exit code becomes the result (`Exit code 137`, an error result like any other). What gets stranded is a call whose answer was coming by a route that dies with the host — a background agent's `<task-notification>`, which `finishedAgents` waits for and never gets.

The pane answers that with **liveness, not the file**. `TranscriptItemView` carries `isLive` down to the row, and a pending call with nothing left to answer it reads `never came back` instead of `running…`. `isLive` is the session's pid, **not `isActivelyWorking()`**, which goes quiet 15s after the parent file stops being written and so reads a background agent as dead. A subagent's own turns take the flag from the row above rather than from the call's `isPending`, which is the same file-only reading one level down.

**A resume answers the stranded call** (since CLI v2.1.281). Before the resumed turn, the CLI writes an error `tool_result` for any call with none: `[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. …]`, then a `<synthetic>` `No response requested.` (see [Turns the CLI wrote itself](turns-the-cli-wrote-itself.md)). The model is told and says it doesn't know. `ToolResult.isUnrecorded` reads that text so the pane keeps saying `never came back` rather than counting a failure. `ToolCall.took` skips it too, since the result's timestamp is the resume's, hours after the death. Not measured for a background agent: its call already has its launch receipt, so there is nothing for this to answer, and its missing notification presumably stays missing. No hidden `Continue` message is written.

`TranscriptStanding.owesTurn` still reads such a file as owing a turn; the `live &&` gate in `SessionStore` is what keeps that off archived rows.

Code: `TranscriptItemView.isLive`, `ToolResult.isUnrecorded`, `TranscriptText.isUnrecordedOutcome`, `finishedAgents`, `TranscriptStanding.owesTurn`, `SessionStore`, `shutdown()` in `Sidecar/src/host.ts`.
