/**
 * When a host that has to go can go without taking work with it. A host's exit
 * kills every CLI it runs, and what was in flight is never answered.
 */

/** How long nothing may have happened before such a host goes, past every session being settled. */
export const QUIET_BEFORE_EXIT_MS = 60_000;

export interface Holder {
  state: string;
  runningTasks(): unknown[];
  /** A turn is coming that has not said so yet: a send taken, or an agent's report the CLI has still to answer. */
  turnOwed: boolean;
}

let lastActivity = Date.now();

/** Something happened: an SDK message drained, a request handled. */
export function stirred(at: number = Date.now()): void {
  lastActivity = at;
}

export function holdsWork(session: Holder): boolean {
  return (
    session.state === "starting" ||
    session.state === "running" ||
    session.state === "compacting" ||
    session.state === "asking" ||
    session.turnOwed ||
    session.runningTasks().length > 0
  );
}

export function mayExit(
  sessions: Iterable<Holder>,
  now: number = Date.now(),
  quietMs: number = QUIET_BEFORE_EXIT_MS,
): boolean {
  for (const session of sessions) if (holdsWork(session)) return false;
  return now - lastActivity >= quietMs;
}
