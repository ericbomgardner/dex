# The CLI updates itself (CLI v2.1.238)

No probe: nothing measures the updater; `changelog-watch.py` is the reader that depends on it.

The `claude` in the Terminal updates itself and skips releases, so a local `--version` is a **floor, never a ceiling**. There may always be newer releases than the one on disk.

What `changelog-watch.py` does with that:

- The bookmark (how far the changelog has been read, not the changelog itself) is the further of `~/.claude/dex/changelog.json` and `docs/claude-code/changelog-read.json`, the mark kept in the repo (`--seen --shared` moves it). Its `givenUp` list holds ranges marked read without a follow-up (`--given-up`, `--followed-up`).
- The *read* runs to whatever is published. It must not cap at the bundled CLI's version — that hides releases already live.
- With no ceiling nothing local can compute the `--seen` that marks a reading done, so `changelog-watch.py` prints the exact `--seen` command for the range it just showed. **A bare `--seen` marks only the installed CLI's version**, which lands short of what you read.
- `changelog-watch.py` reads the `(CLI vX.Y.Z)` markers out of the headers of the files in `docs/claude-code/`; an entry without a marker is never flagged for re-checking.

`CLIVersion` parses `claude --version` and compares part by part, so 2.1.9 sorts below 2.1.10.

Code: `CLIVersion`, `changelog-watch.py`. Tests: `CLIVersionTests`.
