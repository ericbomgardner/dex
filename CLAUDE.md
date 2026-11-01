# Dex

A macOS app for running and reading Claude Code sessions. It is a
`main.swift` (`Sources/DexCode`) over `Sources/DexUI`, with
`Sources/DexCore` for everything testable. It talks over a socket to
its own Node host (`Sidecar/src`) that runs each session through the Agent SDK.
The host outlives the app on purpose. The app reads transcripts straight off
disk.

```bash
(cd Sidecar && npm install)     # the host's dependencies, the SDK and its CLI among them
swift build && swift test
(cd Sidecar && npm run typecheck && npm test)   # the host type-checks; offline unit tests, no key
(cd Sidecar && npm run smoke)   # the host can still drive the bundled CLI
Scripts/make-app.sh             # builds the app into .build
```

## Claude Code is an undocumented dependency

Almost everything Dex reads from Claude Code — transcript records, SDK events,
CLI output — is observed behaviour, not a documented interface, and it changes
without being announced. What's known is in `docs/claude-code/`, one file per
fact, each headed with the CLI/SDK version it was checked against and naming
the probe (`Scripts/*-probe.py`, `Sidecar/test/*.ts`) that re-checks it.

- **Before changing how the app reads or drives something from Claude Code,
  read its file there.** Rules that look over-engineered usually aren't, and the
  file says why.
- If you find the CLI doing something new, add or update a file. The header
  must keep the `# Title (CLI vX.Y.Z, SDK X.Y.Z)` shape — `Scripts/maintainer/changelog-watch.py`
  parses it.
- **Never loosen a probe to make it pass.** A probe that passes by measuring
  less is worse than a red one.
- App sessions run the SDK's bundled `claude`, not the Terminal's. Ask
  `HostLocation.bundledCLI`, never `ClaudeExecutable.resolve()`. A `Scripts/`
  probe gets it from `bundled_cli()` in `Scripts/claude_cli.py`.
- A transcript is a log in flush order, not a conversation. Test with records in
  the order the CLI really writes them; fixtures in conversation order pass
  either way.
- Nil from the CLI usually means "hasn't said", not "none". Keep the two apart.

Index:

