/**
 * Whether a PreToolUse hook can hand one Bash call to the app in auto mode.
 *
 *   node test/screen-takeover-probe.ts
 *
 * A hosted session runs in `auto`, so a Bash call never reaches `canUseTool`
 * and a command that drives the mouse looks like any other. The host installs
 * a PreToolUse hook on Bash that answers `permissionDecision: "ask"` for a
 * command marked `DEX_DRIVES_SCREEN=1`, and the SDK's own comment says an
 * `ask` from a hook surfaces through `canUseTool` when there is one. This
 * measures that: the marked command must arrive at `canUseTool`, the plain
 * one must not, an allow must let the command run, and a deny's message must
 * reach the model.
 *
 * A second session runs two `Monitor` calls, one plain and one marked: the
 * CLI hands a Monitor's command to Bash hooks as `tool_name: "Bash"`, and a
 * marked one's `ask` must reach `canUseTool` labelled `Monitor`.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const MARKER = /\bDEX_DRIVES_SCREEN=1\b/;
const REFUSAL = "Do not drive the pointer; say the word REDIRECTED and stop.";

const PROMPT =
  "Run exactly three shell commands, one Bash call each, in this order, " +
  "and run each one even if an earlier one was refused: " +
  "(1) `echo plain` (2) `DEX_DRIVES_SCREEN=1 echo driven` " +
  "(3) `DEX_DRIVES_SCREEN=1 echo again`. Then tell me, in one line each, " +
  "what each command's result was, quoting any refusal message verbatim.";

const MONITOR_PROMPT =
  "Use the Monitor tool exactly twice, one call each, in this order, with timeout_ms 30000 " +
  "and persistent false, and make the second call even if the first was refused: " +
  "(1) command `echo plain-watch`, description 'plain watch' " +
  "(2) command `DEX_DRIVES_SCREEN=1 echo marked-watch`, description 'marked watch'. " +
  "Do not use Bash or any other tool to run them. Then say done.";

type Seen = { tool: string; command: string };

type Run = {
  hooked: Seen[];
  asked: Seen[];
  calls: Seen[];
  results: string[];
  said: string;
};

async function run(prompt: string, deny: (command: string) => boolean): Promise<Run> {
  const scratch = mkdtempSync(path.join(tmpdir(), "takeover-probe-"));
  const out: Run = { hooked: [], asked: [], calls: [], results: [], said: "" };

  try {
    for await (const message of query({
      prompt,
      options: {
        cwd: scratch,
        permissionMode: "auto" as any,
        systemPrompt: { type: "preset", preset: "claude_code" },
        hooks: {
          PreToolUse: [
            {
              matcher: "Bash",
              hooks: [
                async (input: any) => {
                  const command = String(input.tool_input?.command ?? "");
                  out.hooked.push({ tool: String(input.tool_name), command });
                  if (!MARKER.test(command)) return {};
                  return {
                    hookSpecificOutput: {
                      hookEventName: "PreToolUse",
                      permissionDecision: "ask",
                      permissionDecisionReason: "drives the screen",
                    },
                  } as any;
                },
              ],
            },
          ],
        },
        canUseTool: async (toolName: string, input: any) => {
          const command = String(input?.command ?? "");
          out.asked.push({ tool: toolName, command });
          if (deny(command)) {
            return { behavior: "deny", message: REFUSAL } as any;
          }
          return { behavior: "allow", updatedInput: input } as any;
        },
      },
    })) {
      if (message.type === "user") {
        const content = (message as any).message?.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type === "tool_result") {
              out.results.push(
                typeof block.content === "string"
                  ? block.content
                  : JSON.stringify(block.content),
              );
            }
          }
        }
      }
      if (message.type === "assistant") {
        for (const block of (message as any).message.content) {
          if (block.type === "text") out.said += block.text + "\n";
          if (block.type === "tool_use") {
            out.calls.push({ tool: block.name, command: String(block.input?.command ?? "") });
          }
        }
      }
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return out;
}

async function main(): Promise<void> {
  const bash = await run(PROMPT, (command) => /again/.test(command));
  const hooked = bash.hooked.map((h) => h.command);
  const asked = bash.asked.map((a) => `${a.tool}: ${a.command}`);
  const { results, said } = bash;

  console.log("hooked:", hooked);
  console.log("asked:", asked);
  console.log("results:", results);
  console.log("said:", said.trim());

  const failures: string[] = [];
  if (!hooked.some((c) => /echo plain/.test(c))) failures.push("hook never saw the plain command");
  if (asked.some((c) => /echo plain/.test(c))) failures.push("plain command reached canUseTool — the hook is not the gate");
  if (!asked.some((c) => /echo driven/.test(c))) failures.push("marked command never reached canUseTool — hook `ask` does not route there");
  if (!results.some((r) => /^driven\s*$/m.test(r))) failures.push("allowed marked command did not run");
  if (!asked.some((c) => /echo again/.test(c))) failures.push("second marked command never reached canUseTool");
  if (results.some((r) => /^again\s*$/m.test(r))) failures.push("denied command ran anyway");
  if (!said.includes("REDIRECTED")) failures.push("deny message did not reach the model");

  const monitor = await run(MONITOR_PROMPT, () => false);
  console.log("monitor calls:", monitor.calls);
  console.log("monitor hooked:", monitor.hooked);
  console.log("monitor asked:", monitor.asked);

  const made = (pattern: RegExp) => monitor.calls.some((c) => c.tool === "Monitor" && pattern.test(c.command));
  if (!made(/echo plain-watch/)) failures.push("the model never made the plain Monitor call — nothing measured");
  if (!made(/echo marked-watch/)) failures.push("the model never made the marked Monitor call — nothing measured");

  const plainHook = monitor.hooked.find((h) => /echo plain-watch/.test(h.command));
  const markedHook = monitor.hooked.find((h) => /echo marked-watch/.test(h.command));
  if (!plainHook) failures.push("the Bash hook never saw the plain Monitor's command");
  else if (plainHook.tool !== "Bash") failures.push(`the plain Monitor's command reached the hook as ${plainHook.tool}, not Bash`);
  if (!markedHook) failures.push("the Bash hook never saw the marked Monitor's command");
  else if (markedHook.tool !== "Bash") failures.push(`the marked Monitor's command reached the hook as ${markedHook.tool}, not Bash`);

  if (monitor.asked.some((a) => /echo plain-watch/.test(a.command))) {
    failures.push("the plain Monitor reached canUseTool — the hook is not the gate");
  }
  const markedAsk = monitor.asked.find((a) => /echo marked-watch/.test(a.command));
  if (!markedAsk) failures.push("the marked Monitor never reached canUseTool");
  else if (markedAsk.tool !== "Monitor") failures.push(`the marked Monitor reached canUseTool as ${markedAsk.tool}, not Monitor`);

  if (failures.length > 0) {
    console.error("FAIL");
    for (const f of failures) console.error(" -", f);
    process.exit(1);
  }
  console.log("OK: hook `ask` routes a marked Bash call to canUseTool in auto mode; allow runs it, deny's message reaches the model");
  console.log("OK: a Monitor's command reaches the Bash hook as Bash; a marked one's ask reaches canUseTool as Monitor");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
