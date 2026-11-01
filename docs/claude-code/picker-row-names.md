# Picker row names (CLI v2.1.312)

Probe: `Scripts/model-alias-probe.py` — same run as [The models the picker offers](the-models-the-picker-offers.md); it stops if the `Current model:` line disappears from the reply.

`claude -p "/model"` answers like ``Current model: `Opus 5 (1M context) (default)` (effort: xhigh)``; a specific row is asked with `claude -p --model sonnet[1m] "/model"`. `ModelReadout` parses the name out, so rows are named by the CLI and there is no table to go stale.

- **The name is in backticks and the quoting cuts across the markers**: `default` and the context window sit *inside* the backticks, `effort:` sits outside. A single pass that strips markers stops at the closing backtick and leaves the marks in the name. `name(in:)` alternates `stripMarkers` and `unquoted` until neither changes anything.
- **A lone backtick is not a pair** and is kept — a name short one character is worse than one with a stray mark.
- Trailing markers come off by content (`default`, `effort:`, a context window, a plan-mode override), not by position, since model names can contain parentheses.
- Since CLI v2.1.283 the Opus row no longer says `(1M context)` where Opus already has a 1M window, and since 2.1.311 no row does: at 2.1.312 `opus[1m]`, `sonnet[1m]` and `fable[1m]` read `Opus 5.5`, `Sonnet 5.5` and `Fable 5.1`, the same as their bare aliases. The stripping stays for older CLIs and any row that still carries it.
- The context window is stripped on purpose: the CLI writes it for `opus[1m]` and not for `sonnet[1m]`, so keeping it makes the rows inconsistent.
- Each query is a subprocess that hits the network (~1s), so all rows are asked together the first time the composer opens. If any row fails to parse, no row gets a name — all or none.

Code: `ModelReadout`, `ModelReadout.name(in:)`, `stripMarkers`, `unquoted`. Tests: `ModelReadoutTests` (pins lines the CLI actually printed).
