import XCTest
@testable import DexUI
@testable import DexProbes

/// Where the transcript is left when the pane changes height under it.
///
/// Driven through `ScrollProbe`, which hosts the real `TranscriptColumn` in an
/// offscreen window and reads its scroll view — the only place this is
/// measurable, since what is being pinned is what the pane does about a
/// *container* that shrank as well as content that grew. Written as its own
/// numbers rather than as the probe's verdict so a failure says how far off the
/// bottom the pane was left.
@MainActor
final class TranscriptScrollTests: XCTestCase {

    /// The defect this is all for. The strip appears between the transcript and
    /// the composer, takes its height out of the viewport, and the bottom anchor
    /// has no answer for that: the pane is left 26 points short of the newest
    /// line and stays there until the next thing is written.
    func testTheStripAppearingUsedToLeaveThePaneShortOfTheBottom() throws {
        let short = try reading(.stripAppears, .anchorAlone).shortBy
        XCTAssertGreaterThan(short, TranscriptColumn.slack)
    }

    func testTheStripAppearingLeavesThePaneAtTheBottom() throws {
        try assertFlush(.stripAppears)
    }

    /// The real submit: the strip arrives and "Thinking…" is appended in the
    /// same update. The content growing does not absorb the container shrinking.
    func testASubmitLeavesThePaneAtTheBottom() throws {
        try assertFlush(.stripAppearsWithThinking)
    }

    /// Nothing to do with a submit — the composer taking its fifth line is the
    /// same shrink, and the same 68 points off the end without this.
    func testTheComposerGrowingLeavesThePaneAtTheBottom() throws {
        try assertFlush(.composerGrows)
    }

    /// A turn landing still follows, which is what says `defaultScrollAnchor` is
    /// still doing its half: taken off, this is the case that fails, because a
    /// re-pin is offered only for a gap the *container* opened and content
    /// growing is not that.
    func testATurnLandingStillFollowsTheConversationDown() throws {
        try assertFlush(.turnLands)
    }

    /// A whole submit in the order the app performs it: the field gives its
    /// lines back, the strip and "Thinking…" land when the session picks the
    /// turn up, and the prompt itself lands last, when the transcript on disk
    /// catches up. At the bottom after every one of them, not only at the end.
    func testASubmitHoldsTheBottomThroughEveryPartOfIt() throws {
        try assertFlushThroughout(.submits)
    }

    /// The one the geometry can't answer, and the reason a send says anything
    /// at all: the pane is somewhere back up the conversation, and hitting
    /// return has to bring the end down and keep it there for the turn that
    /// follows. Nothing about the shape of that gap says it should be closed —
    /// which is why it stays open without the word from the composer.
    func testSendingFromUpTheConversationBringsTheEndDown() throws {
        let sent = try reading(.submitsFromUpTheConversation)
        XCTAssertLessThanOrEqual(
            abs(sent.shortBy), TranscriptColumn.slack,
            "left \(sent.shortBy) points short of the message that was just sent"
        )
        XCTAssertGreaterThan(
            try reading(.submitsFromUpTheConversation, .anchorAlone).shortBy,
            TranscriptColumn.slack
        )
    }

    /// And the shortfall this is really for. A window dragged shorter leaves
    /// the pane short and the shortfall is carried, unanswerable by anything
    /// that reads geometry — `testAWindowDragIsLeftNoWorseThanTheAnchorLeftIt`
    /// pins that it stays. What clears it is the reader going back to the box
    /// and typing, which is the one moment they say where they are.
    func testAShortfallCarriedFromADragIsClearedByASend() throws {
        try assertFlushThroughout(.sendsAfterAWindowDrag, from: "sent")
        XCTAssertGreaterThan(
            try reading(.sendsAfterAWindowDrag, .anchorAlone).shortBy,
            TranscriptColumn.slack
        )
    }

