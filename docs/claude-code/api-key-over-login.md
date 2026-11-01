# An API key outranks the stored login (CLI v2.1.308, SDK 0.3.308)

Probe: `Sidecar/test/api-key-over-login-probe.ts` — needs a stored claude.ai login for the key to outrank and doesn't run without one, runs in a scratch cwd, spends a few tokens of haiku on the control and nothing on the rest.

Dex runs sessions on an Anthropic API key. The CLI prefers a key over a login it already has stored, so a session runs on the key even on a Mac where the CLI is logged in. Every run in the probe also has a `UserPromptSubmit` hook and a stdio MCP server that write out their environment, because both start whether or not the turn authenticates.

- **With no key**, init's `apiKeySource` is `"none"` and the stored login answers.
- **`ANTHROPIC_API_KEY` in the environment outranks the login** (`apiKeySource: "ANTHROPIC_API_KEY"`; it also outranks `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_AUTH_TOKEN`). **But the CLI's children inherit it**: the hook and the MCP server both see the key, and so would Bash, so a session running `env` writes it into its transcript and every MCP server gets it. That's why the host doesn't use it.
- **`apiKeyHelper` at the flag layer outranks the login too**, and keeps the key out of the environment. Init says `apiKeySource: "apiKeyHelper"`. A dummy key fails the turn as a `<synthetic>` message with `error: "authentication_failed"` and text `Invalid API key · Fix external API key`, at cost 0, and neither the hook nor the MCP server sees it. Nothing asks to approve the key first.
- **A refused helper key is retried; an environment key isn't.** With the helper, a 401 comes back as `api_retry` messages (`error_status: 401`, `max_retries: 10`, backoff capped near 37s) before the turn fails as above, about three minutes later. Every retry is the key refused, never the login. A bad key in Dex therefore shows a working session for those minutes before it fails, where the environment route fails at once.
- **A helper that fails** (missing file, no output, non-zero exit) fails the turn at once with `Your apiKeyHelper script is failing` (`error: "invalid_request"`). It never falls back to the login.

A dummy key failing to authenticate is the evidence the key was used, because a run that fell back to the login would have answered.

How the key gets there:
- **On the wire:** a `start` request carries `apiKey`, resumes included. The host keeps no key for itself.
- **On disk:** for each keyed session the host writes the key to a `KeyFile`, `$TMPDIR/dex-key-<host pid>-XXXX/key`, with mode 0600 in a 0700 folder.
- **To the CLI:** the session runs with `apiKeyHelper: /bin/cat '<that file>'` in its flag-layer `settings` (see [Output style and effort](output-style-and-effort.md)) and `keylessEnvironment()`. That's the host's environment with `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` taken out, so the helper is the only credential.
- **Clean-up:** the file goes when the session ends or fails to start. A host that stops on a signal (the app's auto-replace, a logout) or idles out exits before any session's drain ends, so `shutdown()` and an `exit` handler remove every file the host still holds (`removeKeyFiles`). Only a host that's killed outright leaves one. A host coming up then removes files whose pid is gone, a zombie, or a process started after the folder was (a reused pid).
- **Older hosts:** a host advertises `apiKey` among its capabilities. One that doesn't would drop the key and run the session on the login, so the app refuses to start a session on it.

What this doesn't cover:
- **Reading the file directly:** the key file is the user's own, so a session that goes looking can still `cat` it. The helper's path is also in the CLI's argv (`--settings`).
- **Bash:** the probe can't run Bash on a dummy key, since no turn ever gets that far. The hook and the MCP server get the same environment the CLI gives its children.
- **Project settings:** a project whose own settings set `env` credentials is outside what the host controls.

The app takes the key from one of two places:
- **The login shell's `ANTHROPIC_API_KEY`:** `LoginShell.probe`, read once per launch, because a Dock-launched app doesn't inherit the shell's environment. It's read off the main thread: a start made while the shell is still answering waits for it without blocking (`KeyLookup`).
- **A key Settings saves** in the login keychain, as the item `<bundle id>.anthropic-api-key` beside the connection tokens (`SavedAPIKey`, `AppKeychain`). It's only read when the shell has no key, and never on the main thread, since a read can wait on a keychain prompt.

With neither, a start or resume is refused before it reaches the host, and the reason points to Settings. A keychain that won't hand the saved key over (locked, or access denied) is refused with its own reason instead, and Settings shows it as unreadable with Retry.

Because a refused key only fails a session minutes in, Settings checks a key as it's saved, and the shell's key once per launch when Settings opens (`APIKeyCheck`): a `GET /v1/models?limit=1` with the key in `x-api-key`, which costs nothing. 2xx is valid, 401 is refused, anything else or no answer is "couldn't check", and only a refused key isn't saved, leaving any key already saved in place. Saves run one at a time, and an item this build can't replace says so (`TokenNotReplaced`). Clearing the field removes the item.

Code: `KeyFile`, `keylessEnvironment`, `removeKeyFiles` and `sweepKeyFiles` in `keyfile.ts`, `SessionOptions.apiKey` in `session.ts`, `Start.apiKey` and the `apiKey` capability in `protocol.ts`, `HostRequest.start(apiKey:)`, `HostSessionIndex.takesAPIKey`, `HostSessions.dispatch`, `SessionCredential`, `KeyLookup`, `SavedAPIKey`, `CredentialSection`, `APIKeyCheck`, `LoginShell.probe`. Tests: `HostProtocolTests`, `LoginShellTests`, `APIKeyCheckTests`, `SessionCredentialTests` (lookup order, the two refusals, never reading on the main thread).
