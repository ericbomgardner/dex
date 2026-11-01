import { readdirSync, readFileSync } from "node:fs";
import * as path from "node:path";

import { isAlive } from "./pid.ts";

/** One session as the app publishes it in `fleet.json`; only what the listing prints. */
interface FleetEntry {
  sessionId?: string;
  name: string;
  address?: string;
  state?: string;
  waitingFor?: string;
  doing: string;
  cwd: string;
  branch?: string;
  merge?: { summary: string };
}

/**
 * The other sessions an agent can message, off the fleet file the app writes.
 * `ListAgents` prints a session's registry name and nothing of what it is
 * doing or where, so an agent picking one to message needs this beside it.
 */
export function listSessions(fleetFile: string, registryDirectory: string, self: string | null): string {
  let sessions: FleetEntry[];
  try {
    sessions = JSON.parse(readFileSync(fleetFile, "utf8")).sessions ?? [];
  } catch {
    return "Dex hasn't published its session list on this Mac. Use ListAgents instead.";
  }
  // The app writes the fleet only while it runs, and the hosts outlive it.
  const live = liveRegistry(registryDirectory);
  const others = sessions.filter((session) => !self || session.sessionId !== self);
  const reachable = others.flatMap((session) => {
    const record = session.sessionId ? live.get(session.sessionId) : undefined;
    if (!record) return [];
    const moved = record.cwd !== undefined && record.cwd !== session.cwd;
    return [{ ...session, address: record.name, ...(moved ? { cwd: record.cwd!, branch: undefined } : {}) }];
  });
  const entries = reachable.map((session) => {
    const where = session.branch ? `${session.cwd} (branch ${session.branch})` : session.cwd;
    const state = session.waitingFor ? `waiting on ${session.waitingFor}` : (session.state ?? "unknown");
    return [
      `- ${session.address}`,
      ...(session.name === session.address ? [] : [`  title: ${session.name}`]),
      `  ${state} · ${where}${session.merge ? ` · ${session.merge.summary}` : ""}`,
      `  doing: ${session.doing}`,
      `  session id: ${session.sessionId ?? "not yet known"}`,
    ].join("\n");
  });
  const stopped = others.length - reachable.length;
  const tail =
    stopped > 0
      ? `\n\n${stopped} more ${stopped === 1 ? "session is" : "sessions are"} not running and can't be messaged.`
      : "";
  if (entries.length === 0) return `No other Dex session is running.${tail}`;
  return `Message one with SendMessage, passing the name after the dash as \`to\`.\n\n${entries.join("\n\n")}${tail}`;
}

/** Name and folder by session id, from each CLI's own record, for processes still alive. */
function liveRegistry(directory: string): Map<string, { name: string; cwd?: string }> {
  const live = new Map<string, { name: string; cwd?: string }>();
  let names: string[] = [];
  try {
    names = readdirSync(directory).filter((name) => /^\d+\.json$/.test(name));
  } catch {
    return live;
  }
  for (const name of names) {
    try {
      const record = JSON.parse(readFileSync(path.join(directory, name), "utf8"));
      if (typeof record.sessionId !== "string" || typeof record.name !== "string" || !record.name) continue;
      if (typeof record.pid === "number" && !isAlive(record.pid)) continue;
      live.set(record.sessionId, { name: record.name, cwd: typeof record.cwd === "string" && record.cwd ? record.cwd : undefined });
    } catch {}
  }
  return live;
}
