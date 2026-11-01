/**
 * What a probe's `start` requests carry so its sessions run on an API key, as
 * smoke's do: `ANTHROPIC_API_KEY`, handed to the host as `apiKey`, which the
 * host gives the CLI through `apiKeyHelper` (docs/claude-code/api-key-over-login.md).
 */
export function startCredential(probe: string): { apiKey?: string } {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error(`${probe}: set ANTHROPIC_API_KEY; its sessions run on it`);
    process.exit(2);
  }
  return { apiKey };
}

/** The exit code a probe ends with when what it measures isn't on this machine; `recheck.sh` counts it as skipped. */
export const SKIPPED = 77;
