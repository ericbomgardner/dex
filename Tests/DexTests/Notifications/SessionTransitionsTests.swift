import Foundation
import Testing
@testable import DexCore

@Suite("Session transitions")
struct SessionTransitionsTests {

    private func row(
        _ state: HostSessionState,
        id: String = "abc123",
        name: String? = "fix-the-parser",
        needs: String? = nil,
        detail: String? = "doing the thing"
    ) -> SessionRowModel {
        SessionRowModel(
            session: AgentSession(
                cwd: "/Users/me/Projects/orchard",
                    startedAt: 1_753_000_000_000,
                hostKey: id,
                state: state,
                sessionId: "sess-\(id)",
                name: name
            ),
            hostedSummary: needs ?? detail
        )
    }

    @Test("The first read notifies nothing")
    func firstReadIsSilent() {
        let current = [row(.asking), row(.done), row(.running)]

        #expect(SessionTransitions.notifications(from: [], to: current).isEmpty)
    }

    @Test("An unchanged list notifies nothing")
    func unchangedListIsSilent() {
        let rows = [row(.asking), row(.running, id: "def456")]

        #expect(SessionTransitions.notifications(from: rows, to: rows).isEmpty)
    }

    @Test("A session that stays blocked notifies once, not on every tick")
    func stayingBlockedDoesNotRepeat() {
        let blocked = [row(.asking)]
        let first = SessionTransitions.notifications(from: [row(.running)], to: blocked)
        #expect(first.count == 1)

        #expect(SessionTransitions.notifications(from: blocked, to: blocked).isEmpty)
        #expect(SessionTransitions.notifications(from: blocked, to: blocked).isEmpty)
    }

    @Test("Stopping a session does not notify")
    func stoppedIsNotAnnounced() {
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [row(.idle)])

