import Foundation

/// Half-written replies and what was dropped on them, each held against the
/// session it was meant for.
public struct ComposerDrafts: Codable, Hashable, Sendable {
    private var texts: [String: String]
    private var files: [String: [String]]

    public init(texts: [String: String] = [:], files: [String: [String]] = [:]) {
        self.texts = texts
        self.files = files
    }

    /// Written by hand so drafts stored before there were attachments still read
    /// back — synthesised decoding would throw on the missing key and lose them all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        texts = try container.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
        files = try container.decodeIfPresent([String: [String]].self, forKey: .files) ?? [:]
    }

    public var stored: [String: String] { texts }

    public var isEmpty: Bool { texts.isEmpty && files.isEmpty }

    /// A draft that has been emptied leaves nothing behind, so the store holds
    /// only sessions with something still to say.
    public subscript(sessionID: String) -> String {
        get { ComposerDraft.restored(texts[sessionID]) }
        set { texts[sessionID] = ComposerDraft.persistable(newValue) }
    }

    public func attachments(for sessionID: String) -> [ComposerAttachment] {
        (files[sessionID] ?? []).map(ComposerAttachment.init)
    }

    public mutating func setAttachments(_ attachments: [ComposerAttachment], for sessionID: String) {
        files[sessionID] = attachments.isEmpty ? nil : attachments.map(\.path)
    }

    /// Files that went away while the app was closed are dropped rather than
    /// offered back as chips pointing at nothing.
    public func present(
        checking exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ComposerDrafts {
        var kept = self
        for (sessionID, paths) in files {
            kept.setAttachments(
                ComposerAttachments.present(paths.map(ComposerAttachment.init), checking: exists),
                for: sessionID
            )
        }
        return kept
    }
}
