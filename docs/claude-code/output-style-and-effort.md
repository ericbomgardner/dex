# Output style and effort (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/output-style-probe.ts` — real sessions; the Default-row half is `Sidecar/test/effort-default-probe.ts`, no session, costs nothing.

## The wire

Both go in through `settings` on `query()` — the flag layer, above the settings files, written to no file. Neither is ever written to `settings.json`: the app's pick governs the app's sessions and a terminal keeps its own.

- `applyFlagSettings({ effortLevel })` moves a running session, `max` included. The composer offers a launch level and `SessionEffortPicker` dials a running one (`HostSessions.setEffort`, `SessionStore.attachedEffort`/`setAttachedEffort`).
- `applyFlagSettings({ outputStyle })` moves a running session too, from the next turn. **The live word is `output_style` on the per-turn `system`/`init` frame; `initializationResult()` is the cached first-connect answer and never moves** (`reinitialize()` is the fresh one) — a check against it reads a moved style as unmoved. The app still offers the style as one app-wide pick at launch; a per-session setter is deferred, not impossible, and would mirror `setEffort`.
- `/output-style <name>` typed at a hosted session writes `{"outputStyle": …}` to the cwd's `.claude/settings.local.json`. The flag layer outranks that file, so a session the app started does not change. The probe removes the file it wrote, or its `resolveSettings` half reads `local` where it expects `project`.
- **`max` asked at launch is dropped, not clamped.** `effortLevel` in the settings schema stops at `xhigh` and an invalid value parses to nothing, so the session starts wherever the layers below say — Default. Only the dial's `applyFlagSettings` reaches `max`, so the launch list stops one short of the dial. `EffortLevel.launchable` sends `xhigh` (`EffortLevel.capped`) in its place, the app's choice rather than a landing place. The earlier "lands on `xhigh`, then `high`, then `xhigh`" readings were the probe reading whichever machine's `~/.claude/settings.json` it ran on; it now names `low` in its own project so the answer is the same everywhere.
- **The CLI restates the effort nowhere.** A refused effort change is put back by `HostSessions.setEffort` (`onRefusal`); nothing else corrects it. The host's `session.init` carries the level the session was started at (`HostSessionInit.effort`), restated every turn, so an app that connected after the session started still knows it. **Nil there is a host too old to say, not Default** — it leaves a known level alone.
- A resume replays both (`HostedArchive.Entry.effort`, `.outputStyle`): sending nothing is Default, which would hand a half-written conversation to whatever the cascade says now. The style is deliberately not read off the app's own pick, which is one setting for every row. `default` normalises to sending nothing (`OutputStyle(stored:)`).
- `session.init` also carries the style the CLI *resolved*, off its own `system` message — the only word for where a name matching no file landed.

## The style list

Styles are files on disk (built in, `~/.claude/output-styles`, a project's own), so the list is `initializationResult().available_output_styles`, which exists only while a session runs. The host learns it from the first session and replays it on the welcome; the app keeps the last list heard (`Defaults.knownOutputStyles`). **An empty list never clears a full one**: empty means nobody has asked yet.

## The Default row

Each picker's Default row is `resolveSettings({ cwd })` — the CLI's own merge engine, in-process, ~30ms, no session. Asked per **directory** (a project's `.claude/settings.json` wins over the config directory's), from `.task(id:)` bound to the folder, because `composerTarget` retargets on its own. Deliberately not read off a running session: the flag layer sits above every file, so a session would answer "whatever you last picked". **Not cached**: the files change under the app and the index outlives the host. Null is neither a failure nor a level — the row says `Default`. `resolveSettings` is `@alpha`: check it is a function, so an SDK without it costs a subtitle, not a picker. A `max` in a file, top-level or under `modelSettings`, is dropped the same way, and the answer comes from the next file down; `sources` already has it removed, and `HostDefaults.effort(forModel:)` skips one anyway.

**The merged `effortLevel` is not the answer for every model.** The CLI walks the files in precedence order and takes the first that answers: `modelSettings.<model>.effortLevel`, then the file's top-level level — except that a top-level level in the **user's** file reaches only the models in `HostDefaults.legacyModels` (nineteen, copied out of the CLI). So `effortLevel: xhigh` in `~/.claude/settings.json` starts Opus 5 at `xhigh` and Opus 5.5 and Haiku 5.5 at their own defaults. The host sends each file's levels (`efforts`) and `HostDefaults.effort(forModel:)` applies the rule for the model the composer names (`modelName(for:)`). Nil `efforts` is an older host and reads the merged key. `launching(default:)` sends the level Default resolved to, which is why a wrong row pins every session to it.

## Probe caveats

- A style is an instruction, not a filter: assert the CLI's `output_style` on the next `init` and the old marker's absence; the new marker's presence only measures compliance.
- Read effort off `CLAUDE_EFFORT`, which the CLI hands to Bash and which names the level after any downgrade; a session asked how hard it is thinking has nothing to read.
- A turn that runs out of time without its `result` must stop the probe, or every later reading is taken off the turn before it.

Code: `HostSessions.setEffort`, `SessionStore.attachedEffort`, `SessionEffortPicker`, `EffortLevel.capped`, `EffortLevel.launchable`, `HostSessionInit.effort`, `HostedArchive.Entry`, `OutputStyle(stored:)`, `Defaults.knownOutputStyles`, `HostDefaults.effort(forModel:)`, `HostDefaults.legacyModels`. Tests: `EffortLevelTests`, `OutputStyleTests`, `HostProtocolTests`, `HostSessionIndexTests`, `HostedArchiveTests`; the wire's half in `Sidecar/test/smoke.ts`.
