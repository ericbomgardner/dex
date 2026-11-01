# What ListAgents shows of a session (CLI v2.1.311, SDK 0.3.311)

Probe: `Sidecar/test/rename-probe.ts` — reads the session's registry record after each kind of rename and after two resumes, then resumes a second session that has only the CLI's titles.

A peer row in `ListAgents` is `name [ref] · kind · status · started N ago`, and nothing else: no folder, title, branch or session id. (Read off the CLI's formatter; a tmux name and a "says it was … until" note are the only extras.) The name is the record's `name` in `~/.claude/sessions/<pid>.json`, the CLI's registry, and its `nameSource` says where it came from:

- **`derived`**: the folder name plus two hex characters (`garden-67`). Every session starts here, and a hosted one stays here: the CLI's own `ai-title` reaches the registry only on the Remote Control path, and not on a resume either.
- **`user`**: a live rename, `Query.renameSession` (the `rename_session` control request). It also writes a `custom-title`, and the CLI generates no more titles for the session.
- **`auto`**: the SDK's `title` option, applied at `initialize`, or on a resume without one the transcript's newest `custom-title`. Neither wrote to the probe's transcript, and the option wins over the record.

An append through the exported `renameSession` doesn't move the registry name of the process running at the time, but **a resume takes the newest `custom-title` back**, appended or not. A session with no `custom-title` resumes as `derived`, `ai-title`s or not.

That file is a few KB. In one unprobed run, a resume whose `custom-title` was 700KB back in a 768KB file copied it to the tail: the same name, so the row's title doesn't move, but don't count on a resume never writing.

At CLI v2.1.296 every resume went back to `derived`, `custom-title` or not; by v2.1.310 it no longer did. Nothing on disk records which: the transcript is the same either way, and only a session still running an older CLI, such as a Terminal one, will show a made-up name after its resume.

So Dex names sessions two ways:

- **On resume** the host passes the name it was handed as `title`, which gives an `auto` name and no record. A renamed session would get its name back without it, but one the CLI only titled would not.
  Not a slash command the session was opened with, which would stick: an `auto` name is never `derived` again.
- **A fresh session** started without a name is renamed live with its first title, once the app sees its registry name is still `derived` (`SessionNaming`). That fixes the row's title at the CLI's first one; the user's own Rename still wins afterwards. Only sessions the host is running: an archived row's id can be alive in a Terminal resume, where the rename would only append.

The registry's `cwd` follows the session into a worktree it enters; the transcript's launch folder does not. The fleet file takes the folder and branch from there (`FleetSnapshot.addressed`), and the `dex` server's `list_sessions` tool prints the fleet for an agent picking whom to message: address, title, folder and branch, state, what it's doing, session id. It re-reads the registry first, since the hosts outlive the app that writes the fleet: a row with no live record is left out, and the registry's name and folder win.

Code: `SessionRegistry.entries`, `SessionNaming`, `SessionStore.giveNames`, `HostedSession` (`title` on resume), `listSessions`. Tests: `SessionRegistryTests`, `SessionNamingTests`, `FleetSnapshotTests`.
