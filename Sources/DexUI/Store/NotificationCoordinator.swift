import DexCore
import Foundation

/// What gets posted as the list moves, what gets taken back once it is no
/// longer news, and the background watchers' alerts.
@MainActor
final class NotificationCoordinator {
    /// The list as the store has it, asked as each decision is made.
    struct Reading {
        let rows: [SessionRowModel]
        let resolutions: SessionResolutions
        let hasNeverLoaded: Bool
    }

    private let presenter: NotificationPresenter
    private let preferences: Preferences
    private let watchers: BackgroundWatchers

    var reading: () -> Reading = { Reading(rows: [], resolutions: SessionResolutions(), hasNeverLoaded: true) }
    /// The rows the window is showing, which a notice for is not news.
    var onScreen: () -> Set<String> = { [] }
    /// Keys whose notice stands whatever their row says: a takeover's stands
    /// for as long as the session has the screen.
    var standing: () -> Set<String> = { [] }

    init(presenter: NotificationPresenter, preferences: Preferences, watchers: BackgroundWatchers) {
        self.presenter = presenter
        self.preferences = preferences
        self.watchers = watchers
    }

    func announce(from previous: [SessionRowModel], to current: [SessionRowModel]) {

        guard preferences.postsNotifications else { return }
        let drafts = SessionTransitions.notifications(
            from: previous, to: current, resolutions: reading().resolutions
        )
        guard !drafts.isEmpty else { return }

        let onScreen = onScreen()
        for draft in drafts {
            guard draft.shouldBeShown(alreadyOnScreen: onScreen.contains(draft.key)) else { continue }
            presenter.post(draft)
        }
    }

    /// Runs posting or not: switching notifications off shouldn't leave stale ones up.
    func withdrawOvertaken() {
        let list = reading()
        // An empty list takes back everything, and launching comes forward first.
        guard !list.hasNeverLoaded else { return }

        // A takeover's notice stands for as long as the session has the
        // screen, which is not a state the rows carry.
        presenter.keepOnly(SessionTransitions.standing(
            in: list.rows,
            resolutions: list.resolutions,
            onScreen: onScreen()
        ).union(standing()).union(watcherAlertKeys))
    }

    // Background watchers

    private var watcherAlertKeys: Set<String> {
        let announced = Defaults.watcherAlerts
        return Set(
            watchers.watchers
                .filter { watcher in
                    let health = watchers.health(of: watcher)
                    return health.needsAttention || (health.isHeldByWake && announced[watcher.id] != nil)
                }
                .map(BackgroundWatcherAlert.key(for:))
        )
    }

    /// Once per problem, across launches too: what each watcher was last
    /// announced for is kept, and a watcher that has recovered is forgotten so
    /// its next failure is news.
    func announceWatchers() {
        var announced = Defaults.watcherAlerts
        let present = Set(watchers.watchers.map(\.id))
        announced = announced.filter { present.contains($0.key) }
        for watcher in watchers.watchers {
            let health = watchers.health(of: watcher)
            if health.isHeldByWake { continue }
            guard let token = health.alertToken(for: watcher) else {
                announced[watcher.id] = nil
                continue
            }
            guard announced[watcher.id] != token else { continue }
            announced[watcher.id] = token
            if preferences.postsNotifications,
                let draft = BackgroundWatcherAlert.draft(watcher, health, now: watchers.now) {
                presenter.post(draft)
            }
        }
        Defaults.watcherAlerts = announced
        withdrawOvertaken()
    }
}
