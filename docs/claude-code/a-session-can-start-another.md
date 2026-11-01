# A session can start another (CLI v2.1.296, SDK 0.3.296)

Probes: `Sidecar/test/start-session-tool-probe.ts` — one haiku session, a stand-in launcher; `Sidecar/test/launch-relay-probe.ts` — a real host, two stand-in apps.

Every hosted session gets an in-process MCP server, `dex`, with `start_session` (`cwd`, `prompt`, optional `name`) and `list_sessions` (see [What ListAgents shows of a session](what-listagents-shows-of-a-session.md)). The session sees it as `mcp__dex__start_session`, deferred behind tool search like any MCP tool; a model that is told the name finds it.

The host doesn't start the session itself: the model and effort are decided in the app, and a session started around them would run on bare CLI defaults. So the call becomes a `launch` event sent to one client — the newest whose `hello` said `launches: true`.
The app starts it through `SessionStore.launchRequested`, with the composer's picks resolved against that folder's defaults and `origin.parent` set to the asking session's key, then answers `launched` with the key or a reason. The tool result says which. No app connected, no answer in 30s, or a cwd that isn't an absolute folder on this Mac each come back as an error result rather than a hang.

- **The tool is pre-approved with a bare `allowedTools` entry**, so it never reaches `canUseTool` and never asks, in any mode. The SDK says so on stderr (`CLAUDE_SDK_CAN_USE_TOOL_SHADOWED`) at every session start; that warning is the intended behaviour, not a fault.
- **`dex` is dropped from the session's MCP readings** (`mcpReadings`): Settings → MCP servers is about the user's servers, and this one is always connected.
- **`mcpServers` passed to `query()` adds to the servers the settings files name**; it doesn't replace them. Checked by hand (no probe): a session in a folder with a local-scope server reported that server both with and without `dex` attached.

A spawned row shows "↳ <parent title>" and clicking it focuses the parent. The origin is kept in `HostedArchive`, so it survives a resume.

Code: `dexServer`, `START_SESSION_TOOL` (`dex-server.ts`), `launch`/`settleLaunch` (`host.ts`), `HostLaunch`, `HostRequest.launched`, `SessionOrigin.parent`. Tests: `HostProtocolTests`.
