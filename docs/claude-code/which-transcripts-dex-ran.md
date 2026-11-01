# Which transcripts Dex ran (CLI v2.1.296, SDK 0.3.296)

Probe: `Sidecar/test/resume-probe.ts` — checks every turn of a session the SDK ran, before and after a resume, carries an `sdk…` entrypoint, and that the first turn names the folder it ran in.

Searching sessions (Cmd-Shift-F) reads `~/.claude/projects` directly, because `HostedArchive` forgets a session after a week.
The folder doesn't say who ran a session, but every `user` and `assistant` record has an `entrypoint`:

- `sdk-ts` — the Agent SDK, which is Dex's host. This is what it writes from SDK 0.3.283 on.
- `sdk-cli` — what the same host wrote before that.
  So do `claude -p` runs. Most of those ran in `/` (the `-` project folder), and they hold no conversation that would match.
- `cli` — the Terminal. Left out.
- `claude-desktop` — the desktop app. Left out.

So the rule is "starts with `sdk`". A few files carry no `entrypoint` at all; they're old and are left out too.

The CLI writes `cwd` with symlinks resolved, so `/var/…` arrives as `/private/var/…`.
An app given a link to a session it no longer lists adds it back to `HostedArchive` (`adopt`) from the transcript, unless its folder is gone.

The match is against what was typed and what Claude said (`text` blocks and narration). It never matches tool input or output, `isMeta`, sidechain records or compaction summaries. The bytes are scanned case-folded for the query as it's written inside a JSON string (quotes and backslashes escaped, slashes and non-ASCII not), and only the lines that match are decoded — apart from tool records, which the CLI writes one block per record and which are skipped before decoding. The fold covers ASCII only, so a query with other letters is scanned for by its longest ASCII run and matched in full once decoded.

Code: `TranscriptSearch`, `HostedArchive.adopt`, `SessionStore.takeBack`. Tests: `TranscriptSearchTests`, `HostedArchiveTests`.
