# Which CLI the app's sessions run (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/smoke.ts` — checks the host can still talk to the bundled CLI, and measures the running-vs-on-disk SDK gap.

There are two copies of `claude` on this machine and they drift.

- The Terminal one updates itself (see [The CLI updates itself](the-cli-updates-itself.md)).
- The SDK ships its own at `Sidecar/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/` (found by search, since npm installs a per-architecture package). **Every hosted session runs that copy**, one process per session, a child of the host. It moves only when the SDK pin in `Sidecar/package.json` moves.

Every probe measures the bundled one: `Sidecar/test/` goes through the SDK, and the `Scripts/` probes run it by path through `bundled_cli()` in `Scripts/claude_cli.py`. They used to run the `claude` on PATH, and three of them rewrite Swift lists from what it printed. Anything the app says about its own sessions must ask the bundled one, through `HostLocation.bundledCLI` — **never `ClaudeExecutable.resolve()`**, which named picker rows after one binary and ran them on the other.

Moving the pin: `Scripts/make-app.sh` does it only when asked (`DEX_UPDATE_SDK=1`); a plain build installs what the lockfile says, and `DEX_PIN_SDK=1` is `npm ci`. It says what moved and leaves the pin uncommitted, then runs `Scripts/maintainer/recheck.sh`, every probe against the new CLI. Every sweep records to `~/.claude/dex/recheck/<stamp>/` (`run.log`, one log per probe, `last.json` naming failed probes and the three probe-written lists), or under `DEX_RECHECK_DIR`. The three lists are rewritten only on a clean `main`, and left in the working tree for you to read and commit.

A running host splits the pair further, in opposite directions:

- **The CLI binary is found by path on every `query()`.** A build that rewrites `node_modules` under a running host is picked up by the next session started, no restart. The cost: the host outlives the app and is spawned from a path, so a rename or clean that removes the bundle leaves the host on JavaScript in memory with no `node_modules`, and `query()` throws `Native CLI binary for darwin-arm64 not found` on every start until the host is replaced. Running sessions are untouched. So `start` is answered after the session is away, a failed key is forgotten so it can be retried, and `HostSessions.Launch` carries the host's error to the toast — otherwise the throw lands under `id: "?"` and the app blames its own list after twenty seconds.
- **The SDK JavaScript is imported once at host start** and held for the life of the process (days). A long-running host runs old SDK code driving a current CLI. The host reads `sdkVersion()` **at module load**, sends it as `sdk`, and a fresh read as `sdkOnDisk`; `HostSDK` compares them, and the gap is the only thing that says replacing the host would change anything. **Never report the on-disk version as the running one.**

Probe caveat: `smoke.ts` measures the gap by editing `package.json`'s version while the host runs; written any other way the check passes trivially because both halves name the same build.

Code: `HostLocation.bundledCLI`, `HostSDK`, `HostSessions.Launch`, `Scripts/make-app.sh`, `Scripts/maintainer/recheck.sh`, `Scripts/claude_cli.py`. Tests: `HostSDKTests`, `HostSessionIndexTests`, `HostProtocolTests`, `BundledCLITests`.
