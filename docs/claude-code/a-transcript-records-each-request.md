# A transcript records each request (CLI v2.1.300, SDK 0.3.300)

Probe: `Sidecar/test/api-request-record-probe.ts` — one haiku turn that reads two files with two parallel Read calls, then reads the transcript.

Since 2.1.300 the CLI writes into the transcript what it sent the API, so a shared file can replay a request exactly. Three new record types, all written **before** the assistant turn they produce:

- `api-request-shape` — `shape: {system, tools}`, the whole system prompt and tool list, keyed by `shapeHash`. Written when the shape changes: once per session in practice, ~37k median and 46k at most across this machine's first 2.1.300 files.
- `api-request-blob` — `hash`, `sessionId` and a `message` of `{role, content}`, the API's form of one message. Written only where that differs from a single record: the system-reminder context folded into the first prompt, a `system`-role block, and **any message the API merges from several records** — parallel tool results, an interruption and the prompt after it. Nothing else: no `timestamp`, `uuid`, `isSidechain`, `cwd` or `version`.
- `api-request` — `id`, `timestamp`, `querySource` (`sdk`, `agent:builtin:general-purpose`, …), `params`, `keep` and `tail` (blob hashes). The assistant turn it produced names it in a new `requestRef`.

**A blob has a `message` like a turn and is not one.** Its content repeats the merged records' blocks — the same `tool_result`s under the same `tool_use_id`s — and it lands after the stamped `user` records it repeats. A reader that walks `message.content` without asking `type` reads every merged result twice, the newest copy unstamped. `McpCallOutcome.read` did, and the unstamped copy slipped a pre-resume drop past `since`. The rule everywhere: **only `user` and `assistant` records are turns** (`TranscriptRecord.role`), and `McpCallOutcome.read`, which scans lines, decodes and then checks the role too.
`TranscriptDocument`, `SessionDigest`'s message and context, `TranscriptStanding`, `TranscriptSearch.searchableText`, `SubagentIdentity` and `transcript-render.py` already gated on type. `DriveReturns` doesn't, and needs no gate while blobs carry no timestamp, since it keeps only stamped results. Of the probes, `subagent-totals-probe.py` and `Scripts/maintainer/token-audit.py` gate on type now; before, the audit counted each blob as more of "your message".

**The front of a file is ~60k bigger** (the shape and the `system` blob), which matters to the one front-of-file read, `SubagentTranscript.identity` (see [What a subagent actually ran on](what-a-subagent-actually-ran-on.md)). The tail reads are not affected the same way: request records sit before the turn, so a finished turn is still the newest record. Only while a request is out do a merged blob's repeated results stand between the window's end and the last turn.

Code: `McpCallOutcome.read`, `TranscriptRecord.role`. Tests: `McpTroubleTests.testARequestBlobRepeatingTheResultsIsNotATurn`.
