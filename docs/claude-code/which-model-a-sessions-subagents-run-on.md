# Which model a session's subagents run on (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/subagent-model-probe.ts` — real sessions that spawn agents and read the agent's own transcript.

Dex doesn't set `CLAUDE_CODE_SUBAGENT_MODEL`: a session's agents run on what the call or the agent names, or on the session's own model.

**The variable is a default, not a floor.** The CLI's subagent resolver reads `tool` > `frontmatter` > `env` > `inherit`: an agent that names its own model keeps it, and the variable decides only for agents that never chose. Set it again only per session, and without `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, which makes it an override: an agent pinned to `model: sonnet` should keep Sonnet.

Never in `~/.claude/settings.json`: a settings entry reaches every session on every model.

**`env` replaces the subprocess environment rather than adding to it**, so the host spreads `process.env` into it whenever it passes one; without that a session starts with no PATH and no credentials.

The per-call `model` is honoured in both directions — an Opus session's agent asked for `haiku` comes back Haiku, asked for `fable` comes back the current Fable.

Probe caveats:
- Read the model from the subagent's own transcript; a subagent asked which model it is can't answer reliably, and its text reaches the stream only under `forwardSubagentText`.
- Ask for the `Agent` tool **by that name** — a session asked for the `Task` tool spawns nothing and reads as a default that held.
- Every run must name three different models (session, env, ask): any two matching leaves the reading unable to say which branch answered.

Code: `session.ts` (`env` on `query()`). Tests: none beyond the probe; see [What a subagent actually ran on](what-a-subagent-actually-ran-on.md) for reading the result back.
