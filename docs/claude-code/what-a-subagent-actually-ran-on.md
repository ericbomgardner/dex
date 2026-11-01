# What a subagent actually ran on (CLI v2.1.300, SDK 0.3.300)

No probe: the fields are in every subagent transcript on disk, and [Which model a session's subagents run on](which-model-a-sessions-subagents-run-on.md) is what puts a model there to check.

Each `assistant` record in a subagent's file names its model and effort in two places: `message.model` inside the message, and `effort` at the **top level** of the same record. Reading the message alone answers only half. Haiku 4.5's files carry no `effort` (a model with no level); Haiku 5.5's do — `medium` in the CLI 2.1.293 files on disk. A `perTurnEffort` sometimes sits beside or in place of `effort`; unread so far.

Why the row is worth having: a subagent whose first call 404s falls down the session's fallback chain instead of dying, so a model id that goes away is a quiet demotion, and this row is the only thing that notices. **Nothing fills a missing effort in from the session** — that would be the app reporting its own setting back to itself.

Read from the **front** of the file — the only transcript read here that isn't a tail — because the wanted turn is the first. **The front is not small, and no fixed slab stays right**: an agent's file opens with an `attachment` of type `instructions` carrying the session's CLAUDE.md and memory (hundreds of KB), plus a `prompt_snapshot`, and the `instructions` payload tracks the size of the config file. So `SubagentTranscript.identity` reads `identityWindow` at a time up to `identityCeiling` (1M) and stops at the first turn; past the ceiling the row says nothing rather than reading more. A fixed slab would go quiet on large agents with nothing to say so. Since CLI 2.1.300 the request records come before the first turn too ([A transcript records each request](a-transcript-records-each-request.md)): across this machine's first 27 agents written by it the first turn sat at 95k median and 101k at most, so the median agent now takes two windows, still a tenth of the ceiling.

The first turn naming a model is the only one that needs to; a `<synthetic>` turn is skipped the same way `TranscriptDocument.model` skips it.

Code: `SubagentTranscript.identity`, `SubagentIdentity`, `ToolCallRow.tally` (draws it ahead of the CLI's counts). Tests: `SubagentIdentityTests`.
