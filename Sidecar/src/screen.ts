import type { ScreenDrive } from "./protocol.ts";

/**
 * The mark a session puts on a command that drives the user's screen — a
 * synthetic click, a keystroke, an `activate` — so the app can read it as one.
 * The hook below also catches the shapes sessions used before the mark
 * existed, but that is a net for old habits: a session that invents a new tool
 * name slips past it, and the mark is the contract.
 */
export const SCREEN_MARKER = /\bDEX_DRIVES_SCREEN=1\b/;

const SCREEN_HABITS =
  /cliclick|xdotool|keystroke\s+("|return\b|tab\b|space\b)|key code\s+\d|cghidEventTap|SessionEventTap|to activate|activate application|(?<![\w./-])(click|drag|scroll)\s+-?\d+(?![\d>])/;

/**
 * The line of a shell command that drives the screen, or null for one that
 * doesn't. The mark is looked for first: a session that marked its command
 * said which line it meant, and the net's word only stands in where it didn't.
 * A Monitor's command reaches the Bash hook as `Bash` but its ask arrives
 * named `Monitor` (test/screen-takeover-probe.ts).
 */
export function screenDrive(toolName: string, input: unknown): ScreenDrive | null {
  if (toolName !== "Bash" && toolName !== "Monitor") return null;
  const command = String((input as { command?: unknown } | null)?.command ?? "");
  const found = SCREEN_MARKER.exec(command) ?? SCREEN_HABITS.exec(command);
  if (!found) return null;
  const start = command.lastIndexOf("\n", found.index) + 1;
  const end = command.indexOf("\n", found.index);
  return {
    line: command.slice(start, end === -1 ? command.length : end).trim(),
    match: found[0],
  };
}

export function drivesScreen(toolName: string, input: unknown): boolean {
  return screenDrive(toolName, input) !== null;
}
