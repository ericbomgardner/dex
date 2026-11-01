# When that transcript turns up (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/transcript-arrival-probe.ts` — one session, measures the gap between the announcement and the file.

**Naming the file and writing it are two separate moments.** `system/init` — where the app learns the session id, and so where it goes looking — carries a path to a file that does not exist yet. The file appears ~100ms later, and the CLI's title lands a second after that. Don't build against the number; it is one machine's. The rule is only that it is never zero.

So a read taken on the announcement always comes back empty. `SessionStore.awaitTranscripts` retries every 250ms until the file exists or the session is older than the reconcile. That retry is also what gets `TranscriptWatcher` attached: the watch is opened against the file, and until one exists the row hears nothing written to it. The title arrives on a later pass than the file, so it is read off a write (`applyActivity` carries `digest.title`), not off the first successful read.

**The lag runs to the other end of the turn too, and is seconds there.** A resumed turn's transcript is still being written after the `session.result` that ends it (15 lines at the result, 21 three seconds later). Nothing in the app reads a transcript on the strength of a result.

Probe caveat: `Sidecar/test/smoke.ts` settles this by waiting for the file to go quiet, not by sampling twice, and that wait is last in the test — a resumed session's query ends on its own and the host forgets its key with it, so a wait placed earlier finds the key free and reads the refusal check as a pass.

Code: `SessionStore.awaitTranscripts`, `TranscriptWatcher`, `applyActivity`. Tests: `Sidecar/test/smoke.ts` (the quiet-wait).
