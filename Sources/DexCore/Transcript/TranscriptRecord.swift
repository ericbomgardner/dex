import Foundation

/// One line of a `~/.claude/projects/**/*.jsonl` transcript, kept to the fields a
/// reading view needs. The file carries a dozen other record types (`mode`,
/// `last-prompt`, `file-history-snapshot`); those decode to `nil` and are dropped.
struct TranscriptRecord: Decodable {
    let type: String
    /// On `system` records: `compact_boundary`, and whatever else the CLI adds.
    let subtype: String?
    let uuid: String?
    let timestamp: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let message: RawMessage?
    let toolUseResult: RawToolResult?

    /// The CLI's mark on a turn it wrote because the request failed — an
    /// overload, a dropped connection, a session limit, a login it wants. Set on
    /// every such record and on nothing else, across a thousand-odd transcripts.
    /// **CLI v2.1.234**.
    let isApiErrorMessage: Bool?

    /// How hard the turn thought, written beside `message` rather than in it.
    /// Only on `assistant` records, and on a subagent's turns it is the agent's
    /// own level rather than the session's. **CLI v2.1.243** surfaced the pair
    /// in `/tasks`; the field itself goes back to at least v2.1.237.
    let effort: String?

    /// The title the CLI generated for this session, carried on a record of its
    /// own (`{"type":"ai-title","aiTitle":"…"}`). Rewritten rather than appended
    /// to, so the newest one is the CLI's current name for it. **CLI v2.1.227**; `Scripts/session-digest-probe.py` says whether it
    /// still does.
    let aiTitle: String?

    /// The name the user gave the session, `{"type":"custom-title","customTitle":"…"}`.
    /// Outranks `aiTitle` wherever both are written. `Sidecar/test/rename-probe.ts`.
    let customTitle: String?

    /// What became of a message in the session's queue, on a record of its own:
    /// `enqueue` as it goes in, carrying what was typed, and `dequeue` or
    /// `remove` as it comes out. **CLI v2.1.228**.
    let operation: String?

    /// The queued message, held as whatever was written rather than as a string.
    /// The CLI writes a turn's content as a block array as readily as a string,
    /// and a `String?` that met one would throw away the line instead of the
    /// field — losing a `remove` leaves its message waiting on screen for good.
    let content: JSONValue?

    var queuedText: String? { content?.stringValue }

    /// What the CLI hands the model alongside a turn. The one a reading view
    /// wants is `queued_command`, which is a queued message the session took
    /// into the turn it was already running.
    let attachment: RawAttachment?

    /// Where a message came from, when it wasn't typed here. Written on a user
    /// turn delivered from another session, and on the attachment when one was
    /// absorbed into a running turn. **CLI v2.1.263** —
    /// `Sidecar/test/cross-session-message-probe.ts` says whether it still is.
    let origin: RawOrigin?

    /// The CLI's mark on the user record it writes after a compaction: the
    /// summary handed to the model in place of everything dropped. Not `isMeta`,
    /// so without this it reads as a wall of text you typed. **CLI v2.1.42** —
    /// `Sidecar/test/compaction-probe.ts` says whether it still does.
    let isCompactSummary: Bool?

    /// Beside a `system/compact_boundary` record. `postTokens` arrived around
    /// v2.1.146; the oldest boundaries seen carry `preTokens` only.
    let compactMetadata: RawCompactMetadata?

    struct RawCompactMetadata: Decodable {
        let trigger: String?
        let preTokens: Int?
        let postTokens: Int?
    }

    var isCompactBoundary: Bool { type == "system" && subtype == "compact_boundary" }

    /// What a local command printed, written as a user turn after the command's
    /// own. Only local commands get one, and nothing answers it. Asked only of
    /// a record that is nothing but the output, as `isInterruption` is.
    var isLocalCommandOutput: Bool {
        guard let content = message?.content, content.count == 1,
              case .text(let text) = content[0] else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<local-command-stdout>")
            && trimmed.hasSuffix("</local-command-stdout>")
    }

    struct RawOrigin: Decodable {
        let kind: String?
        /// The sending session's messaging name — the one `ListAgents` prints.
        /// On a subagent's hand-back it is the agent's type instead (CLI
        /// v2.1.286), never read: a hand-back is dropped rather than drawn.
        let name: String?
        /// The sender's address. For a subagent it is the agent id, the same
        /// one its launch's `toolUseResult.agentId` names.
        let from: String?
        /// The CLI's mark on a subagent's final report, delivered as a message
        /// rather than as the result of the call that delegated the work.
        /// **CLI v2.1.278**.
        let handback: Bool?
        /// The message as sent, without the wrapper the CLI puts around it.
        let body: String?

        var isPeer: Bool { kind == "peer" }

        var isHandback: Bool { handback == true }
    }

    struct RawAttachment: Decodable {
        let type: String?
        let prompt: String?
        /// A pasted image turns `prompt` into a block array: the `[Image #1]`
        /// text, then the image. Read as a string, the whole message was lost.
        let images: [RawBlock]
        /// `prompt` for something a person typed. The queue also carries what
        /// the CLI puts there itself — `task-notification` and the like.
        let commandMode: String?
        let origin: RawOrigin?

