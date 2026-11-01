# Renaming a session (CLI v2.1.311, SDK 0.3.311)

Probe: `Sidecar/test/rename-probe.ts` — renames a running session both ways, runs more turns, then renames it after it has closed.

A user's name for a session is its own record, `{"type":"custom-title","customTitle":"…"}`, and it outranks the CLI's `ai-title` wherever both are written. The CLI keeps writing `ai-title` after a rename and re-asserts the two together, custom first, so reading from the end the CLI's own title comes first. `SessionDigest` keeps the two apart (`renamed`, `named`) and the rename wins; a window holding only a fresh `ai-title` merges over the earlier rename rather than replacing it.

The host renames by transcript id, through one of two routes:

- **A session it is running** goes through `Query.renameSession(title, sessionId)`. Undocumented on `Query`; it sends the `rename_session` control request with `source: "host"`, which the CLI counts as a user rename and writes down at once.
- **Anything else**, including a Terminal session or a closed one, goes through the exported `renameSession(sessionId, title)`, which appends the record to the file. Searched across every project directory, because the session's folder may since have moved.

An append made behind a running CLI's back survives its next turn: the probe checks it stays the newest `custom-title`. So the second route is safe for a live session too; the first is preferred because it moves the CLI's in-memory title as well.

**A name sent with `start`** goes the first route too, once, after the first `session.init`. The SDK's `query()` takes no name, so without this a background watcher's "CI fail: feature/foo" lived only in the host's memory and the row showed the CLI's title. Skipped on a resume: the app resumes with the name it last read off the file, and writing that down would freeze the CLI's title as a rename. Probe: `Sidecar/test/start-name-probe.ts`, which also checks `session.init` carries the name and origin. In its run no `ai-title` was written at all once the `custom-title` was there.

A live rename also becomes the name `ListAgents` shows, and the app renames a session started without a name once it has a title; a resume passes the name as the SDK's `title` option instead, which writes nothing. Without the option a resume takes the newest `custom-title` back. See [What ListAgents shows of a session](what-listagents-shows-of-a-session.md).

The SDK refuses an empty title, and so does the host. An archived row's transcript is never re-read, so on a successful reply the app also renames its `HostedArchive` entry.

Code: `SessionDigest.renamed`, `HostRequest.rename`, `HostedSession.rename`, `SessionRow` (Rename… in the row's context menu). Capability `rename` on the welcome; a host too old to have it leaves the menu item disabled. Tests: `SessionDigestTests`, `HostProtocolTests`.