    /// What holding the end costs, which has to be nothing: having sent a
    /// message, the reader goes back up the conversation while the session is
    /// writing into it. Nothing written under them may take the page away
    /// again — not the turn landing as they go, and not the ones after it. The
    /// hold is released by their going, not by the turn ending, which is why it
    /// is released on the offset: a write opens the same gap without moving
    /// them, and reading the gap here would hold a reader only until the next
    /// line landed under them.
    func testAReaderWhoGoesBackAfterSendingIsLeftWhereTheyWent() throws {
        for step in try reading(.scrolledBackAfterASend).trail.drop(while: { $0.name != "readsBack" }) {
            XCTAssertLessThanOrEqual(
                abs(step.drift), TranscriptColumn.slack,
                "\(step.name) moved the pane \(step.drift) points under a reader who had gone back"
            )
        }
    }

    /// The strip arriving is not the last time it changes height: a session
    /// that delegates takes another row for every agent it sends, mid-turn,
    /// out of the same viewport. Each one is the strip's own doing and is
    /// answered as such.
    func testARowJoiningTheStripKeepsThePaneAtTheBottom() throws {
        try assertFlushThroughout(.anotherAgentJoinsUnasked)
    }

    /// And the same with the end being held for a reader who has just sent
    /// something, which is when a session is most likely to be sending agents
    /// out. The hold only answers the gaps the shrink rule refuses — measured,
    /// standing in for it here left the pane seventeen points short of the
    /// third agent's row.
    func testARowJoiningTheStripIsAnsweredWhileHoldingTheEnd() throws {
        try assertFlushThroughout(.anotherAgentJoins)
    }

    /// The half a re-pin could take away. Scrolled back through the
    /// conversation, neither the strip arriving nor a turn landing under it may
    /// move the place being read.
    func testAReaderScrolledBackIsLeftWhereTheyWere() throws {
        let reading = try reading(.scrolledBack)
        XCTAssertLessThanOrEqual(
            abs(reading.drift), TranscriptColumn.slack,
            "the pane moved \(reading.drift) points under a reader who was not at the bottom"
        )
    }

    /// And left there for a whole turn of the session, which is four container
    /// changes rather than one. The reading that rules out a mechanism which
    /// holds for the first and gives way on the second — every version of this
    /// that kept a flag between readings had somewhere it could be talked into
    /// re-arming, and this is where that would show.
    func testAReaderScrolledBackStaysPutForAWholeTurn() throws {
        for step in try reading(.scrolledBackThroughATurn).trail {
            XCTAssertLessThanOrEqual(
                abs(step.drift), TranscriptColumn.slack,
                "\(step.name) moved the pane \(step.drift) points under a reader who had scrolled back"
            )
        }
    }

    /// And the pane answers again after a reader comes back to the end by hand.
    func testComingBackToTheBottomIsAnsweredAgain() throws {
        try assertFlush(.returnsToBottom)
    }

    /// A window dragged shorter keeps a reader at the end at the end, and
    /// through the whole turn after it. The SwiftUI pane carried the drag's
    /// shortfall into every change after it; the bottom anchor alone still
    /// does, which is what says the column is doing this rather than the
    /// staging making it easy.
    func testAWindowDragKeepsTheEnd() throws {
        try assertFlush(.windowShrinks)
        try assertFlushThroughout(.aTurnAfterAWindowDrag)
        XCTAssertGreaterThan(
            try reading(.aTurnAfterAWindowDrag, .anchorAlone).shortBy,
            TranscriptColumn.slack
        )
    }

    func testComingBackToASessionLandsWhereItWasLeft() throws {
        try assertStayedPut(.returnsToItsPlace)
    }

    func testComingBackToASessionTheFeedReadAgainLandsWhereItWasLeft() throws {
        try assertStayedPut(.returnsToItsPlaceAfterARead)
    }

    /// The defect that asked for this: a switch swapped the new transcript in
    /// under the old one's offset, and opened it thousands of points up.
    func testAnotherSessionOpensAtItsEndWhereverTheLastWasLeft() throws {
        try assertFlush(.opensAnotherAtItsEnd)
    }

