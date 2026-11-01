# Row title and subtitle (CLI v2.1.283)

Probes: `Scripts/session-digest-probe.py` — checks the title record is still rewritten, not appended. `Sidecar/test/command-title-probe.ts` — checks a session opened with a slash command still goes untitled.

Both come from the transcript: the host reports state, not content, so `SessionRowModel.summary` has nothing else to read.

**Title.** Its own record, `{"type":"ai-title","aiTitle":"…"}`, written a second or two after the first prompt. It is **rewritten rather than appended**, so the *last* one is the name, and a long session carries dozens. A user's rename is a different record, `custom-title`, which outranks it: see [Renaming a session](renaming-a-session.md). That rewriting is also what keeps the title inside the bounded read-from-end window (never more than 33k from the end of a 2MB file, against a 256k window). If the CLI stops rewriting it, nothing fails loudly — long sessions keep stale titles — which is what the probe is for. Until the title lands the row says "New session".

**A session opened with a slash command gets no title.** The CLI skips a first prompt that is a command, with or without arguments, and titles the session only when a plain prompt follows, so a session that is only `/land` never gets named. The first user record is the command's echo (`<command-name>/land</command-name>`, `<command-args>…</command-args>`), and `SessionDigestReader.openingCommand` names the row with that, `/code-review high`, until an `ai-title` turns up. It reads only the file's own opening: the whole file when it fits the window, otherwise the first 64k, because a window that starts mid-file could begin at any command.

**Subtitle.** The newest `text` block either side said. Excluded on purpose:
- tool calls and results — they put a diff or stack trace where the conversation should be;
- sidechain turns (`isSidechain`);
- unknown record types, guarded by `role`;
- CLI-injected content, stripped by `TranscriptText.cleaned`.

A session waiting on a question shows the ask instead, from the socket, only while it is still asking — withdrawing an ask and leaving `asking` are two separate messages.

Rejected, don't re-propose: tool descriptions as subtitles (they read as a working line, not what the row is for), and generating a line with Haiku (6–14s and 1–2¢ each, and it inverted the finding it was handed).

Code: `SessionRowModel.summary`, `SessionDigest`, `TranscriptText.cleaned`. Tests: `SessionDigestTests`, `HostRowsTests`.
