import Foundation

/// A file dropped on the composer. The CLI takes one string, so an
/// attachment travels into the session as a path inside the opening message.
public struct ComposerAttachment: Identifiable, Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var id: String { path }

    public var name: String {
        (path as NSString).lastPathComponent
    }
}

public enum ComposerAttachments {

    /// The draft, then what rides under it: a line per file dropped on it and a
    /// line per session or task it names, so a title in the sentence reaches the
    /// model as something it can open.
    public static func prompt(
        draft: String,
        attachments: [ComposerAttachment],
        mentions: [Mention] = []
    ) -> String? {
        let sentence = ComposerChips.sentence(draft)
        let footer = attachments.map { "Attached: `\($0.path)`" } + mentions.compactMap(\.line)
        guard !footer.isEmpty else { return ComposerDraft.persistable(sentence) }

        let lines = footer.joined(separator: "\n")
        guard let text = ComposerDraft.persistable(sentence) else { return lines }

        let trimmed = text.replacingOccurrences(
            of: "\\s+$",
            with: "",
            options: .regularExpression
        )
        return trimmed + "\n\n" + lines
    }

    /// The message as the session will read it, with anything riding along named
    /// by a path that survives being typed back.
    ///
    /// Asked for at the send rather than at the drop, because the plain name is a
    /// link in the scratch space and a draft can sit unsent for days. What is kept
    /// against the session is the reader's own path, which outlives anything the
    /// app writes; the link only has to last the message out.
    public static func outgoing(
        draft: String,
        attachments: [ComposerAttachment],
        mentions: [Mention] = [],
        locating: (String) -> String?
    ) -> String? {
        prompt(draft: draft,
               attachments: attachments.map(addressable),
               mentions: mentions.map { $0.located(by: locating) })
    }

    public static func outgoing(
        draft: String,
        attachments: [ComposerAttachment],
        mentions: [Mention] = []
    ) -> String? {
        outgoing(draft: draft, attachments: attachments, mentions: mentions) {
            TranscriptLocator().locate(sessionID: $0)?.path
        }
    }

    /// A path a session can type back, or the one that was dropped. Falling back
    /// is safe in the one direction that matters: the file really is there, and a
    /// path a session may mistype beats no attachment at all.
    private static func addressable(_ attachment: ComposerAttachment) -> ComposerAttachment {
        guard !ComposerStash.typesAsWritten(attachment.path) else { return attachment }
        return (try? ComposerStash.link(attachment.path)) ?? attachment
    }

    public static func adding(
        _ dropped: [ComposerAttachment],
        to existing: [ComposerAttachment]
    ) -> [ComposerAttachment] {
        var kept = existing
        for attachment in dropped where !kept.contains(attachment) {
            kept.append(attachment)
        }
        return kept
    }

    public static func present(
        _ attachments: [ComposerAttachment],
        checking exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ComposerAttachment] {
        attachments.filter { exists($0.path) }
    }
}
