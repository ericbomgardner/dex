import { existsSync, readdirSync, rmSync } from "node:fs";
import * as path from "node:path";

import { configDirectory } from "./support.ts";

/**
 * Every file the CLI keeps under a session's id: the transcript in each project
 * folder and the folder beside it with subagent transcripts and spilled tool
 * results.
 */
export function eraseTranscript(sessionId: string, directory = configDirectory()): boolean {
  if (!sessionId || sessionId.includes("/") || sessionId.startsWith(".")) return false;
  const projects = path.join(directory, "projects");
  let folders: string[];
  try {
    folders = readdirSync(projects);
  } catch {
    return false;
  }
  let found = false;
  for (const folder of folders) {
    if (folder.startsWith(".")) continue;
    for (const name of [`${sessionId}.jsonl`, sessionId]) {
      const target = path.join(projects, folder, name);
      if (!existsSync(target)) continue;
      found = true;
      rmSync(target, { recursive: true, force: true });
    }
  }
  return found;
}
