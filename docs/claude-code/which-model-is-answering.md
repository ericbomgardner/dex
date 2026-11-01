# Which model is answering (CLI v2.1.222)

No probe: the field is pinned by `TranscriptDocumentTests` against the record shape.

The model is read from `message.model` on each assistant turn, not from the launch options. `/model` typed mid-conversation changes what answers and the options never do, so a badge built from options is wrong from that point on.

The value is the resolved id (`claude-opus-5`), so a variant like `opus[1m]` reads as its model. `ModelName` derives display names from ids by rule, not from a table, so a new id still gets a name.

Not every assistant turn names a model: a turn the CLI wrote itself carries `<synthetic>` there and must be skipped, not believed — see [Turns the CLI wrote itself](turns-the-cli-wrote-itself.md).

Code: `TranscriptDocument.model`, `ModelName`. Tests: `TranscriptDocumentTests`.
