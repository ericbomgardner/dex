import { appendFileSync } from "node:fs";

let logFile: string | null = null;

/** Where `log` writes from now on. The app gives the host /dev/null for stderr, so this file is all there is. */
export function logTo(file: string): void {
  logFile = file;
}

export function log(line: string): void {
  if (logFile === null) {
    console.error(`[host] ${line}`);
    return;
  }
  try {
    appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`);
  } catch {
    // A host that can't write its log is still a host worth running.
  }
}

/** What a thrown value says about itself: its `message` where it has one. */
export function why(error: unknown): string {
  const message = typeof error === "object" && error !== null ? (error as { message?: unknown }).message : undefined;
  return String(message ?? error);
}
