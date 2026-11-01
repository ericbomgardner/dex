# A background agent's turns look like the parent working (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/interrupt-background-agent-probe.ts` — two sessions, one with a launched background agent and one with a resumed one, each interrupted while idle.

A background agent's own turns arrive on the parent's stream as ordinary `assistant`/`user` messages, marked only by `parent_tool_use_id`, and they keep arriving while the parent sits at the prompt. The only thing that ever says `idle` is a `result`, which a background agent never produces for the parent. So **only a message with no `parent_tool_use_id` moves the state** (`#drain` in `session.ts`). Read any message as the parent working and a session that launched an agent and ended its turn goes `running` on the agent's first word and stays there for good — nothing is left to correct it. An idle-with-work session reads as exactly that off `session.tasks`.

**`interrupt` on an idle session kills every background agent it has out**, launched or resumed, and the CLI says so in two places and not the third:

- The stream carries `task_notification` with status `stopped` within a few ms, so the task set empties.
- The agent's own file ends with `[Request interrupted by user]`.
- **The parent transcript records nothing** — no interruption (there was no turn) and no `<task-notification>` (the agent didn't finish). A launched agent's pending call in the pane has nothing to settle it and draws `running…` for the rest of the file. Known and unfixed; the only way in is Escape, which still goes to `SessionPane.interrupt` on an idle session.

**An interrupt mid-turn kills them too**, and there the parent file does say something: the turn's own `[Request interrupted by user]`, with each agent's file ending on the same line and no notification after. The session then tends to tell its user the agents are still working. `TranscriptDocument.stopLaunchedAgents` settles every launch still pending as stopped on an interruption record; a notification that lands later overwrites it, so an agent that survived still comes back on its own word.

**A resume is a task too.** `SendMessage` to a finished agent announces `task_started` with the *same* `task_id` and the SendMessage call's `tool_use_id`, so the set counts it under a call the pane has no agent row for. The pane finds it by the task id instead, which is the `agentId` the agent's own call came back with (`TranscriptFlow.marking`'s `agents`). `TaskStop` on that id after an interrupt answers `No task found`.

Probe caveats: the interrupt must go off a timer, since awaiting it inside the stream loop stops the loop reading and the agent's turns are never seen. The resumed run arms on a turn that called `SendMessage` (the CLI's own task-notification turn is a `result` too) and holds the interrupt until the agent's first turn has been seen. The agent's work must stay in the foreground with a long timeout (330s): an agent that backgrounds its own loop ends its turn, the CLI runs a task-notification turn on the parent, and the interrupt lands on that turn instead — a parent interruption and no stop for the agent. The probe refuses a run whose agent had already notified when the interrupt went out. The agent warms up with a 15s command first: its first call can reach the stream before the parent's `result`, and a single long call after it leaves nothing to see while the parent is idle (red three runs running on 2026-10-19).

Code: `#drain` in `Sidecar/src/session.ts`, `session.tasks`, `TranscriptDocument.stopLaunchedAgents`, `SessionPane.interrupt`, `TranscriptFlow.marking`.
