# A background shell command is a task too (CLI v2.1.312, SDK 0.3.312)

Probe: `Sidecar/test/background-bash-probe.ts` — one session backgrounds a shell command; `Sidecar/test/foreground-task-probe.ts` pins that the task set empties on every foreground path.

`Bash(run_in_background: true)` announces itself with the same `task_started` an agent does — `task_type: local_bash`, the Bash call's `tool_use_id` beside it — and settles with the same `task_notification`.

**The launch receipt ends the turn.** The state goes `idle` and the transcript reads as finished while the command still has minutes to go. `session.tasks` is the only thing that says otherwise, and a backgrounded command writes nothing to the transcript while it runs — **for that stretch the task set off the socket is the liveness signal, not the file.** `SessionRowModel.runningTasks` keeps an idle-with-work row drawing the working spinner, exempt from the 15s quiet-dim.

What keeps the count from wedging is that the set empties on every path:

- A quick foreground Bash (`echo hi`) announces no task at all; a long one (75s) announces one and settles it. "Foreground Bash is invisible to the task set" is true only of the quick ones.
- A foreground Bash that outlives its `timeout` is moved to the background, not killed (the result says so since CLI 2.1.311): the same task gets a `task_updated` with `is_backgrounded: true`, the turn's `result` follows, and the command's own end settles it by `task_notification` under the same task id. So it is a backgrounded command from then on — still in the set, its Bash call answered, which is exactly what `TranscriptFlow.backgroundWork` puts on the strip. Pinned by the fourth run of `foreground-task-probe.ts`.
- A foreground agent settles by `task_notification` whether it finishes or is stopped from outside. `task_updated` lands first either way and is not the final word. The socket's status for a stop is `stopped`; the transcript's is `killed`.
- Tasks the host can't name a `tool_use_id` for are **dropped, not counted**: the SDK registers ambient housekeeping with no tool call (`skip_transcript`), and counting one would spin a row with nothing to explain it.

Two temptations, both refused:

- The task's `.output` file mtime is **not** liveness — it freezes for the whole run when the command's output goes elsewhere.
- The session-level Stop stays off while only background work is out: `interrupt` cuts a turn and there is no turn. A message *sent* while the work is out starts a turn, though, and `owesTurn` outranks the waiting reading for exactly that stretch.

See also [The CLI's own idle waits for its agents](the-clis-own-idle-waits-for-its-agents.md): the CLI's own state leaves `local_bash` out, so it calls the session idle the whole time.

Code: `session.tasks`, `SessionRowModel.runningTasks`, `TranscriptStanding.owesTurn`, `HostSessionIndex`. Tests: `HostSessionIndexTests`, `HostRowsTests`, `ActivelyWorkingTests`.
