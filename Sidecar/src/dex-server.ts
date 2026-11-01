import * as path from "node:path";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

import { listSessions } from "./fleet.ts";
import { why } from "./log.ts";
import { SUPPORT_FOLDER, configDirectory } from "./support.ts";

/** The host's own MCP server, on every session. Not one of the user's, so not in its readings. */
export const DEX_SERVER = "dex";
export const START_SESSION_TOOL = `mcp__${DEX_SERVER}__start_session`;
export const LIST_SESSIONS_TOOL = `mcp__${DEX_SERVER}__list_sessions`;

export interface LaunchRequest {
  cwd: string;
  prompt: string;
  name?: string;
  parent: string;
}

/** Starts a session through the app and answers its key, or throws why it couldn't. */
export type Launcher = (request: LaunchRequest) => Promise<string>;

export function dexServer(parent: string, launch: Launcher, self: () => string | null) {
  const fleetFile = path.join(configDirectory(), SUPPORT_FOLDER, "fleet.json");
  const registryDirectory = path.join(configDirectory(), "sessions");
  return createSdkMcpServer({
    name: DEX_SERVER,
    tools: [
      tool(
        "list_sessions",
        "List the other Dex sessions running on this Mac: the name to message each by with SendMessage, its title, " +
          "folder and branch, what it is doing, and its session id. ListAgents shows names only; use this to pick which session to message.",
        {},
        async () => ({ content: [{ type: "text", text: listSessions(fleetFile, registryDirectory, self()) }] }),
      ),
      tool(
        "start_session",
        "Start a separate Dex session that works on its own and shows in Dex as its own row, where the user talks to it directly. " +
          "Use it when the user asks for work to be split into sessions of its own; otherwise prefer a subagent. " +
          "It hears nothing of this conversation, so the prompt has to stand on its own.",
        {
          cwd: z
            .string()
            .describe("Absolute path of the folder it works in: the project's own checkout, not this session's worktree."),
          prompt: z.string().describe("Its first message."),
          name: z.string().optional().describe("A short title for its row."),
        },
        async ({ cwd, prompt, name }) => {
          try {
            const key = await launch({ cwd, prompt, name, parent });
            return {
              content: [
                {
                  type: "text",
                  text: `Started${name ? ` "${name}"` : ""} as session ${key}. It runs on its own; the user will talk to it in Dex.`,
                },
              ],
            };
          } catch (error) {
            return {
              content: [{ type: "text", text: why(error) }],
              isError: true,
            };
          }
        },
      ),
    ],
  });
}
