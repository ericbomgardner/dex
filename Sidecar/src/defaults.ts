import { resolveSettings, type ResolvedSettings } from "@anthropic-ai/claude-agent-sdk";

import type { EffortSource } from "./protocol.ts";

/**
 * The settings a session started in `cwd` would run under, with nothing of the
 * app's own mixed in — what the app sends rides in the flag layer, above every
 * source read here, so leaving it out is what makes this answer what Default
 * means rather than what was last picked.
 */
export async function resolveDefaults(
  cwd: string,
): Promise<{
  outputStyle: string | null;
  effort: string | null;
  model?: string | null;
  efforts?: EffortSource[];
}> {
  if (typeof resolveSettings !== "function") {
    // model deliberately absent rather than null: null says "no file names
    // one" and the chip asserts the built-in default on it. Unasked stays
    // unanswered.
    return { outputStyle: null, effort: null };
  }
  const resolved: ResolvedSettings | undefined = await resolveSettings({ cwd });
  return {
    outputStyle: resolved?.effective?.outputStyle ?? null,
    effort: resolved?.effective?.effortLevel ?? null,
    // A folder can move the model without the model key: env.ANTHROPIC_MODEL
    // is honoured by the CLI the session runs, so it counts as the pin here.
    model: resolved?.effective?.model ?? resolved?.effective?.env?.ANTHROPIC_MODEL ?? null,
    efforts: effortSources(resolved?.sources),
  };
}

export function effortSources(sources: ResolvedSettings["sources"] | undefined): EffortSource[] {
  if (!Array.isArray(sources)) return [];
  return sources
    .map((entry) => {
      const models: Record<string, string> = {};
      for (const [name, settings] of Object.entries(entry?.settings?.modelSettings ?? {})) {
        if (typeof settings?.effortLevel === "string") models[name] = settings.effortLevel;
      }
      const effort = entry?.settings?.effortLevel;
      return {
        source: String(entry?.source ?? ""),
        effort: typeof effort === "string" ? effort : null,
        models,
      };
    })
    .filter((entry) => entry.effort !== null || Object.keys(entry.models).length > 0)
    .reverse();
}
