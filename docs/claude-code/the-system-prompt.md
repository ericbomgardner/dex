# The system prompt (SDK 0.3.283)

Probe: `Sidecar/test/system-prompt-probe.ts` — two sessions in a scratch directory.

**Leaving `systemPrompt` out does not mean "use the CLI's own."** The SDK reads the missing value as an empty custom prompt (`if (s === void 0) d = ""`), so the session runs with no system prompt at all: no tool guidance, no Claude Code, ~6.5k tokens missing, no warning. The host therefore always names one: the `claude_code` preset.

This is measured by counting tokens, not by asking: a session with no system prompt still claims to be Claude Code, inferred from its tools, and its answer changes with the wording. The `append` is the exception and is verified by asking, with a marker invented for the run. Both checks run in a scratch directory so a `CLAUDE.md` above the cwd doesn't skew the counts.

The prompt is also in the transcript: an `attachment` of type `prompt_snapshot` near the front of the file, once or twice per conversation, carrying `systemPrompt` as a list of parts and, in its second form, `tools` with every definition and `cliPrefix` — up to 142k in a session's file, 3k in a subagent's. The document drops it as an unknown attachment, which is right. It matters for any front-of-file read: see [What a subagent actually ran on](what-a-subagent-actually-ran-on.md).

Code: `session.ts` (`systemPrompt` on `query()`), the briefs in `briefs.ts`.
Tests: none beyond the probe.