        private enum CodingKeys: String, CodingKey { case type, prompt, commandMode, origin }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                type = nil
                prompt = nil
                images = []
                commandMode = nil
                origin = nil
                return
            }

            type = try? container.decode(String.self, forKey: .type)
            if let text = try? container.decode(String.self, forKey: .prompt) {
                prompt = text
                images = []
            } else if let blocks = try? container.decode([RawBlock].self, forKey: .prompt) {
                let texts = blocks.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }
                prompt = texts.isEmpty ? nil : texts.joined(separator: "\n")
                images = blocks.filter {
                    if case .image = $0 { return true }
                    return false
                }
            } else {
                prompt = nil
                images = []
            }
            commandMode = try? container.decode(String.self, forKey: .commandMode)
            origin = try? container.decode(RawOrigin.self, forKey: .origin)
        }
    }

    /// The tool result again, structured, sitting beside the message rather than
    /// inside it. Only what a reading view can use is picked out — the rest of
    /// the payload is the result text over again.
    struct RawToolResult: Decodable {
        let answers: [String: String]
        let notes: [String: String]
        let response: String?
        let subagent: SubagentTotals?
        /// A background agent's call comes back as soon as the agent is launched.
        /// The receipt says so; the work is still going. **CLI v2.1.221**.
        let isLaunch: Bool
        /// An approved plan the user rewrote in the dialog on the way through.
        /// **CLI v2.1.92**.
        let planWasEdited: Bool
        /// Names the transcript the subagent wrote, which is the only link
        /// between a delegating call and the conversation it set off.
        /// **CLI v2.1.227** — see `SubagentTranscript`.
        let agentID: String?

        /// What a `TaskOutput` call collected: a background task's own result,
        /// fetched rather than waited for. **CLI v2.1.257**.
        let collected: CollectedTask?

        private enum CodingKeys: String, CodingKey {
            case answers, annotations, response, status, planWasEdited, agentId
            case totalToolUseCount, totalTokens, totalDurationMs
            case retrieval_status, task
        }

        /// A background task as `TaskOutput` reported it. The status is the
        /// task's, not the retrieval's: a retrieval can succeed and report a
        /// task still running.
        struct CollectedTask: Decodable {
            let taskID: String
            let status: String

            private enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case status
            }

            /// The statuses that mean the task is over, listed rather than
            /// inferred from what isn't `running`. Both readings go wrong on a
            /// status the CLI adds, and only this one goes wrong safely: an
            /// unknown word leaves the row running until something else settles
            /// it, where the other would call a working agent finished.
            private static let over: Set<String> = ["completed", "failed", "killed", "cancelled"]

            var isOver: Bool { Self.over.contains(status) }
            var failed: Bool { status != "completed" }
        }

        private struct Annotation: Decodable {
            let notes: String?
        }

        init(from decoder: any Decoder) throws {
            // Most tools report something other than an object here, and a throw
            // would take the whole line down with it.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                answers = [:]
                notes = [:]
                response = nil
                subagent = nil
                isLaunch = false
                planWasEdited = false
                agentID = nil
                collected = nil
                return
            }

            let given = (try? container.decode([String: JSONValue].self, forKey: .answers)) ?? [:]
            answers = given.compactMapValues { Self.text($0) }

            let annotations = (try? container.decode([String: Annotation].self, forKey: .annotations)) ?? [:]
            notes = annotations.compactMapValues(\.notes)
            response = (try? container.decode(String.self, forKey: .response)).flatMap { $0.isEmpty ? nil : $0 }

            subagent = Self.totals(container)
            isLaunch = (try? container.decode(String.self, forKey: .status)) == "async_launched"
            planWasEdited = (try? container.decode(Bool.self, forKey: .planWasEdited)) ?? false
            agentID = try? container.decode(String.self, forKey: .agentId)

            // A retrieval that didn't come back with the task says nothing about
            // it — a blocking `TaskOutput` that hits its own timeout reports the
            // failure here while the agent carries on working.
            let retrieved = (try? container.decode(String.self, forKey: .retrieval_status)) == "success"
            collected = retrieved
                ? try? container.decode(CollectedTask.self, forKey: .task)
                : nil
        }

        /// The three the terminal prints together, so they are read together:
        /// half a line is worse than none. Written by **CLI v2.1.221** —
        /// `Scripts/subagent-totals-probe.py` says whether it still writes them.
        private static func totals(
            _ container: KeyedDecodingContainer<CodingKeys>
        ) -> SubagentTotals? {
            guard let toolUses = try? container.decode(Int.self, forKey: .totalToolUseCount),
                  let tokens = try? container.decode(Int.self, forKey: .totalTokens),
                  let milliseconds = try? container.decode(Double.self, forKey: .totalDurationMs)
            else { return nil }

            return SubagentTotals(
                toolUses: toolUses,
                tokens: tokens,
                duration: milliseconds / 1_000
            )
        }

        private static func text(_ value: JSONValue) -> String? {
            if let scalar = value.scalarText { return scalar }
            guard let items = value.arrayValue else { return nil }
            let joined = items.compactMap(\.scalarText).joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }
    }

    struct RawMessage: Decodable {
        let content: [RawBlock]

        /// On assistant records only.
        let model: String?

        /// What the turn read. On assistant records only, and the field names
        /// are the API's own — **CLI v2.1.227**, the same three
        /// `Scripts/maintainer/token-audit.py` adds up. A rename here reads as a session
        /// carrying nothing rather than as an error.
        let usage: Usage?

        struct Usage: Decodable {
            let input: Int
            let cacheRead: Int
            let cacheCreation: Int

            private enum CodingKeys: String, CodingKey {
                case input = "input_tokens"
                case cacheRead = "cache_read_input_tokens"
                case cacheCreation = "cache_creation_input_tokens"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                input = (try? container.decode(Int.self, forKey: .input)) ?? 0
                cacheRead = (try? container.decode(Int.self, forKey: .cacheRead)) ?? 0
                cacheCreation = (try? container.decode(Int.self, forKey: .cacheCreation)) ?? 0
            }

            var context: Int { input + cacheRead + cacheCreation }
        }

        private enum CodingKeys: String, CodingKey { case content, model, usage }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [.text(text)]
            } else {
                content = (try? container.decode([RawBlock].self, forKey: .content)) ?? []
            }
            model = try? container.decode(String.self, forKey: .model)
            usage = try? container.decode(Usage.self, forKey: .usage)
        }
    }

    /// A content block. Unknown types decode to `.other` rather than failing the
    /// line — the transcript format gains block types between releases.
    enum RawBlock: Decodable {
        case text(String)
        case thinking(text: String, isNarration: Bool)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, text: String, isError: Bool)
        case image(mediaType: String?, bytes: Int)
        case other

        private enum CodingKeys: String, CodingKey {
            case type, text, thinking, id, name, input, signature, source
            case toolUseID = "tool_use_id"
            case content
            case isError = "is_error"
        }

        private struct Source: Decodable {
            let mediaType: String?
            let data: String?

            private enum CodingKeys: String, CodingKey {
                case mediaType = "media_type"
                case data
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try? container.decode(String.self, forKey: .type) {
            case "text":
                self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
            case "thinking":
                self = .thinking(
                    text: (try? container.decode(String.self, forKey: .thinking)) ?? "",
                    isNarration: NarrationSignature.isNarration(
                        try? container.decode(String.self, forKey: .signature)
                    )
                )
            case "tool_use":
                self = .toolUse(
                    id: (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString,
                    name: (try? container.decode(String.self, forKey: .name)) ?? "Tool",
                    input: (try? container.decode(JSONValue.self, forKey: .input)) ?? .null
                )
            case "tool_result":
                self = .toolResult(
                    toolUseID: (try? container.decode(String.self, forKey: .toolUseID)) ?? "",
                    text: Self.resultText(container),
                    isError: (try? container.decode(Bool.self, forKey: .isError)) ?? false
                )
            case "image":
                let source = try? container.decode(Source.self, forKey: .source)
                self = .image(
                    mediaType: source?.mediaType,
                    bytes: source?.data.map(TranscriptImage.decodedSize(ofBase64:)) ?? 0
                )
            default:
                self = .other
            }
        }

        /// A tool result's content is a bare string for most tools and a block
        /// array for the ones that can return images. An image stands in the
        /// text as a line naming it, or a Read of a screenshot comes back empty.
        private static func resultText(_ container: KeyedDecodingContainer<CodingKeys>) -> String {
            if let text = try? container.decode(String.self, forKey: .content) { return text }
            guard let blocks = try? container.decode([JSONValue].self, forKey: .content) else {
                return ""
            }
            return blocks.compactMap { block -> String? in
                guard let fields = block.objectValue else { return nil }
                if fields["type"]?.stringValue == "image" {
                    let source = fields["source"]?.objectValue
                    let bytes = source?["data"]?.stringValue.map(TranscriptImage.decodedSize(ofBase64:))
                    let label = TranscriptImage.label(
                        mediaType: source?["media_type"]?.stringValue, bytes: bytes ?? 0
                    )
                    return "[\(label)]"
                }
                return fields["text"]?.stringValue
            }
            .joined(separator: "\n")
        }
    }

    static func decode(_ line: Data) -> TranscriptRecord? {
        try? JSONDecoder().decode(TranscriptRecord.self, from: line)
    }

    var role: TranscriptRole? {
        switch type {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    var at: Date? { TranscriptTimestamp.parse(timestamp) }

    /// A turn Claude Code composed itself rather than got back from the API. It
    /// says so where the model id goes, which is the only mark the benign ones
    /// carry — `isApiErrorMessage` covers the failures alone.
    var isSynthetic: Bool { message?.model == TranscriptText.syntheticModel }

    /// What this turn was carrying, or nil where the record isn't a turn that
    /// read anything. A turn reporting nothing on all three fields is skipped
    /// rather than read as an empty context, so the reading keeps looking back
    /// for one that says something.
    var context: SessionContext? {
        guard let usage = message?.usage, usage.context > 0 else { return nil }
        return SessionContext(tokens: usage.context, model: message?.model)
    }
}
