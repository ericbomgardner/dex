import XCTest

@testable import DexCore

final class BuildProgressTests: XCTestCase {

    // Lines the scripts print, as they print them

    func testAProbeLineNamesTheProbeAndWhereItSits() {
        XCTAssertEqual(BuildProgress.phase(of: "  10/19 resume-probe                    "),
                       "probe 10 of 19: resume-probe")
    }

    /// `swift build` numbers its steps in brackets; those fold to one word
    /// rather than reading as probes.
    func testACompileStepIsNotAProbe() {
        XCTAssertEqual(BuildProgress.phase(of: "[22/108] Compiling DexCore PullState.swift"), "compiling…")
        XCTAssertNil(BuildProgress.phase(of: "[22/108] Emitting module DexCore"))
    }

    func testThePinMoveIsSaidInVersions() {
        XCTAssertEqual(BuildProgress.phase(of: "==> SDK 0.3.268 → 0.3.269 (Claude Code 2.1.268 → 2.1.269)"),
                       "SDK 0.3.268 → 0.3.269")
    }

    func testTheScriptsOwnHeadingsAreRead() {
        XCTAssertEqual(BuildProgress.phase(of: "Installing Sidecar dependencies as pinned…"), "installing the Sidecar…")
        XCTAssertEqual(BuildProgress.phase(of: "Updating the Sidecar SDK…"), "asking npm for the newest SDK…")
        XCTAssertEqual(BuildProgress.phase(of: "Re-running the probes."), "re-running the probes…")
        XCTAssertEqual(BuildProgress.phase(of: "  swift test against the rewritten lists…"), "swift test against the rewritten lists…")
        XCTAssertEqual(BuildProgress.phase(of: "==> bundling /x/.build/\(AppCheckout.Layout.bundleName)"), "bundling the app…")
        XCTAssertEqual(BuildProgress.phase(of: "==> fetching node v26.5.0 for the host"), "fetching node for the host…")
    }

    func testChatterSaysNothing() {
        XCTAssertNil(BuildProgress.phase(of: ""))
        XCTAssertNil(BuildProgress.phase(of: "    committed on main — not pushed"))
        XCTAssertNil(BuildProgress.phase(of: "ok"))
    }

    // Reading a stream

    /// `recheck.sh` prints the probe's name and holds the line open until the
    /// verdict lands beside it, so the name is only ever on a partial line.
    func testAProbeNameOnAnUnfinishedLineIsRead() {
        var reader = BuildProgress.Reader()
        XCTAssertEqual(reader.feed(Data("Re-running the probes.\n\n  1/19 smoke      ".utf8), from: .stderr),
                       "probe 1 of 19: smoke")
        // The verdict completes the same line, which still names the same probe.
        XCTAssertEqual(reader.feed(Data("                ok\n".utf8), from: .stderr), "probe 1 of 19: smoke")
        XCTAssertEqual(reader.feed(Data("  2/19 auth-probe".utf8), from: .stderr), "probe 2 of 19: auth-probe")
    }

    /// A chunk boundary can fall anywhere, including inside the number.
    func testALineSplitAcrossChunksIsReadOnceWhole() {
        var reader = BuildProgress.Reader()
        XCTAssertNil(reader.feed(Data("  1".utf8), from: .stderr))
        XCTAssertEqual(reader.feed(Data("0/19 resume-probe".utf8), from: .stderr), "probe 10 of 19: resume-probe")
    }

    /// The two streams interleave — swift build on stdout, the script's own
    /// notes on stderr — and a partial line on one must not glue to the other.
    func testTheStreamsKeepSeparatePartialLines() {
        var reader = BuildProgress.Reader()
        XCTAssertNil(reader.feed(Data("  1".utf8), from: .stderr))
        XCTAssertEqual(reader.feed(Data("[1/5] Compiling X\n".utf8), from: .stdout), "compiling…")
        XCTAssertEqual(reader.feed(Data("/19 smoke".utf8), from: .stderr), "probe 1 of 19: smoke")
    }

    func testTheNewestPhaseInAChunkWins() {
        var reader = BuildProgress.Reader()
        XCTAssertEqual(reader.feed(Data("Re-running the probes.\n  1/2 a  ok\n  2/2 b".utf8), from: .stderr),
                       "probe 2 of 2: b")
    }
}
