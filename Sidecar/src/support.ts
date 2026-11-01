import { homedir } from "node:os";
import path from "node:path";

/** The folder under the config directory that holds the host's socket, its state and the fleet file. */
export const SUPPORT_FOLDER = "dex";

export function configDirectory(): string {
  return process.env.CLAUDE_CONFIG_DIR && process.env.CLAUDE_CONFIG_DIR.length > 0
    ? process.env.CLAUDE_CONFIG_DIR
    : path.join(homedir(), ".claude");
}
