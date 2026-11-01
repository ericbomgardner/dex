# Whether a session is working (CLI v2.1.227)

No probe: pinned by `TranscriptStandingTests` against the interruption record shape.

**Not from host state alone.** The state updates when the session reports, not when it is handed a turn, so the spinner would sit still through the opening think. The transcript answers first: your message is appended as you send it, and `TranscriptStanding` reads the end of the file — a user turn last means unfinished work; an assistant turn last means done only if it left no tool call running. Subagent turns are skipped; the call that spawned them stands in for them.

The transcript is consulted **only once the state says the session has stopped**, since stopping is the one thing the state is late about. Blocked comes from state alone — a pending question and a running tool call look identical in the file.

**A stopped turn is the one user turn that isn't unfinished work.** The CLI writes `[Request interrupted by user]` — or `…by user for tool use` where it landed on a call — as an ordinary user record: one text block, no `isMeta`. Read at face value, an interrupted session spins for as long as it sits there. `TranscriptText.isInterruption` tells them apart, and is asked **only of a record that is nothing but the note** — quoting the line back at a session is a message like any other.

Code: `TranscriptStanding`, `TranscriptText.isInterruption`. Tests: `TranscriptStandingTests`.
