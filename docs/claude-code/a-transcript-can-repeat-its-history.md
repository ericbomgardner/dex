# A transcript can repeat its history (CLI v2.1.308, SDK 0.3.308)

No probe: seen once, in a week-old session on a machine whose CLI version wasn't recorded; the version above is only what was current here when it was written up. None of several thousand other transcripts repeat a uuid. `TranscriptDocumentTests` and `transcript-render-test.py` pin the shape.

Partway down the file, after a metadata block (`ai-title`, `agent-name`, `mode`, `pr-link`), the CLI wrote the whole conversation again from the first prompt: about 2,300 records, each with a `uuid` that already appeared above, with timestamps jumping backwards where it starts. A resume is the likeliest cause; nobody has confirmed it.

The replay is not a faithful copy. It repeats each background agent's `tool_use` and its launch receipt, but not the `<task-notification>` that came after. Read in file order, every background agent that had finished was out again, and the strip over the composer listed them with clocks at 165 hours.

So both readers skip a record whose uuid they have already read. A record's `parentUuid` points at a uuid, so a repeat is the same record again, not a new one. Records with no uuid (`queue-operation`, the metadata types) aren't covered; if the replay repeats queue operations, the message count could jump. That hasn't been seen.

Code: `TranscriptDocument.append` (`read`), `Document.append` in `Scripts/maintainer/transcript-render.py`. Tests: `testAHistoryWrittenTwiceDoesNotRelaunchItsAgents`, `test_a_history_written_twice_does_not_relaunch_its_agents`.
