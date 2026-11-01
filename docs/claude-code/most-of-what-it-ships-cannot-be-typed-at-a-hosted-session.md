# Most of what it ships cannot be typed at a hosted session (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/smoke.ts` — checks `slash_commands` arrives on init and is forwarded.

About half of the names in `BuiltInCommands` are `local-jsx` — panels drawn in a terminal — and a session started through the SDK answers one with `/help isn't available in this environment.` **That reply costs a turn**, so a menu that offers them makes you pay to find out.

The only thing that says which is which is `slash_commands` on `system/init`, the CLI's dispatch table. A command that can't run simply isn't listed — **absence is the whole reading**. The host forwards it on `session.init` and repeats it in the welcome's summaries, since `init` is emitted once per turn and an idle session would otherwise have nothing to say.

**Nil and empty mean different things, and the difference is the whole safety of it.** Empty means the session claims it runs nothing. Nil means it hasn't said yet. `SlashCommands.marked` treats nil as *offer everything*, because a menu that greys every row is worse than one that greys none. Two states are nil: a host from before the field existed, and a session before its first `init` (every session between `start` answering and its first turn). So the host holds `commands` as `string[] | null` and **initialises it to null, never `[]`**.

The list is a filter, **never a source**: it also carries housekeeping nobody types (`heapdump`, `autocompact`, `__remote-workflow`).

Known wrong on aliases: it uses canonical names, so `/cost` greys while `/usage` doesn't, though both run. A greyed row can still be typed.

Separately stale: `BuiltInCommands` moves only when [Slash commands](slash-commands.md)' probe runs, so a command the CLI adds after that is offered by neither until the next run.

Code: `SlashCommands.marked`, `BuiltInCommands`, `commands` in `session.ts`. Tests: `HostProtocolTests`, `HostSessionIndexTests`, `SlashAvailabilityTests`.
