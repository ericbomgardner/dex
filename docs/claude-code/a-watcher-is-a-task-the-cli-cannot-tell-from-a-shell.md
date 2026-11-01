# A watcher is a task the CLI cannot tell from a shell (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/monitor-task-probe.ts` — a session puts a `Monitor` on an empty file, the probe appends a line, then stops the watcher.

The `Monitor` tool — a `tail -f` on a log, a command re-run until it matches — registers a background task with `task_type: "local_bash"`, `is_backgrounded: true` and the Monitor call's own `tool_use_id`. **Nothing on the event says it is a monitor**: it is word for word the announcement a backgrounded Bash makes. The turn's `result` arrives with the watcher still out, and the CLI's own registry says `idle` for the whole stretch, since `local_bash` is left out of its "running background tasks" (see [The CLI's own idle waits for its agents](the-clis-own-idle-waits-for-its-agents.md)).

**A watcher is not work.** It is the session waiting for something to happen. Counted like a shell, a session that had reported its results and gone quiet spins for the full life of a `tail -f` that never exits on its own. When the watched thing happens, the CLI runs a real turn on it — a `user` record and a `result`, with nobody at the keyboard — so the row moves through the ordinary state and needs no reading of its own. That turn never appears on the SDK stream as a `user` message, only as the `result` that closes it.

The only thing that separates a watcher from a shell is the name of the tool call it came from. The host keeps the tool name of every `tool_use` block it streams and sends it beside the task as `tool` (`RunningTask.tool`). `HostTask.isWatcher` reads `Monitor`; `HostSessionIndex` leaves watchers out of the `runningTasks` count that spins the row while keeping them in the set the pane stops from. **Nil is a host older than the field and reads as work** — the side that fails loud.

Stopping one: `stopTask` on a watcher resolves, and `task_updated` (`killed`) and `task_notification` (`stopped`) follow within ms carrying the Monitor call's `tool_use_id`. The transcript records the stop only as an `enqueue` of a `<task-notification>` with status `killed`, dequeued a few seconds later with no turn written. A monitor's event notification carries no `<tool-use-id>`; the stop's does.

Every watch has a deadline — 30 minutes at most, 10 in a `-p` run — after which the CLI tells the model to re-arm it. There is no `persistent` flag and nothing here reads one. The model reaches `Monitor` only through `ToolSearch`, since its schema is deferred; the probe reports that rather than failing on it.

Code: `RunningTask.tool` (`Sidecar/src/session.ts`), `HostTask.isWatcher`, `HostSessionIndex`, `ToolCall.isWatcher`. Tests: `HostProtocolTests`, `HostSessionIndexTests`.
