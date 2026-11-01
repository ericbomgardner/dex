import DexCore
import Foundation

extension SessionStore {
    // The composer

    /// The sessions an `@` offers: every one, whatever project the list is
    /// filtered to, since the one being continued is as likely as not in
    /// another, with the resolved ones last. Not the one being typed at.
    func mentionable(excluding rowID: String? = nil, searched: MentionSearch = MentionSearch()) -> MentionCandidates {
        let split = resolutions.split(orderedRows)
        let sessions = SessionMentions.candidates(in: split.active, excluding: rowID).map(Mention.session)
        let resolved = SessionMentions.candidates(in: split.settled, excluding: rowID, resolved: true)
            .map(Mention.session)
        return MentionCandidates(lanes: [sessions], searched: searched.lanes, searchedFor: searched.query,
                                 resolved: resolved)
    }

    /// What a draft names: its chips, then every row the list holds, so a title
    /// typed out by hand or left in a draft older than chips still reaches the
    /// session as an id.
    func mentions(in draft: String) -> [Mention] {
        guard draft.contains("@") || ComposerChips.hasChips(draft) else { return [] }
        let sessions = SessionMentions.candidates(in: snapshot.rows).map(Mention.session)
        return ComposerChips.named(in: draft, known: sessions)
    }

    var composerTarget: String {
        return ComposerTarget.resolve(
            selectedProject: selectedProject,
            lastUsed: composer.directory,
            rows: snapshot.rows
        )
    }

    var composerTargetName: String {
        return ComposerTarget.name(for: composerTarget, in: composerFolders)
    }

    /// The target when something named it, as against the home directory it
    /// falls back to. Only a named folder counts as one that was picked.
    private var composerPick: String? {
        ComposerTarget.picked(
            selectedProject: selectedProject,
            lastUsed: composer.directory,
            rows: snapshot.rows
        )
    }

    /// The composer's picker: projects with sessions plus every folder picked
    /// before, newest first. The filter picker keeps `projects`, since filtering
    /// to a folder with no sessions would show an empty list.
    var composerFolders: [ProjectSummary] {
        let marks = resolutions
        return ComposerFolders.list(rows: snapshot.rows, recents: composer.recentFolders, resolutions: marks) {
            SessionSections.counts($0, resolutions: marks)
        }
    }

    /// What the composer's Default rows resolve to, for the folder the next
    /// session starts in. Nil until the host has answered, and the pickers say
    /// the bare word until then.
    ///
    /// Per folder rather than per app, because a project can carry settings of
    /// its own: the same picker means two different things pointed at two
    /// projects, and naming one of them everywhere would be worse than naming
    /// none.
    var composerDefaults: HostDefaults? {
        host
            .defaults(for: composerTarget)
    }

    /// Asked when the composer is drawn and whenever it changes folder. Cheap
    /// enough to ask that often — the host answers in-process from the same
    /// merge engine the CLI uses, with no session and no subprocess — and the
    /// host holds the answer, so asking twice for one folder costs one request.
    func readComposerDefaults() {
        guard !composerTarget.isEmpty else { return }
        host
            .resolveDefaults(cwd: composerTarget)
    }

    var composerFollowsFilter: Bool {
        ComposerTarget.pinned(to: selectedProject) != nil
    }

    /// Asked of a draft rather than of the stored one, since the overlay holds its
    /// own until it closes.
    func canDispatch(draft: String) -> Bool {
        guard ComposerAttachments.prompt(draft: draft, attachments: composer.attachments,
                                         mentions: mentions(in: draft)) != nil
        else { return false }
        return FileManager.default.fileExists(atPath: composerTarget)
    }

    /// What a drop on the list lands in — the composer, where there is room to
    /// read back what you just attached and say what to do with it.
    func attachAndCompose(_ dropped: [ComposerAttachment]) {
        guard !dropped.isEmpty else { return }
        composer.attach(dropped)
        openComposer()
    }

    /// The overlay closes at once.
    func dispatchQuick() {
        let draft = composer.draft
        let attachments = composer.attachments
        let mentions = mentions(in: draft)
        let directory = composerTarget
        guard ComposerAttachments.prompt(draft: draft, attachments: attachments, mentions: mentions) != nil
        else { return }
        if let picked = composerPick {
            composer.noteRecent(picked)
        }
        composer.draft = ""
        composer.attachments = []
        closeOverlay()

        guard let prompt = ComposerAttachments.outgoing(
            draft: draft, attachments: attachments, mentions: mentions
        ) else { return }
        dispatchHosted(
            prompt: prompt, name: nil, directory: directory
        )
    }

    // The model and effort pickers

    func readModelNames() {
        modelNames.read(keeping: composer.model) { [claude] in await claude.executable() }
    }

    var namedModels: [SessionModel: String] {
        modelNames.named(keeping: composer.model)
    }

    /// What the CLI would run for a row, in its words. Missing until asked, and
    /// for every row until all of them have one.
    func modelName(for model: SessionModel) -> String? { namedModels[model] }

    /// The alias the settings files behind `defaults` pin, or nil where none
    /// does. The cascade's own word, so unlike the CLI's display name it still says
    /// which context width was asked for — `opus` and `opus[1m]` are two
    /// answers here and one string there.
    static func pinnedModel(in defaults: HostDefaults?) -> String? {
        guard case .named(let alias) = defaults?.model else { return nil }
        return alias
    }

    /// The rows Default lands on, which is what a pick of nothing now sends.
    var composerDefaultModel: SessionModel? {
        SessionModel.matchingDefault(
            in: SessionModel.picking(keeping: composer.model), names: namedModels
        )
    }

    var composerDefaultEffort: EffortLevel? { defaultEffort(in: composerDefaults) }

    func defaultEffort(in defaults: HostDefaults?) -> EffortLevel? {
        EffortLevel.matchingDefault(
            in: EffortLevel.shown(keeping: composer.effort, accepting: acceptedEfforts),
            resolved: defaults?.effort(forModel: modelName(for: composer.model))
        )
    }

    /// What the host will take on an `effort` request. The pickers offer no
    /// more than this: the host outlives the app, so one started before a
    /// level existed has never heard of it, and a row that cannot be sent is a
    /// dead end you find only by picking it.
    var acceptedEfforts: [String] {
        host
            .acceptedEfforts
    }

    /// What the style picker offers. The host's list where it has one, and the
    /// one kept from last time where it does not — a fresh host has run no
    /// session and so knows nothing yet, and a picker that empties itself for
    /// that stretch is one that forgets the style you chose.
    var offeredOutputStyles: [String] {
        host.outputStyles.isEmpty ? preferences.knownOutputStyles : host.outputStyles
    }
}
