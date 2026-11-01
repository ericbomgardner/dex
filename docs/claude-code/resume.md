# Resume (SDK 0.3.283)

Probe: `Sidecar/test/resume-probe.ts` — resumes a real session and asks it what it remembers; the app's half is in `Sidecar/test/smoke.ts`.

A session dies with its host (in-process, no state on disk). What survives is the transcript plus what the app recorded in `HostedArchive`.

Three facts about `query({ resume })`:
- It **continues the same `<session-id>.jsonl`** rather than forking a new file. A fork would leave every reopened row bound to a transcript that stops mid-conversation.
- The resumed session actually remembers the conversation (asked, not assumed).
- **It stays silent until handed a prompt** — no `system/init`, nothing on the socket. That silence is why an archived row is not a live session and opening one doesn't start it: the row is drawn from `HostedArchive`, the pane reads the file, and sending a message is what wakes the conversation. The probe asserts the silence, so an SDK that starts announcing early fails there rather than in the app. Early announcement would be an option to take up deliberately (rows going live on open), not a bug.

Handed a prompt, `init` is not always the first thing it says: a `/compact` sends `compacting` first and `init` only when done, so the host announces a resume on its first message of any kind ([Compaction](compaction.md)).

The app names the resume key: rows are keyed by it, and a host handing back a fresh one would list a resumed conversation as a stranger. A key already running is refused, since two sessions under one key leaves one unreachable. A resume also replays the recorded effort and output style and forces `auto` — see [Output style and effort](output-style-and-effort.md) and [Permission modes and plans](permission-modes-and-plans.md).

Code: `HostedArchive`, `session.ts` (`resume` on `query()`). Tests: `HostedArchiveTests`, `Sidecar/test/smoke.ts`.
