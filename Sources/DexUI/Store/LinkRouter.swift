import DexCore
import Foundation
import Observation

/// What asks for the window and a row in it: a notification, a link, a fresh
/// dispatch. The store decides which row; this holds the asks the window
/// answers, and a link still waiting for its row to turn up.
@MainActor
@Observable
final class LinkRouter {
    struct FocusRequest: Equatable {
        let sessionID: String?
        let token: Int
    }

    private(set) var focusRequest: FocusRequest?
    private(set) var scrollTargetID: String?

    private var focusToken = 0
    private var scrollTargetClearTask: Task<Void, Never>?

    private static let scrollTargetLifetime = Duration.seconds(6)

    private var pendingLink: SessionLink?
    private var pendingLinkDeadline = Date.distantPast

    static let linkPatience: TimeInterval = 15

    func requestFocus(sessionID: String) {
        focusToken += 1
        focusRequest = FocusRequest(sessionID: sessionID, token: focusToken)
    }

    /// Asks for the window and nothing in it, which is all reopening wants:
    /// there is no session behind a Dock click, or behind `open` on an app
    /// already running.
    func showWindow() {
        focusToken += 1
        focusRequest = FocusRequest(sessionID: nil, token: focusToken)
    }

    func clearFocusRequest() {
        focusRequest = nil
    }

    // Cleared on a timer so focusing the same row again re-triggers the scroll.
    func scroll(to row: SessionRowModel) {
        scrollTargetID = row.rowID
        scrollTargetClearTask?.cancel()
        scrollTargetClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scrollTargetLifetime)
            guard !Task.isCancelled else { return }
            self?.scrollTargetID = nil
        }
    }

    func stop() {
        scrollTargetClearTask?.cancel()
        scrollTargetClearTask = nil
    }

    /// Held for `linkPatience` rather than failed on the first snapshot.
    func wait(for link: SessionLink) {
        pendingLink = link
        pendingLinkDeadline = Date().addingTimeInterval(Self.linkPatience)
    }

    enum Waiting {
        case nothing
        case stillWaiting
        case found(SessionRowModel)
        case gaveUp(SessionLink)
    }

    /// Whether the link being waited on has its row yet. Found or given up
    /// on, it is no longer waited on.
    func pendingLink(in rows: [SessionRowModel]) -> Waiting {
        guard let link = pendingLink else { return .nothing }
        guard let row = rows.first(where: { $0.session.sessionId == link.sessionID }) else {
            guard Date() >= pendingLinkDeadline else { return .stillWaiting }
            pendingLink = nil
            return .gaveUp(link)
        }
        pendingLink = nil
        return .found(row)
    }
}
