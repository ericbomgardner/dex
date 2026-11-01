# Slash commands (CLI v2.1.308, SDK 0.3.308)

Probe: `Scripts/slash-command-probe.py` — drives a real session's `/help` (needs `pip3 install pyte`) and rewrites `BuiltInCommands.swift`.

The CLI has no way to print its command list other than the `/help` panel in a terminal, so the list in `BuiltInCommands.swift` is scraped from the screen. Custom commands are read from disk at runtime and are not in that file; for where the user's come from, see [User commands follow the config dir](user-commands-follow-the-config-dir.md).

**The probe rewrites source, so it has to prove it read the whole panel.** A trust prompt or a half-drawn panel would otherwise write the file short and nothing would say so. The gates, all of which stay:

- wait for the Commands tab's own header (`Browse default commands`) and re-check it on every screen of the walk;
- require five sentinels (`help`, `model`, `compact`, `clear`, `exit`) to come back;
- refuse a list under 90% of the count already on disk unless passed `--shrink`.

Since 2.1.307 the panel gives bundled skills (`/claude-api`, `/simplify`, `/loop`, …) their short descriptions instead of the long model-facing ones, which the old list had cut off mid-sentence; the names didn't change. The probe runs the SDK's bundled CLI, since that is what the app's sessions run.

**The panel depends on the login.** On an API key it lists 20 fewer at CLI v2.1.314 (87 against 107): the claude.ai-only ones, among them `/upgrade`, `/usage-credits`, `/remote-control`, `/teleport`, `/voice` and `/schedule`. `BuiltInCommands.swift` is the login's list, so the probe runs on a stored claude.ai login and doesn't run without one. On a key the shorter list would fail its own 90% gate.

Which of those names actually run in a hosted session is a separate reading: see [Most of what it ships cannot be typed at a hosted session](most-of-what-it-ships-cannot-be-typed-at-a-hosted-session.md). `BuiltInCommands` only moves when this probe runs, so a command the CLI adds later is offered by nothing until the next run.

Code: `BuiltInCommands.swift`.