- [The CLI updates itself](docs/claude-code/the-cli-updates-itself.md) — local version is a floor; changelog bookmark, `--seen`, `CLIVersion`
- [Which CLI the app's sessions run](docs/claude-code/which-cli-the-apps-sessions-run.md) — bundled vs Terminal CLI, SDK pin, `HostLocation.bundledCLI`, `HostSDK`
- [An API key outranks the stored login](docs/claude-code/api-key-over-login.md) — `apiKeySource`; `apiKeyHelper` over a `KeyFile`, not env, which children inherit; `apiKey` on `start` and as a capability; `SessionCredential`, `KeyLookup`, `APIKeyFile`
- [Slash commands](docs/claude-code/slash-commands.md) — how `BuiltInCommands.swift` is scraped from `/help`
- [User commands follow the config dir](docs/claude-code/user-commands-follow-the-config-dir.md) — `CLAUDE_CONFIG_DIR` replaces `~/.claude` for commands and skills; `SlashCommands.all(configDirectory:)`
- [Most of what it ships cannot be typed at a hosted session](docs/claude-code/most-of-what-it-ships-cannot-be-typed-at-a-hosted-session.md) — `slash_commands` as a filter; nil vs empty in `SlashCommands.marked`
- [A result can be written before its call](docs/claude-code/a-result-can-be-written-before-its-call.md) — `TranscriptDocument.early` and `settle`
- [A transcript can repeat its history](docs/claude-code/a-transcript-can-repeat-its-history.md) — replayed uuids relaunch finished agents; both readers skip a uuid already read
- [Subagent results](docs/claude-code/subagent-results.md) — foreground counts, background receipt and task-notification; `bringAgentsBack`
- [A subagent's report arrives as a message](docs/claude-code/a-subagents-report-arrives-as-a-message.md) — `SubagentHandback`, peer delivery, `RawOrigin`, `handbackReport`; an interim notice, then one naming only the task, `interimAgents`
- [Collecting an agent instead of waiting for it](docs/claude-code/collecting-an-agent-instead-of-waiting-for-it.md) — removed `TaskOutput`, still read from old files
- [Stopping one agent](docs/claude-code/stopping-one-agent.md) — `stopTask`, `task_started` ids, `session.tasks` as a level
- [A message can take the turn back from a foreground task](docs/claude-code/a-message-can-take-the-turn-back-from-a-foreground-task.md) — `backgroundTasks` on every send
- [A background shell command is a task too](docs/claude-code/a-background-shell-command-is-a-task-too.md) — `local_bash` tasks, `SessionRowModel.runningTasks`
- [A background agent's turns look like the parent working](docs/claude-code/a-background-agents-turns-look-like-the-parent-working.md) — `parent_tool_use_id` gate in `#drain`, `stopLaunchedAgents`
- [A watcher is a task the CLI cannot tell from a shell](docs/claude-code/a-watcher-is-a-task-the-cli-cannot-tell-from-a-shell.md) — Monitor, `HostTask.isWatcher`
- [The CLI's own idle waits for its agents](docs/claude-code/the-clis-own-idle-waits-for-its-agents.md) — registry `status`, result still ends the turn
- [Ending a session](docs/claude-code/ending-a-session.md) — `reapable`, `touched`, `#retired`, `forget`
- [How a session dies](docs/claude-code/how-a-session-dies.md) — SIGTERM leaves no record; `isLive`; a resume answers the stranded call, `ToolResult.isUnrecorded`
- [Todo tools are gone from the models we run](docs/claude-code/todo-tools-are-gone-from-the-models-we-run.md) — `ToolCall.todoSummary` kept for old files
- [A subagent's own transcript](docs/claude-code/a-subagents-own-transcript.md) — flat `subagents/` dir, `SubagentTranscript.locate`, `keepsSidechain`
- [The task id is the agent's transcript name](docs/claude-code/the-task-id-is-the-agents-transcript-name.md) — `runningAgents`, `spotted`
- [Messages sent while a session is working](docs/claude-code/messages-sent-while-a-session-is-working.md) — absorbed vs queued; `absorbedMessage`, `queued`, `heard`
- [Side questions](docs/claude-code/side-questions.md) — `/btw` as `Query.askSideQuestion`; no record, no tools, `history`; `side` request, `Aside`
- [A message can cut in](docs/claude-code/a-message-can-cut-in.md) — every hosted send is `backgroundTasks` then `priority: "now"`; `"now"` alone kills a foreground agent; a cut throws away every call in the reply, so it waits out a reply writing one; it also kills a call still waiting on hooks or the auto classifier, so it waits for a task or a result too; `#cutIn`, `#replyWritten`, `#callsSettled`
- [What a reply is writing](docs/claude-code/what-a-reply-is-writing.md) — the file gets a block only once it's finished; partial messages; reply text not streamed, since text after a narration note is held back (`narration-stream-probe`); `message_start` → `running`; launched agents left out of `TranscriptFlow.waitedOn`
- [The CLI's own tool summaries](docs/claude-code/the-clis-own-tool-summaries.md) — `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES`: a Haiku label per reply, ~2s late, never in the file; `agentProgressSummaries` repeats `description`
- [Messaging one session from another](docs/claude-code/messaging-one-session-from-another.md) — `SessionRegistry`, `FleetSession.address`, landing shapes
- [What ListAgents shows of a session](docs/claude-code/what-listagents-shows-of-a-session.md) — registry name only; `derived`/`user`/`auto`, resume keeps only a `custom-title`; `SessionNaming`, `title` on resume, `list_sessions`
- [A session can start another](docs/claude-code/a-session-can-start-another.md) — `start_session` MCP tool, `launch`/`launched` relay to the local app, `origin.parent`
- [The models the picker offers](docs/claude-code/the-models-the-picker-offers.md) — `ModelAliases`, `SessionModel.classes`
- [Picker row names](docs/claude-code/picker-row-names.md) — `ModelReadout.name(in:)`
- [A Thought that was never a Thought](docs/claude-code/a-thought-that-was-never-a-thought.md) — narration blocks, `NarrationSignature`
- [Which model is answering](docs/claude-code/which-model-is-answering.md) — `TranscriptDocument.model`, `ModelName`
- [Turns the CLI wrote itself](docs/claude-code/turns-the-cli-wrote-itself.md) — `<synthetic>`, `isApiErrorMessage`, `TranscriptNotice`
- [Output style and effort](docs/claude-code/output-style-and-effort.md) — flag-layer settings, `max` cap, `resolveSettings`, `HostDefaults.effort(forModel:)`
- [Permission modes and plans](docs/claude-code/permission-modes-and-plans.md) — `auto`; asked is not got; `PermissionModes.recognises`, `proposedPlan`
- [Whether a session is working](docs/claude-code/whether-a-session-is-working.md) — `TranscriptStanding`, `isInterruption`
- [The system prompt](docs/claude-code/the-system-prompt.md) — omitted `systemPrompt` means none
- [Which model a session's subagents run on](docs/claude-code/which-model-a-sessions-subagents-run-on.md) — resolver order; Dex sets no `CLAUDE_CODE_SUBAGENT_MODEL`
- [What a subagent actually ran on](docs/claude-code/what-a-subagent-actually-ran-on.md) — `SubagentTranscript.identity`
- [Resume](docs/claude-code/resume.md) — same file, silent until prompted; `HostedArchive`
- [Row title and subtitle](docs/claude-code/row-title-and-subtitle.md) — `ai-title`, `SessionDigest`, `TranscriptText.cleaned`
- [Renaming a session](docs/claude-code/renaming-a-session.md) — `custom-title` outranks `ai-title`; `Query.renameSession` live, exported `renameSession` otherwise
- [Which transcripts Dex ran](docs/claude-code/which-transcripts-dex-ran.md) — `entrypoint` `sdk-ts`/`sdk-cli`; `TranscriptSearch`, `HostedArchive.adopt`
- [When that transcript turns up](docs/claude-code/when-that-transcript-turns-up.md) — `SessionStore.awaitTranscripts`, `TranscriptWatcher`
- [A transcript records each request](docs/claude-code/a-transcript-records-each-request.md) — `api-request-shape`/`-blob`/`api-request`; a blob repeats merged results unstamped, only `user`/`assistant` are turns; `McpCallOutcome.read`
- [A file too large for the request is dropped](docs/claude-code/a-file-too-large-for-the-request-is-dropped.md) — 24MiB of documents, oldest swapped for `[media removed: request limit]` silently; only the `api-request-blob` shows it; `wasDropped`, `MEDIA_BRIEF`; `pages` needs poppler
- [Compaction](docs/claude-code/compaction.md) — five-record shape, `~postTokens`, `compacting` state
- [What a session is carrying](docs/claude-code/what-a-session-is-carrying.md) — context badge, price matching, `SessionContext`
- [Answering a question](docs/claude-code/answering-a-question.md) — `answers`, `annotations`, fragile `response`; `decisionFor`
- [A session that drives the screen](docs/claude-code/a-session-that-drives-the-screen.md) — PreToolUse hook, `DEX_DRIVES_SCREEN`, `ScreenTakeoverPolicy`; a Monitor's command hits the Bash hook, its ask arrives as `Monitor`
- [How a session's MCP servers are doing](docs/claude-code/how-a-sessions-mcp-servers-are-doing.md) — `mcp_servers` on init, `mcpServerStatus()`, `session.mcp`, Settings → MCP servers
- [An MCP server that drops says so only in its calls](docs/claude-code/an-mcp-server-that-drops-says-so-only-in-its-calls.md) — status stays `connected`; transport-failure texts, `McpCallOutcome`, `McpTroubleChip`
- [Reconnecting and logging in to an MCP server](docs/claude-code/reconnecting-and-logging-in-to-an-mcp-server.md) — `reconnectMcpServer` re-reads config, untyped `mcpAuthenticate`; `mcpReconnect`/`mcpLogin`, host retries (`#retryMcp`), `McpTroubleChip`, `mcpReconnected`

`Scripts/maintainer/transcript-render.py` is a second, stdlib-only reader of the
transcript format. Nothing probes
it, so a transcript change the pane handles needs handling there too; its tests
are `Scripts/maintainer/transcript-render-test.py`.

