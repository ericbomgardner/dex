import DexCore
import Foundation
import Observation

/// What the new-session composer holds between openings: its picks, its draft
/// and the folders it has been pointed at, each written to `Defaults` as it
/// changes. Where the next session goes is the store's to say, since it reads
/// the list and the host as well as these.
@MainActor
@Observable
final class ComposerModel {
    private(set) var model: SessionModel {
        didSet { Defaults.composerModel = model }
    }

    /// Where an app's running sessions write their dial back, the next one
    /// starts where the last one was left.
    var effort: EffortLevel {
        didSet { Defaults.composerEffort = effort }
    }

    var draft: String {
        didSet {
            Defaults.composerDraft = draft
        }
    }

    var attachments: [ComposerAttachment] {
        didSet {
            Defaults.composerAttachments = attachments
        }
    }

    private(set) var directory: String? {
        didSet { Defaults.composerDirectory = directory }
    }

    private(set) var recentFolders: RecentFolders {
        didSet { Defaults.recentFolders = recentFolders }
    }

    init() {
        self.directory = Defaults.composerDirectory
        self.recentFolders = Defaults.recentFolders
        self.draft = Defaults.composerDraft
        self.attachments = Defaults.composerAttachments
        self.model = Defaults.composerModel.settled
        self.effort = Defaults.composerEffort

        if let directory, !recentFolders.contains(directory) {
            recentFolders.note(directory)
        }
    }

    func chooseProject(_ path: String) {
        directory = path
        recentFolders.note(path)
    }

    func chooseModel(_ model: SessionModel) {
        self.model = model
    }

    func chooseEffort(_ effort: EffortLevel) {
        self.effort = effort
    }

    /// A folder picked by name as a session starts, which goes to the top of
    /// the recents without becoming the one the composer is pointed at.
    func noteRecent(_ path: String) {
        recentFolders.note(path)
    }

    /// Asked on every rebuild and again as the composer opens, since the menu
    /// draws from this and a folder deleted between two rebuilds must not.
    func pruneRecentFolders(keeping stillThere: (String) -> Bool) {
        var recents = recentFolders
        recents.prune(keeping: stillThere)
        guard recents != recentFolders else { return }
        recentFolders = recents
    }

    func attach(_ dropped: [ComposerAttachment]) {
        attachments = ComposerAttachments.adding(dropped, to: attachments)
    }

    func detach(_ attachment: ComposerAttachment) {
        attachments.removeAll { $0 == attachment }
    }
}