        #expect(drafts.isEmpty)
    }

    @Test("Working to working does not notify")
    func stillWorkingIsNotAnnounced() {
        let drafts = SessionTransitions.notifications(
            from: [row(.running, detail: "step one")],
            to: [row(.running, detail: "step two")]
        )

        #expect(drafts.isEmpty)
    }

    @Test("Working to blocked notifies with the reason")
    func blockingAnnouncesWithTheAsk() {
        let waiting = row(.asking, needs: "answer: Tabs or spaces? (Spaces · Tabs)")
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [waiting])

        #expect(drafts.count == 1)
        #expect(drafts.first?.needsInput == true)
        #expect(drafts.first?.title == "Input needed: fix-the-parser")

        #expect(drafts.first?.body == "answer: Tabs or spaces? (Spaces · Tabs)")
        #expect(drafts.first?.sessionID == "sess-abc123")
    }

    @Test("Working to done notifies a finish")
    func finishingAnnounces() {
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [row(.done)])

        #expect(drafts.count == 1)
        #expect(drafts.first?.needsInput == false)
        #expect(drafts.first?.title == "Finished: fix-the-parser")
    }

    @Test("Failing notifies as a failure, not a finish")
    func failingAnnounces() {
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [row(.failed)])

        #expect(drafts.first?.title == "Failed: fix-the-parser")
    }

    /// The list can call a session the CLI hasn't named yet New session, since
    /// it draws the folder on the next line. A banner has no next line, and a
    /// first turn that fails outright is a session that never gets named at
    /// all — so every one of those would arrive saying the same thing.
    @Test("A session the CLI hasn't named is announced by its folder")
    func anUnnamedSessionIsAnnouncedByWhereItIsRunning() {
        let drafts = SessionTransitions.notifications(
            from: [row(.running, name: nil)],
            to: [row(.failed, name: nil)]
        )

        #expect(drafts.first?.title == "Failed: orchard")
    }

    @Test("Blocked to done notifies the finish")
    func answeringThenFinishingAnnounces() {
        let drafts = SessionTransitions.notifications(from: [row(.asking)], to: [row(.done)])

        #expect(drafts.count == 1)
        #expect(drafts.first?.needsInput == false)
    }

    @Test("Each session is diffed against its own previous state")
    func rowsAreMatchedIndividually() {
        let before = [row(.running, id: "aaa", name: "one"), row(.running, id: "bbb", name: "two")]
        let after = [row(.running, id: "aaa", name: "one"), row(.asking, id: "bbb", name: "two")]

        let drafts = SessionTransitions.notifications(from: before, to: after)

        #expect(drafts.count == 1)
        #expect(drafts.first?.title == "Input needed: two")
    }

    @Test("A session that appears already blocked notifies")
    func newBlockedRowAnnounces() {
        let drafts = SessionTransitions.notifications(
            from: [row(.running, id: "existing")],
            to: [row(.running, id: "existing"), row(.asking, id: "brandnew", name: "new-one")]
        )

        #expect(drafts.count == 1)
        #expect(drafts.first?.title == "Input needed: new-one")
    }

    @Test("A session that appears already done does not notify")
    func newFinishedRowIsSilent() {
        let drafts = SessionTransitions.notifications(
            from: [row(.running, id: "existing")],
            to: [row(.running, id: "existing"), row(.done, id: "brandnew")]
        )

        #expect(drafts.isEmpty)
    }

    @Test("An unrecognised state is not treated as a finish")
    func unknownStateIsNotAFinish() {
        let drafts = SessionTransitions.notifications(
            from: [row(.running)],
            to: [row(.unknown("retiring"))]
        )

        #expect(drafts.isEmpty)
    }

    @Test("Moving out of an unrecognised state into done notifies")
    func unknownToDoneAnnounces() {
        let drafts = SessionTransitions.notifications(
            from: [row(.unknown("retiring"))],
            to: [row(.done)]
        )

        #expect(drafts.count == 1)
    }

    @Test("A finish in the foreground is not notified")
    func finishOnScreenIsQuiet() {
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [row(.done)])

        #expect(drafts.first?.shouldBeShown(alreadyOnScreen: true) == false)
        #expect(drafts.first?.shouldBeShown(alreadyOnScreen: false) == true)
    }

    @Test("A blocked row notifies in foreground and background")
    func blockedIgnoresTheForeground() {
        let waiting = row(.asking, needs: "answer: Tabs or spaces? (Spaces · Tabs)")
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [waiting])

        #expect(drafts.first?.shouldBeShown(alreadyOnScreen: true) == true)
        #expect(drafts.first?.shouldBeShown(alreadyOnScreen: false) == true)
    }

    @Test("A failure in the foreground is quietened like any finish")
    func failureOnScreenIsQuiet() {
        let drafts = SessionTransitions.notifications(from: [row(.running)], to: [row(.failed)])

        #expect(drafts.first?.needsInput == false)
        #expect(drafts.first?.shouldBeShown(alreadyOnScreen: true) == false)
    }

    private func standing(
        _ rows: [SessionRowModel],
        resolutions: SessionResolutions = SessionResolutions(),
        onScreen: Set<String> = []
    ) -> Set<String> {
        SessionTransitions.standing(in: rows, resolutions: resolutions, onScreen: onScreen)
    }

    @Test("A session still wanting input keeps its notification")
    func blockedNotificationStands() {
        #expect(standing([row(.asking)]) == ["abc123"])
    }

    @Test("A notification stands whether or not the session is on screen")
    func blockedNotificationIgnoresTheForeground() {
        #expect(standing([row(.asking)], onScreen: ["abc123"]) == ["abc123"])
    }

    @Test("Answering the session takes its notification back")
    func answeringWithdraws() {
        #expect(standing([row(.running)]).isEmpty)
    }

    @Test("Resolving a session still wanting input takes its notification back")
    func resolvingWhileBlockedWithdraws() {
        let waiting = row(.asking)
        var resolutions = SessionResolutions()
        resolutions.resolve(waiting)

        #expect(standing([waiting], resolutions: resolutions).isEmpty)
    }

    @Test("A finish stands until it has been on screen")
    func finishStandsUntilSeen() {
        #expect(standing([row(.done)]) == ["abc123"])
        #expect(standing([row(.done)], onScreen: ["abc123"]).isEmpty)
        #expect(standing([row(.failed)]) == ["abc123"])
    }

    @Test("Stopping a session takes back whatever it was saying")
    func stoppingWithdraws() {
        #expect(standing([row(.idle)]).isEmpty)
    }

    @Test("A session that has left the list keeps nothing standing")
    func departedSessionWithdraws() {
        #expect(standing([]).isEmpty)
        #expect(!standing([row(.asking, id: "still-here")]).contains("gone"))
    }

    @Test("Sessions are judged one at a time")
    func rowsStandSeparately() {
        let rows = [row(.asking, id: "aaa"), row(.done, id: "bbb"), row(.running, id: "ccc")]

        #expect(standing(rows, onScreen: ["bbb"]) == ["aaa"])
        #expect(standing(rows) == ["aaa", "bbb"])
    }

    @Test("A session with no transcript yet is still filed under its row")
    func sessionlessRowIsStillWithdrawable() {
        let blocked = SessionRowModel(session: AgentSession(
            cwd: "/Users/me/Projects/orchard",
            startedAt: 1_753_000_000_000,
            hostKey: "abc123",
            state: .asking,
            name: "fix-the-parser"
        ))

        #expect(blocked.session.sessionId == nil)
        #expect(standing([blocked]) == ["abc123"])

        let drafts = SessionTransitions.notifications(
            from: [row(.running, id: "abc123")], to: [blocked]
        )
        #expect(drafts.first?.key == "abc123")
        #expect(drafts.first?.sessionID == nil)
    }

    @Test("A settled row is not announced, since it would be withdrawn at once")
    func settledRowIsNotAnnounced() {
        let waiting = row(.asking)
        var resolutions = SessionResolutions()
        resolutions.resolve(waiting)

        let drafts = SessionTransitions.notifications(
            from: [row(.running)], to: [waiting], resolutions: resolutions
        )

        #expect(drafts.isEmpty)
        #expect(SessionTransitions.notifications(from: [row(.running)], to: [waiting]).count == 1)
    }
}
