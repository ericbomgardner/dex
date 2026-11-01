import XCTest
@testable import DexCore

/// The mode vocabulary and the row state stay pinned although the mode UI is
/// gone: the vocabulary is a reading of the CLI the probe keeps current, and
/// the row's mode still feeds the archive a resume replays.
final class PermissionModesTests: XCTestCase {

    /// The mode vocabulary and the transcript's disagree at the edges: the SDK
    /// takes names the transcript never writes, and the transcript writes one
    /// the SDK's list omits. A mode is only unrecognised if it is in neither —
    /// reading `default` as unknown would mark most sessions.
    func testTheTwoVocabulariesAreBothRecognised() {
        XCTAssertTrue(PermissionModes.recognises("plan"))
        XCTAssertTrue(PermissionModes.recognises("auto"))
        XCTAssertTrue(PermissionModes.recognises("default"), "written, but not in the offered list")
        XCTAssertTrue(PermissionModes.recognises("dontAsk"), "taken, but never written")
        XCTAssertFalse(PermissionModes.recognises("yolo"))
    }

    func testTheOfferedListDoesNotTakeDefault() {
        XCTAssertFalse(PermissionModes.all.contains("default"),
                       "sending no mode already means that")
    }

    // Reading a mode back off a row

    func testALiveModeStandsOnItsOwn() {
        XCTAssertEqual(
            makeRow("r", state: .running, livePermissionMode: "acceptEdits").livePermissionMode,
            "acceptEdits"
        )
    }

    func testNoModeReadsAsNoMode() {
        XCTAssertNil(makeRow("r", state: .running).livePermissionMode)
    }
}
