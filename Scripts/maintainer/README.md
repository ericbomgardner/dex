# Maintainer scripts

For keeping Dex in step with Claude Code. Nothing here is needed to build or run the app.

- `recheck.sh` re-runs every probe against the bundled CLI and says which readings in `docs/claude-code` no longer hold. `make-app.sh` runs it when `DEX_UPDATE_SDK=1` moves the SDK pin. `--dry-run` keeps the three list-writing probes from editing source, and `DEX_RECHECK_DIR` moves its record out of `~/.claude/dex/recheck`.
- `changelog-watch.py` reads Claude Code's changelog for things worth building, and with `--probes` names the readings pinned below the CLI that answers for them.
- `token-audit.py` adds up what sessions spent from their transcripts.
- `transcript-render.py` is a second, stdlib-only reader of the transcript format. `transcript-render-test.py` is its tests.
