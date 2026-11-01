# Todo tools are gone from the models we run (CLI v2.1.295)

No probe: a surface going quiet, and a probe can only confirm an absence it was already told about.

`TodoWrite` and the `Task*` tools are not offered on Opus 4.8, Sonnet 5, Fable 5, Mythos 5, Haiku 5.5 or newer — every alias in `ModelAliases`, `haiku` included since it moved to Haiku 5.5 (CLI 2.1.293). Haiku 4.5, asked for by its full id, still gets `TaskCreate`, `TaskGet`, `TaskList` and `TaskUpdate` in `system`/`init`. `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` on a session's env brings them back.

- `ToolCall.todoSummary` and the pane's checklist icon still work and stay: old transcripts and Haiku 4.5 sessions still carry the records. They just won't be reached on the models the app runs.
- There is no `TaskCreate` now. `Sidecar/test/subagent-model-probe.ts` asks for the `Agent` tool by name for that reason; a comment there still describes the old reach for `TaskCreate` and is out of date.

Code: `ToolCall.todoSummary`, `ModelAliases`.
