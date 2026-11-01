# The models the picker offers (CLI v2.1.312)

Probe: `Scripts/model-alias-probe.py` — runs `claude -p "/model"` and rewrites `ModelAliases.swift`.

`claude -p "/model"` prints the models under `Available:`. The probe parses that list into `ModelAliases.swift`; if the output doesn't parse it keeps the existing list rather than writing an empty one. `default` is dropped, since sending no model already means that.

- The list is what to **offer**, not what to allow: the SDK also accepts full model ids, so a name that falls off the list still dispatches.
- The picker shows only the classes in `SessionModel.classes`, each at its widest context window. Bare `opus` is the narrow variant; the CLI's own picker uses `claude-fable-5-1[1m]` for Fable (`additionalModelOptionsCache` in `~/.claude.json`).
- CLI 2.1.311 dropped the `[1m]` suffix from model names and ids where it changes nothing. The suffix is still taken, and at 2.1.312 `sonnet[1m]`, `opus[1m]` and `fable[1m]` are all still listed, so `SessionModel.widest` still picks them. If they fall off the list, `widest` falls back to the bare class and `settled` moves a stored `opus[1m]` onto it.

Row names come from the same command — see [Picker row names](picker-row-names.md).

Code: `ModelAliases`, `SessionModel.classes`. Tests: `SessionModelTests` (every class is in the list).
