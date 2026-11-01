# Stopping one agent (SDK 0.3.283, CLI v2.1.283)

Probe: `Sidecar/test/stop-agent-probe.ts` — starts a session with a background agent and stops it; the wire's own half is in `Sidecar/test/smoke.ts`.

`query.stopTask(taskId)` ends one agent and leaves the session working.

**Getting the id is the hard part.** The transcript's only `task_id` arrives in the `<task-notification>` when the agent is done, which is useless for stopping it. The id of a *running* agent comes only from the SDK's `task_started` stream event, which carries `tool_use_id` beside it. The transcript knows an agent only by the call that spawned it, so without that pairing there is a stoppable task and no row to put it on.

The host keeps the set of running tasks from the `task_started`/`task_notification` pair and sends it as a **level** (`session.tasks`), never as add/remove events — a missed event would leave a Stop on a row whose agent already came back. It replays the set on connect, since an agent that started before the app connected only ever produces the event that *removes* it. The SDK's `background_tasks_changed` is deliberately unused: it carries ids only, and its docs say not to correlate it with the event stream.

What settles the row afterwards differs by kind, and the app reads both:

- A stopped **foreground** agent's call comes back as an ordinary tool result.
- A stopped **background** agent's comes back as a `<task-notification>` with status `killed` — **not `stopped`, which is the word the socket uses for the same event**. `finishedAgents` reads anything that isn't `completed` as a failure, so both land. The turn hands itself back either way.

**A `stopTask` for an id the CLI has forgotten is accepted, not refused**, so a stale id fails silently. That is why nothing leaves the screen when the button is pressed: the row goes when the transcript says the agent stopped. Real refusals are a session the host isn't holding and an SDK without `stopTask`.

**`stopTask` can reject while the stop still lands.** Asked as the turn is handing itself back, the query closes first and rejects with `Query closed before response received`, and the agent stops anyway with the transcript recording `killed` (about one run in two). Don't read that rejection as a failed stop; the transcript settles it. Anything else thrown while the agent is still running is a real failure worth surfacing.

`backgroundTasks(toolUseId)` sits beside it and moves a foreground task to the background rather than ending it — see [A message can take the turn back from a foreground task](a-message-can-take-the-turn-back-from-a-foreground-task.md).

Code: `session.tasks`, `finishedAgents`, `HostedSession.stopTask`. Tests: `HostProtocolTests`, `HostSessionIndexTests`.
