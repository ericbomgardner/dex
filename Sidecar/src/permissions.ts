import type { PermissionResult, PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";

import type { Answer, AskOption } from "./protocol.ts";

const REDIRECT_MESSAGE =
  "Refused by Dex: this would drive the user's pointer or keyboard while they are using the machine. " +
  "Do it another way — an Accessibility press (AXUIElementPerformAction) or CGEvent.postToPid on the " +
  "target process needs neither the pointer nor focus, and a window can be captured by id without " +
  "activating it. If nothing else can do it, ask the user when to run it instead of retrying.";

/** What `decisionFor` needs of the ask it answers. */
export interface AskedFor {
  input: Record<string, unknown>;
  suggestions: PermissionUpdate[];
}

/**
 * The rules "Allow for this session" hands the CLI: the ones it suggested
 * saving, which for WebFetch is the domain, kept for the session only. The CLI
 * still runs its other checks against them, which a host-held grant would skip.
 */
export function sessionRules(suggestions: PermissionUpdate[]): PermissionUpdate[] {
  return suggestions
    .filter((suggestion) => suggestion?.type === "addRules" && suggestion?.behavior === "allow")
    .map((suggestion) => ({ ...suggestion, destination: "session" }));
}

/**
 * The option id is what `decisionFor` reads; the kind is for the app. An app
 * older than `allow_session` takes an unknown kind for a refusal and would
 * answer a typed-over card with it, so that option goes out as `allow_always`.
 */
export function permissionOptions(suggestions: PermissionUpdate[], grantable: boolean): AskOption[] {
  const options: AskOption[] = [
    grantable
      ? { optionId: "allow_session", name: "Allow for this session", kind: "allow_always" }
      : { optionId: "allow_once", name: "Allow", kind: "allow_once" },
  ];
  if (
    suggestions.some((suggestion) => suggestion?.destination === "localSettings")
  ) {
    options.push({
      optionId: "allow_always",
      name: "Allow every time",
      kind: "allow_always",
    });
  }
  options.push({ optionId: "reject_once", name: "Deny", kind: "reject_once" });
  return options;
}

/**
 * `redirect` is a refusal that says what to do instead. The words are the
 * host's so the app only ever picks an option, and so a refusal chosen from
 * the card and one the app makes on its own read the same to the model.
 */
export function takeoverOptions(): AskOption[] {
  return [
    { optionId: "allow_once", name: "Go ahead", kind: "allow_once" },
    { optionId: "redirect", name: "Not with my pointer", kind: "reject_once" },
    { optionId: "reject_once", name: "Not now", kind: "reject_once" },
  ];
}

export function decisionFor(message: Answer, parked: AskedFor): PermissionResult {
  if (message.kind === "question") {
    // A response is not a fuller answer but a different one: measured against
    // CLI v2.1.227, the result it writes is "The user responded: …" and carries
    // nothing else, so answers and notes sent beside it are dropped. Kept apart
    // here so what is thrown away is thrown away in one place.
    if (message.response) {
      return {
        behavior: "allow",
        updatedInput: {
          questions: parked.input.questions ?? [],
          answers: {},
          response: message.response,
        },
      };
    }

    return {
      behavior: "allow",
      updatedInput: {
        questions: parked.input.questions ?? [],
        answers: message.answers,
        ...(message.annotations ? { annotations: message.annotations } : {}),
      },
    };
  }

  // Anything that isn't a recognised allow is a denial, so an option this host
  // no longer offers can never be replayed into an approval.
  if (message.optionId === "redirect") {
    return { behavior: "deny", message: message.message ?? REDIRECT_MESSAGE };
  }
  if (
    message.optionId !== "allow_once" &&
    message.optionId !== "allow_session" &&
    message.optionId !== "allow_always"
  ) {
    return {
      behavior: "deny",
      message: message.message ?? "Denied from Dex",
    };
  }

  const remembered =
    message.optionId === "allow_always"
      ? parked.suggestions.filter(
          (suggestion) => suggestion?.destination === "localSettings",
        )
      : message.optionId === "allow_session"
        ? sessionRules(parked.suggestions)
        : [];

  return {
    behavior: "allow",
    updatedInput: parked.input,
    ...(remembered.length > 0 ? { updatedPermissions: remembered } : {}),
  };
}
