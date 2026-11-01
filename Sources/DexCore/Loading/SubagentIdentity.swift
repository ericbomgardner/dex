import Foundation

/// Which model a subagent actually ran on, and how hard it thought.
///
/// The CLI picks it — the per-call model, the agent's frontmatter, or the
/// session's own — and never says which it landed on. That matters more from
/// **CLI v2.1.247**, which made a subagent whose first call 404s fall down the
/// session's fallback model chain instead of dying: a model id that goes away
/// is now a quiet demotion rather than a loud failure, and this reading is the
/// only thing that would notice.
///
/// Read from the agent's own transcript, never from the parent's — the parent
/// records its own `effort` on its own turns and says nothing about its
/// agents'. Both fields sit on `assistant` records and they do not sit
/// together: the model is inside `message`, the effort is beside it at the top
/// level. **CLI v2.1.243** put the pair in `/tasks` and the agent dialogs; the
/// records have carried it back to at least v2.1.237.
public struct SubagentIdentity: Sendable, Hashable {

    /// As `ModelName` reads it — `Opus 5`, not `claude-opus-5`.
    public let model: String

    /// The bare level the CLI wrote (`xhigh`), or nil where the turn named
    /// none. Not defaulted to the session's: an agent whose effort cannot be
    /// read should say less, not guess.
    public let effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }

    /// What goes on the row, ahead of the totals the terminal prints.
    public var summary: String {
        [model, effort].compactMap { $0 }.joined(separator: " · ")
    }

    /// The first turn that names a model wins, and it is the only one that ever
    /// needs to: across a sample of a hundred-odd subagent transcripts no file
    /// named two models, and the three that appeared to were `<synthetic>` —
    /// the CLI's placeholder on a turn it wrote itself, which stands for no
    /// model and carries no effort. Skipped here for the same reason
    /// `TranscriptDocument.model` skips it.
    public static func read(lines: [Data]) -> SubagentIdentity? {
        for line in lines {
            guard let record = try? JSONDecoder().decode(TranscriptRecord.self, from: line),
                  record.type == "assistant",
                  let id = record.message?.model,
                  id != TranscriptText.syntheticModel
            else { continue }
            return SubagentIdentity(model: ModelName.display(for: id), effort: record.effort)
        }
        return nil
    }
}
