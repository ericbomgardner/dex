# Messaging one session from another (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/cross-session-message-probe.ts` — two hosted sessions, one sends to the other in each receiver state.

`SendMessage` reaches a session by the name `ListAgents` prints, and **that name is in no transcript**. It is generated per process — the cwd's folder name plus two random hex characters, `garden-9d` — and lives only in the CLI's own registry, `~/.claude/sessions/<pid>.json`, which every session writes itself, hosted ones included (`entrypoint: sdk-ts`), with `sessionId` beside it. The fleet file's `name` is the transcript title, and sending to that is refused (`No agent named … is reachable`). `SessionRegistry` reads the registry by session id and `FleetSession.address` carries the name; a record whose pid is gone is skipped, since a crash leaves one behind. The `[ref]` beside a name is the first six hex characters of sha256 over `session:` plus the socket path, wanted only when two rows share a name.

The name is the folder plus hex only until something names the session; what does is in [What ListAgents shows of a session](what-listagents-shows-of-a-session.md).

`CLAUDE_CODE_SESSION_NAME` would name a session outright and is deliberately not sent: the CLI keeps derived names unique per machine, and titles have spaces and repeat.

**`success: true` from `SendMessage` is not a delivery receipt.** With nothing set the CLI delivers only between sessions of the same permission class. Every session the app starts is `auto`, so they reach each other. Across a mismatch (a `bypassPermissions` terminal sending to an app session) the message is held for an approval a headless session cannot give, expires, and is dropped — nothing in the receiver's transcript, and a headless sender is told the message was held. `settings.crossSessionInbound: "accept"` beats parity through the same flag layer as `effortLevel`; pinned by the probe and deliberately not sent, since it would take messages from any class.

Three ways a message lands, by what the receiver is doing:
- **Idle with its stream open**: a `user` turn under `isMeta` with plain-string content, and the session runs a turn on it unprompted — a row can move with nobody at the keyboard.
- **Busy in a tool call**: absorbed — `enqueue`, `attachment` of type `queued_command` with `commandMode: "prompt"`, `remove` with `absorbed_mid_turn` — and **no user turn written** (the shape in [Messages sent while a session is working](messages-sent-while-a-session-is-working.md)).
- **Parked on a question or permission prompt**: enqueued, shown to the model only once the prompt is answered. **A message cannot unblock a parked session.**

Both landing shapes carry `origin: {kind: "peer", name, body, fromMode}`, and the document keys on that rather than the wrapper prose: a peer's `isMeta` turn is kept where every other `isMeta` turn is dropped, and both shapes draw as a user turn named for the sender. A message from one of the session's own agents carries `from` and `senderTaskId` as the agent id, and `name` is absent or (from CLI 2.1.286) the agent's type, which doesn't tell two agents apart; a `SendMessage` back to it puts the same id in `to`. The app names both sides for the brief on the launch whose `toolUseResult.agentId` matches (`TranscriptFlow.agentBriefs`); `transcript-render.py` draws only the inbound side as a message, and names it the same way (`agent_purposes`). A hand-back is the same shape and is dropped — see [A subagent's report arrives as a message](a-subagents-report-arrives-as-a-message.md).

Probe caveats:
- The CLI blocks a standalone `sleep`, so a "busy" receiver built on one is idle and the run passes by measuring nothing. Use a `ping`, gated on the send landing before the command returns.
- Don't change the sender's mode to quiet the SDK's `CLAUDE_SDK_CAN_USE_TOOL_SHADOWED` warning under `bypassPermissions` (it is wrong about `AskUserQuestion`, which still routes through `canUseTool`): that hands the message to the inbound gate and lets the ask take credit for the drop.

Code: `SessionRegistry`, `FleetSession.address`, `TranscriptDocument` (peer `origin`). Tests: `SessionRegistryTests`, `FleetSnapshotTests`, `TranscriptDocumentTests`.
