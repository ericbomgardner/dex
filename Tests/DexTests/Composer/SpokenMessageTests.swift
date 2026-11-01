import DexCore
import XCTest
@testable import DexUI

/// What the pane stands in for between a message being sent and the transcript
/// having it. The file is the only word for what a session has been told and it
/// is a second or two behind — longer when the message is what resumes the
/// session — so for that stretch the message is on screen because the pane is
/// holding it, and nothing else.
///
/// The arithmetic is the whole of the risk: settle a message early and it
/// blinks out before the file has it, settle it late and it is on screen twice.
@MainActor
final class SpokenMessageTests: XCTestCase {

    func testAMessageIsHeldFromTheMomentItIsSent() {
        let pane = pane()
        pane.send("what's left to do?")

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["what's left to do?"])
    }

    /// The prompt lands in the file and the pane stops standing in for it.
    func testItIsLetGoWhenTheTranscriptHasIt() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("what's left to do?")
        pane.heard(5, of: transcript, for: key)

        XCTAssertEqual(pane.saying(for: key).count, 0)
    }

    /// Two sent before either is written, let go in the order they were sent.
    func testTheyAreLetGoOldestFirst() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("first")
        pane.send("second")
        pane.heard(5, of: transcript, for: key)

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["second"])
    }

    /// The reading that would drop a message with nothing on screen to replace
    /// it. The feed starts every transcript from nothing and climbs back — that
    /// is a session adopting its transcript id, or one that changed directory —
    /// and the climb is not the message arriving.
    func testAFileBeingReadAgainDoesNotCountAsArrival() {
        let pane = pane()
        pane.heard(9, of: transcript, for: key)
        pane.send("what's left to do?")

        pane.heard(0, of: transcript, for: key)
        pane.heard(6, of: transcript, for: key)
        pane.heard(9, of: transcript, for: key)

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["what's left to do?"])

        pane.heard(10, of: transcript, for: key)
        XCTAssertEqual(pane.saying(for: key).count, 0)
    }

    /// The first reading is a mark to measure later ones against, not an
    /// arrival: read as one, a message sent to a pane that had never seen a
    /// count would be dropped by the very first pass.
    func testTheFirstReadingLetsNothingGo() {
        let pane = pane()
        pane.send("what's left to do?")
        pane.heard(12, of: transcript, for: key)

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["what's left to do?"])
    }

    /// Each session is measured against its own file.
    func testOneSessionsTranscriptDoesNotSettleAnothers() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("what's left to do?")
        pane.heard(40, of: "another", for: "other")

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["what's left to do?"])
    }

    /// A message handed back because it never got out is a message in the box
    /// again, and nothing is standing in for it.
    func testAMessageGivenBackIsNoLongerHeld() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("what's left to do?")
        pane.restore(draft: "what's left to do?", for: key, unsaying: ["what's left to do?"])

        XCTAssertEqual(pane.saying(for: key).count, 0)
    }

    /// The frame the prompt lands in. What the file has caught up on and the
    /// pane's stand-in for it come off the same reading, and the bookkeeping
    /// runs after the frame is drawn — so the drawing asks the same question
    /// rather than waiting to be told.
    func testTheStandInIsGoneInTheFrameThePromptLandsIn() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("what's left to do?")

        XCTAssertEqual(pane.saying(for: key, heard: 5, of: transcript).count, 0)
        XCTAssertEqual(pane.saying(for: key, heard: 4, of: transcript).count, 1)
    }

    /// A key outlives the session that used it: one that ends frees it, and a
    /// new session can start under it. A mark left over from a long
    /// conversation sits above anything a new file could reach, so a message
    /// sent to the new session would be stood in for by a pane that could never
    /// let go of it — on screen for good, and twice over once the file caught
    /// up.
    func testAMarkFromAnotherTranscriptLetsNothingGo() {
        let pane = pane()
        pane.heard(50, of: "the long one", for: key)

        pane.send("hello again")
        pane.heard(0, of: "a new one", for: key)
        XCTAssertEqual(pane.saying(for: key, heard: 0, of: "a new one").count, 1)

        pane.heard(1, of: "a new one", for: key)
        XCTAssertEqual(pane.saying(for: key).count, 0)
    }

    /// Handing a failed message back doesn't take an unrelated one with it: a
    /// message sent while the host still held the session went out by a route
    /// a later resume failing says nothing about.
    func testOnlyTheMessagesHandedBackStopBeingHeld() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("already gone")
        pane.send("never left")
        pane.restore(draft: "never left", for: key, unsaying: ["never left"])

        XCTAssertEqual(pane.saying(for: key).map(\.text), ["already gone"])
    }

    /// The frame after a switch between panes pairs the previous session's
    /// count with the new session's id — the feed is one object across the
    /// switch — and read as a mark it sat above anything the new file could
    /// reach: every message sent to it climbed toward that mark and stayed on
    /// screen twice, under its own turn, one more per send. So the pane view
    /// hands over only a reading of the transcript it is on, and opens each
    /// transcript at nothing instead. A mark it already holds is kept, since
    /// nothing is above nothing; one it doesn't starts where a first reading
    /// can let go of a message sent before the transcript was named.
    func testOpeningATranscriptMarksItAtNothingAndKeepsAMarkItHolds() {
        let pane = pane()
        pane.heard(4, of: transcript, for: key)
        pane.send("hello")
        pane.heard(0, of: transcript, for: key)
        XCTAssertEqual(pane.saying(for: key).count, 1)
        pane.heard(5, of: transcript, for: key)
        XCTAssertEqual(pane.saying(for: key).count, 0)

        let fresh = SessionPane()
        fresh.open(PaneAttachment(hostKey: key, workingDirectory: "/tmp", sessionID: nil))
        fresh.hostSend = { _, _ in }
        fresh.heard(0, of: nil, for: key)
        fresh.send("first words")
        fresh.heard(0, of: "named", for: key)
        fresh.heard(1, of: "named", for: key)
        XCTAssertEqual(fresh.saying(for: key).count, 0)
    }

    // MARK: - Driving

    private let key = "/tmp/project#session"
    private let transcript = "session"

    private func pane() -> SessionPane {
        let pane = SessionPane()
        pane.open(PaneAttachment(hostKey: key, workingDirectory: "/tmp", sessionID: "session"))
        pane.hostSend = { _, _ in }
        return pane
    }
}
