import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

import { isAlive } from "./pid.ts";

/** The host's environment with no credential in it, so a keyed session can run on nothing but its key. */
export function keylessEnvironment(base: NodeJS.ProcessEnv = process.env): Record<string, string> {
  const env = { ...(base as Record<string, string>) };
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_AUTH_TOKEN;
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  return env;
}

const KEY_FILE_PREFIX = "dex-key-";

/**
 * A session's API key, read by its CLI through `apiKeyHelper` rather than from
 * its environment, which the session's Bash, hooks and MCP servers inherit
 * (`api-key-over-login-probe.ts`). Only its owner can read it, and it goes
 * with the session.
 */
export class KeyFile {
  readonly path: string;

  constructor(apiKey: string, directory: string = tmpdir()) {
    const folder = mkdtempSync(path.join(directory, `${KEY_FILE_PREFIX}${process.pid}-`));
    this.path = path.join(folder, "key");
    writeFileSync(this.path, `${apiKey}\n`, { mode: 0o600 });
    if (!exitHooked) {
      process.once("exit", removeKeyFiles);
      exitHooked = true;
    }
    liveKeyFiles.add(this);
  }

  get helper(): string {
    return `/bin/cat '${this.path.replace(/'/g, `'\\''`)}'`;
  }

  remove(): void {
    liveKeyFiles.delete(this);
    rmSync(path.dirname(this.path), { recursive: true, force: true });
  }
}

const liveKeyFiles = new Set<KeyFile>();
let exitHooked = false;

/**
 * Every key file this process still holds, synchronously. A host that exits
 * on a signal never reaches the end of its sessions' drains, where each
 * removes its own, so this also runs on any `process.exit`.
 */
export function removeKeyFiles(): void {
  for (const file of [...liveKeyFiles]) file.remove();
}

/**
 * Key files left by a host that died before its sessions ended. A pid that is
 * a zombie, or a process started after the folder was, isn't that host.
 */
export function sweepKeyFiles(directory: string = tmpdir()): void {
  for (const name of readdirSync(directory)) {
    if (!name.startsWith(KEY_FILE_PREFIX)) continue;
    const pid = Number(name.slice(KEY_FILE_PREFIX.length).split("-")[0]);
    if (!pid) continue;
    const folder = path.join(directory, name);
    if (holdsKeyFile(pid, statSync(folder).mtimeMs)) continue;
    rmSync(folder, { recursive: true, force: true });
  }
}

function holdsKeyFile(pid: number, writtenAt: number): boolean {
  if (!isAlive(pid)) return false;
  const reading = spawnSync("ps", ["-o", "stat=,lstart=", "-p", String(pid)], { encoding: "utf8" });
  const match = /^\s*(\S+)\s+(.+?)\s*$/.exec(reading.stdout ?? "");
  if (!match) return true;
  if (match[1].startsWith("Z")) return false;
  const started = Date.parse(match[2]);
  // lstart is to the second, and the folder is written within its host's life.
  return Number.isNaN(started) || started <= writtenAt + 1000;
}