    func testASessionLeftAtTheEndComesBackToItsNewEnd() throws {
        try assertFlush(.returnsToTheEndItGrew)
    }

    /// Rows come back at their default height, so an offset alone would land
    /// a row shut above the place that many points further on.
    func testComingBackKeepsTheLineWhenARowAboveItComesBackShorter() throws {
        let drift = try reading(.returnsToItsPlaceAfterARowAboveShrank).drift
        XCTAssertEqual(drift, -400, accuracy: TranscriptColumn.slack)
    }

    func testComingBackWaitsForATranscriptReadInPasses() throws {
        try assertStayedPut(.returnsToItsPlaceReadInPasses)
    }

    func testComingBackToTheTopLandsAtTheTop() throws {
        try assertStayedPut(.returnsToTheTop)
    }

    /// A row that has gone can't hold the return open: the send after it
    /// still has to bring the end down and keep it.
    func testComingBackWhenItsRowIsGoneStillFollowsASend() throws {
        let reading = try reading(.returnsWhenItsRowIsGone)
        XCTAssertEqual(reading.shortBy(after: "stripAndThinking") ?? .infinity, 0, accuracy: TranscriptColumn.slack)
    }

    /// Not offered a line from the end; from the top it brings the end down
    /// and holds it through the turn after, as a send does.
    func testJumpingToTheEndHoldsIt() throws {
        let reading = try reading(.jumpsToTheEnd)
        XCTAssertEqual(reading.shortBy(after: "aLineUp") ?? 0, 40, accuracy: TranscriptColumn.slack)
        for step in reading.trail.dropFirst(2) {
            XCTAssertLessThanOrEqual(abs(step.shortBy), TranscriptColumn.slack, "after \(step.name)")
        }
    }

    /// The window's pane runs up under the titlebar, and AppKit insets a new
    /// scroll view for it only after the column has put the reader at the end.
    /// Taken as the reader scrolling, it left every first open of a session
    /// the titlebar's height short.
    func testOpeningUnderTheTitlebarLandsAtTheEnd() throws {
        try assertFlush(.opensUnderTheTitlebar)
    }

    // MARK: - Driving

    /// Unwrapped here rather than in the probe, which answers nil where nothing
    /// hosted a scroll view: it is called from this bundle as well as from the
    /// command line, and a probe that exited on it would take the other thousand
    /// tests down with it.
    private func reading(
        _ kase: ScrollProbe.Case,
        _ arrangement: ScrollProbe.Arrangement = .scroller,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ScrollProbe.Reading {
        try XCTUnwrap(
            ScrollProbe.reading(kase, arrangement),
            "nothing hosted a scroll view — either this machine has no window server to lend, "
                + "or the transcript's column has stopped being a scroll view",
            file: file,
            line: line
        )
    }

    private func assertFlushThroughout(
        _ kase: ScrollProbe.Case,
        from step: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let trail = try reading(kase, file: file, line: line).trail
        for at in trail.drop(while: { at in step.map { at.name != $0 } ?? false }) {
            XCTAssertLessThanOrEqual(
                abs(at.shortBy), TranscriptColumn.slack,
                "\(at.name) left the pane \(at.shortBy) points short of the bottom",
                file: file,
                line: line
            )
        }
    }

    private func assertFlush(
        _ kase: ScrollProbe.Case,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reading = try reading(kase, file: file, line: line)
        XCTAssertLessThanOrEqual(
            abs(reading.shortBy), TranscriptColumn.slack,
            "left \(reading.shortBy) points short of the bottom, viewport "
                + "\(reading.viewportBefore) → \(reading.viewportAfter)",
            file: file,
            line: line
        )
    }

    private func assertStayedPut(
        _ kase: ScrollProbe.Case,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let drift = try reading(kase, file: file, line: line).drift
        XCTAssertLessThanOrEqual(
            abs(drift), TranscriptColumn.slack,
            "came back \(drift) points from where it was left",
            file: file,
            line: line
        )
    }
}
