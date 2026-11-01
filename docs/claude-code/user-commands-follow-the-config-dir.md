# User commands follow the config dir (CLI v2.1.308, SDK 0.3.308)

Probe: `Scripts/config-dir-commands-probe.py` — seeds a fake `HOME/.claude`, a separate config dir and a project, then reads `slash_commands` off `system/init` with `CLAUDE_CONFIG_DIR` set and unset.

The user's own `commands/` and `skills/` are read from `$CLAUDE_CONFIG_DIR` when it is set, and **`~/.claude` is not read at all**: there is no fallback and no merge. Unset, they come from `~/.claude`. A project's `.claude/commands` and `.claude/skills` are read either way.

So the composer's `/` menu reads its user scope from `ConfigDirectory.resolve()`, like the rest of the app, and not from the home folder. A menu built from `~/.claude` under a scratch config offers commands the session has never heard of.

Code: `SlashCommands.all(configDirectory:)`, `SlashCommands.scopes`. Tests: `SlashCommandsTests`.
