import XCTest

@testable import DexUI
@testable import DexProbes

/// Where the ask card's field registers its undo actions.
///
/// Driven through `AskCardProbe`, which hosts the real card in an offscreen
/// window, types into the answer field and then throws the card away — which is
/// what the pane does every time it is pointed at another session. Nothing here
/// is arithmetic we own: it is where AppKit files an `NSTextView`'s undo, and
/// the only way to read it is to make one and look.
///
/// The defect: the actions went to the *window's* undo manager, which does not
/// retain what they are aimed at. The card went, the editor was freed, and the
/// next Cmd-Z popped one of them into freed memory — `objc_msgSend` under
/// `-[_NSUndoStack popAndInvoke]`, with the whole app going with it.
@MainActor
final class AskCardUndoTests: XCTestCase {

    /// One staging for the four readings: each is a window, a click sweep and a
    /// teardown, and they all come off the same run.
    private static var measured: AskCardProbe.UndoReading?

    private func reading() throws -> AskCardProbe.UndoReading {
        if let measured = Self.measured { return measured }
        let taken = try XCTUnwrap(AskCardProbe.undoStacks(), "the card never opened its answer field")
        Self.measured = taken
        return taken
    }

    func testTheFieldKeepsAnUndoStackOfItsOwn() throws {
        XCTAssertTrue(try reading().ownStack)
    }

    /// The half a fix could take away by turning undo off.
    func testUndoInTheFieldStillTakesTheTypingBack() throws {
        XCTAssertTrue(try reading().fieldUndoes)
    }

    /// The defect itself. The typing has to be registered somewhere — which is
    /// what the reading above says — and the window is the one place it must
    /// not be, since what is left there outlives the card that put it there.
    func testTheCardGoingAwayLeavesNothingOnTheWindowsStack() throws {
        XCTAssertFalse(
            try reading().windowHolds,
            "the window is holding an undo action aimed at an editor the card has thrown away"
        )
    }
}
