# Side questions (SDK 0.3.283, CLI v2.1.283)

Probe: `Sidecar/test/side-question-probe.ts` — asks side questions of a running session, idle and mid-turn, and checks what the transcript and the next turn make of them.

`/btw` in the terminal opens a panel, so typed at a hosted session it is no use. The same thing is on `Query` as `askSideQuestion(question, { history, signal })`, undocumented, which sends the CLI's `side_question` control request and resolves to `{ response, synthetic, refusalFallback? }` (`response` null where nothing came back).

What it does, measured:

- **It sees the conversation.** A word set in an earlier turn comes back.
- **It leaves no record.** The transcript doesn't grow and never names the question.
- **The session never hears it.** A later turn doesn't know what was said in it.
- **It forgets its own earlier answers** unless they are passed back as `history: [{ question, response }]`. The app keeps the aside and sends it each time.
- **It answers mid-turn** in under a second on haiku, and the turn it cut into finishes normally.
- **It runs no tools.** The CLI's system reminder tells the model so, and asked to read a file it says to ask in the main conversation.

The host passes it through as the `side` request (capability `side`) and answers with `response` on the reply. The app answers `/btw …` in the composer itself and never sends it to the CLI.

Code: `askSideQuestion` in `session.ts`, `side` in `host.ts`, `HostRequest.side`, `Aside`, `SessionPane.askAside`, `AsideCard`. Tests: `AsideTests`, `HostProtocolTests`, `smoke.ts`.
