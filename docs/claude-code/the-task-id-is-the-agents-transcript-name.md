# The task id is the agent's transcript name (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/agent-file-probe.ts` — starts a session that launches an agent and reads the agent's file while it runs.

`task_started`'s `task_id` is the stem of `subagents/agent-<id>.jsonl`. The file is readable within a fraction of a second of the announcement, while the agent is still running, and every record in it names the same id as `agentId` — the field the result finally carries. **Nothing documents these as the same id; they just match.** That is why it is pinned: a rename on either side would announce nothing.

What depends on it: a foreground agent's own name arrives only beside its result, so for its whole run the row had nothing to open. The pane hands `session.tasks` down as `runningAgents`; the row prefers the transcript's word and falls back to the host's, and **keeps an id once seen (`spotted`)** — the host drops a finished task the moment it hears, a beat before the transcript's next pass carries the result's `agentId`, and without that memory an open conversation folds back into launch JSON for the gap.

Hosted live sessions only, by construction: a session found on disk has no host holding its tasks and reads the id off the result, as before.

Code: `SessionPane.runningAgents`, `TranscriptPane` (`runningAgents` environment, `spotted`), `session.tasks`. Tests: none; the probe is the check.
