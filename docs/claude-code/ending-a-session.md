# Ending a session (SDK 0.3.283)

Probe: `Sidecar/test/reap-probe.ts` — a session under a short reap window, counted off `ps`.

Closing a session's input stream ends its CLI process, within ms of the `session.exit` the drain loop announces. The probe counts that off `ps`, **not the host's own bookkeeping**: a stream that closed without killing the process would leak one CLI per reap, off the map that could have counted it, so the host would report itself emptier the more it leaked. Each CLI costs ~470MB and doesn't shrink between turns.

What ends a session:

- `HostedSession.reapable` releases one idle for 24h (`DEX_REAP_AFTER_MS` sets it for a probe; `DEX_HOST_IDLE_MS` does the same for the host's own exit). The 24h is measured against how often a conversation is come back to after that long, not picked.
- `forget` drops one whose query ended on its own, which also frees its key. `start` refuses a key already in the map and a row is resumed under the key it ran as, so without `forget` an errored session is a row that can never be reopened.

**Idle is not the same as nothing running.** A background agent outlives the turn that launched it, so the predicate reads `#tasks` and `#parked`, not just the clock.

**The clock only moves on what the session *says*.** An inbound message is echoed by nothing, so a `send` to a session idle long enough to be reaped leaves it looking exactly as stale, and the next tick ends the turn it was just handed. Every request that names a session stamps it (`touched`), in `handle` rather than in `send`: a `mode` request that picks the mode already in effect changes nothing else and is still someone reaching for the session.

**A reap has to read as housekeeping.** The drain loop ends the same way whoever closed the stream, and a `done` on the way out is the app's word for a turn that just finished: the row takes it as it is, `SessionTransitions` posts **Finished**, and `session.status` moves the row's clock (`movesRowClock`), so a row dismissed yesterday would un-settle and climb back to the top of the list. `stop()` marks the session `#retired`, the drain skips the state change, and the exit calls itself `retired` rather than `ended`. The app cannot tell the two apart on the wire; only the host knows which it did. **A query that ends on its own still says `done`, and should** — that one really is a finish. The dying CLI writes its own goodbye records, so the transcript's mtime moves at a reap; that costs nothing only because rows are built from the host and the archive, never from a scan of disk.

Probe caveat: the check is for an *absence* — no `session.status`/`done` for the key up to the reap, and again after an app-asked `stop`. Written as a wait for a quiet exit it would pass on a host that had stopped emitting anything.

Code: `HostedSession.reapable`, `HostedSession.touched`, `#retired`, `forget` (`Sidecar/src/host.ts`), `HostRows`, `SessionTransitions`, `HostEvent.movesRowClock`. Tests: `HostProtocolTests`.
