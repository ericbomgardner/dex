# Permission modes and plans (CLI v2.1.283)

Probe: `Scripts/permission-mode-probe.py` — rewrites `PermissionModes.swift` from `--help`; the wire is pinned by `Sidecar/test/mode-dial-probe.ts`.

The SDK's `permissionMode` option takes the flag names (`manual`, `dontAsk`, `bypassPermissions`), none of which appear in a transcript; transcripts write `default`, which that list omits. So `recognises` is the union: one half generated from `--help`, the other pinned by hand so an unexercised mode doesn't vanish.

**Sending nothing is not auto** — it lands the CLI's ask-first `default`. Every `start` names `permissionMode: "auto"`, and a resume names `auto` too rather than replaying the recorded mode: there is no mode UI, so a session brought back in `plan` or `default` would be invisible and unfixable.
**Asking for a mode is not getting it** — auto mode can't run on Haiku 4.5, and the CLI quietly starts it in `default`; `system`/`init` says which.

`PermissionModes.swift` is read by nothing in the app. It and its tests stay because the probe that writes it is also the re-check for the plan shapes below. The wire under the dropped UI stays too: a `mode` request is accepted while parked on an ask and while idle; the welcome says which modes a host takes; and `session.mode` is the only word for a mode the CLI changed itself — approving a plan lands the session in **auto**, restated on its own `system` messages. A host older than the mode answers `unknown mode auto`; only replacing the host fixes that.

Plans: `ExitPlanMode`'s schema says it takes no plan and reads one from `~/.claude/plans/<slug>.md`, but the CLI records the full plan under `input.plan` anyway, with `planFilePath` beside it. `proposedPlan` prefers the inline plan and falls back to the file. The outcome is read off the result: an approved result repeats the whole plan under `## Approved Plan:` (**don't render that text or the plan prints twice**), `planWasEdited` marks one rewritten in the dialog, and `is_error` marks a refusal with the user's words after `the user said:`.

Code: `PermissionModes.recognises`, `proposedPlan`, `session.mode`. Tests: `PermissionModesTests`, `HostSessionIndexTests`, `TranscriptDocumentTests`.
