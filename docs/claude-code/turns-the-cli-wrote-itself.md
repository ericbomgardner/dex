# Turns the CLI wrote itself (CLI v2.1.283)

Probe: `Scripts/synthetic-turn-probe.py` — forces one with a model name that can't resolve; fails before the request is sent, so a second and no tokens.

A request that fails is still written as an assistant turn, marked two ways: `<synthetic>` where the model id goes, and `isApiErrorMessage` **on failures only**. The same `<synthetic>` mark also appears on `No response requested.` — the CLI saying a resumed conversation had nothing to add — which is not a failure and carries no `isApiErrorMessage`. That is why the second mark is read rather than inferred from the first.

- `TranscriptDocument.model` skips the placeholder instead of believing it: it names no model, and the badge moves only when a turn names one. Read as a model, the badge would show `<synthetic>` under the composer for the whole stretch where it is wrong.
- The text is drawn as a `TranscriptNotice`, not prose. Read as prose, "You've hit your session limit" looks like something the model said about itself.
- Both record kinds carry `usage` 0/0, so the context badge needs no special case — `TranscriptRecord.context` already skips a turn that read nothing.
- `SessionDigest` still reads the text: a limit notice is worth having as the row's second line.

Code: `TranscriptDocument.model`, `TranscriptRecord.context`, `TranscriptNotice`, `SessionDigest`. Tests: `TranscriptDocumentTests`.
