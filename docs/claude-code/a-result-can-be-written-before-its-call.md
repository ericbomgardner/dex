# A result can be written before its call (CLI v2.1.237)

No probe: the shape is in every transcript that used `Skill`; `TranscriptDocumentTests` pins it against a fixture written in file order.

The transcript is a log, not a conversation: records land in the order the CLI flushed them, not in call-then-answer order. Nearly always the call comes first, but `Skill` reliably breaks it — the loaded skill is fed to the model as an `isMeta` turn *before* the assistant turn that called for it, so the result lands three or four records **ahead** of the call. A few reads and edits do the same.

Trap: a reader that matches results to calls by looking the call up (`callSites`) finds no call, drops the result, and then the call arrives with nothing left to answer it — it stays pending for the rest of the file. `TranscriptDocument.early` holds a result that arrives before its call and `settle` folds it in once the call is written. The agent id off a launch receipt and the handover clock go the same route, since both read off the same lookup.

**Don't test this with a fixture written in conversation order — it passes either way.** And a scan that measures it has to collect *all* the ids first: building the call table as you walk, a result seen before its call never matches, which is exactly the case being measured.

Code: `TranscriptDocument.early`, `TranscriptDocument.settle`, `callSites`. Tests: `TranscriptDocumentTests`.
