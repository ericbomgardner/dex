# The CLI's own idle waits for its agents (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/session-state-probe.ts` — three sessions launching one background task each, reading the CLI's registry record after the turn's result.

With a background **agent** out, the CLI's own state stays `busy` after the turn ends, until the agent is back and the CLI's task-notification turn has run. That state has two surfaces, and the host reads neither:

- `status` in `~/.claude/sessions/<pid>.json` — `busy` or `idle`. It is what another session's `ListAgents` shows. **Absent on a record an older CLI wrote, which is a CLI too old to say, not an idle session.**
- `system/session_state_changed`, typed by the SDK for the same state. **A streaming-input session never receives one**, so on the stream there is nothing new to read.

**The turn's `result` still arrives when the model is done**, well ahead of the agent's notification. So the `result` → `idle` reading in `#drain` holds, and everything built on it holds with it: the row draws idle-with-work off `session.tasks`, and the session-level Stop stays off while only background work is out.

**A background shell holds nothing.** The CLI's "running background tasks" leaves `local_bash` out, so a session with only a backgrounded command out says `idle` at once — see [A background shell command is a task too](a-background-shell-command-is-a-task-too.md), where the app's task set is what keeps the row spinning.

`CLAUDE_CODE_BG_TASKS_REPORT_RUNNING=0` restores the old reading for agents. The app sends nothing here, since what it draws comes from the task set. Unused so far: the registry's `status` is the CLI's own word for a row, and `SessionRegistry` reads only `pid`, `sessionId` and `name`.

The probe is the alarm for the day the `result` itself starts being held, or the state starts arriving on the stream. Probe caveats: read the registry at a fixed offset after the result rather than polling for the wanted value — polled, it matches the `busy` written before the result and reads the change as present. Read it while the session is alive, since the CLI deletes the record on exit. And take the reading with an agent, not a backgrounded `sleep`, which measures the `local_bash` exclusion instead.

Code: `#drain` in `Sidecar/src/session.ts`, `session.tasks`, `SessionRegistry`.
