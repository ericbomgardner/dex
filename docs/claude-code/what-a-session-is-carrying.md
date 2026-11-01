# What a session is carrying (CLI v2.1.314, SDK 0.3.314)

No probe: the field names are pinned by `SessionContextTests`, and `Scripts/maintainer/token-audit.py` is the second reader that would go quiet with them.

Read from `message.usage` on the **newest** assistant turn: `input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens`, the same three `Scripts/maintainer/token-audit.py` adds up. Newest rather than accumulated, which is why compaction needs no special case here: the next turn reads whatever the compacted conversation really carries. That is usually far less, but not always. The newest reply is kept verbatim beside the summary, so a session whose last reply was most of it can read the same or a little more after compacting (the estimate a boundary sets in the meantime, and why, are in [Compaction](compaction.md)).

**A rename of any of the three fields reads as a session carrying nothing, silently.** That is what the test pins.

Rules on the read:
- Rides on the same bounded read-from-end as the title and last message (never more than 38k back, against a 256k window).
- A turn reporting nothing on all three is skipped, not believed.
- A subagent's turns are skipped — its context belongs to its own conversation.
- That conversation is read too, for the agent's row: the newest turn in the last 256k of `subagents/agent-<id>.jsonl`, where every record is a sidechain one and so is kept rather than skipped. Re-read every source interval while the agent is out (`SubagentTranscript.context`).
- `HostSessionResult.costUSD` is decoded and dropped on purpose: the transcript answers for resumed and archived sessions too, and the socket doesn't.

The row badge threshold (150k) is derived, not chosen: `Scripts/maintainer/token-audit.py --long` calls a session worth splitting at 150 turns, and a session at that cut is carrying 150k by the tenth percentile.

**Prices** are the published list rates, the same table `token-audit.py` carries, so the two go stale together. An unknown model shows a size with no cost beside it rather than a guess — and that needs the id **matched whole**, with only a release date or width marker taken off. Matched on a bare prefix, `claude-opus-5-5` prices as `claude-opus-5` and the carry reads 2.5x high with nothing to say so. The cached-read share is per model in the table for the same reason: Sonnet 5.5 reads cache at 5% of input ($0.10/M), which the CLI's own cost figures took up in 2.1.296. Haiku 5.5 has two rate cards split at a 100k prompt, and the whole prompt is billed at the long one past it — the carry is the prompt, so the size picks the card (`Rate.longPrompt`, `LONG_PROMPT` in `token-audit.py`).

Code: `SessionContext`, `TranscriptRecord.context`, `SubagentTranscript.context`, `HostSessionResult.costUSD`, `Scripts/maintainer/token-audit.py`. Tests: `SessionContextTests`, `SubagentTranscriptTests`.
