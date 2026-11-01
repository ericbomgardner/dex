import XCTest
@testable import DexCore

final class FinishedWorkingTests: XCTestCase {
    func testTerminalStatesHaveFinished() {
        for state in [HostSessionState.done, .idle, .failed] {
            XCTAssertTrue(makeSession("s", state: state).hasFinishedWorking, state.raw)
            XCTAssertTrue(makeSession("s", state: state, hostPID: 4242).hasFinishedWorking, state.raw)
        }
    }

    func testWorkingAskingAndUnknownHaveNot() {
        for state in [HostSessionState.starting, .running, .compacting, .asking, .unknown("quiescing")] {
            XCTAssertFalse(makeSession("s", state: state).hasFinishedWorking, state.raw)
        }
    }
}

final class OutcomeTests: XCTestCase {
    func testHeadlineTakesFirstLine() {
        let outcome = ActionOutcome(label: RebuildRunner.label, succeeded: false,
                                    message: "build failed\nsee the log for what broke")
        XCTAssertEqual(outcome.headline, "build failed")
    }

    func testHeadlineFallsBackWhenMessageEmpty() {
        XCTAssertEqual(
            ActionOutcome(label: RebuildRunner.label, succeeded: true, message: "").headline,
            "done"
        )
        XCTAssertEqual(
            ActionOutcome(label: RebuildRunner.label, succeeded: false, message: "").headline,
            "failed"
        )
    }

    func testSuccessDwellsAndClearsItself() {
        let outcome = ActionOutcome(label: "New session", succeeded: true, message: "done")
        XCTAssertEqual(outcome.dwell, ActionOutcome.successDwell)
    }

    func testFailureNeverTimesOut() {
        let outcome = ActionOutcome(label: "New session", succeeded: false,
                                    message: "error: option '--permission-mode <mode>' argument 'bogus' is invalid")
        XCTAssertNil(outcome.dwell)
    }

    func testReadoutNeverTimesOutOnSuccess() {
        let outcome = ActionOutcome(label: "Supervisor", succeeded: true,
                                    message: "daemon running", isReadout: true)
        XCTAssertNil(outcome.dwell)
    }

    func testOutcomesAreConfirmationsByDefault() {
        let outcome = ActionOutcome(label: "New session", succeeded: true, message: "ok")
        XCTAssertFalse(outcome.isReadout)
        XCTAssertNotNil(outcome.dwell)
    }

    func testAnOutcomeIsShownUnlessMarkedSelfEvident() {
        let outcome = ActionOutcome(label: "New session", succeeded: true, message: "ok")
        XCTAssertFalse(outcome.successVisibleInList)
        XCTAssertTrue(outcome.shouldBeShown)
    }

    func testSelfEvidentSuccessIsNotWorthShowing() {
        let outcome = ActionOutcome(label: RebuildRunner.label, succeeded: true,
                                    message: "/Applications/Dex.app",
                                    successVisibleInList: true)
        XCTAssertFalse(outcome.shouldBeShown)
    }

    func testAFailureIsShownEvenWhenMarkedSelfEvident() {
        let outcome = ActionOutcome(
            label: RebuildRunner.label, succeeded: false,
            message: "built, but no bundle to open",
            successVisibleInList: true
        )
        XCTAssertTrue(outcome.shouldBeShown)
        XCTAssertNil(outcome.dwell, "it stays until dismissed")
    }

    func testTheDetailLineIsDrawnUnlessSuppressed() {
        let outcome = ActionOutcome(label: "New session", succeeded: true,
                                    message: "backgrounded 7c509585")
        XCTAssertEqual(outcome.detail, "backgrounded 7c509585")
    }

    func testASuccessThatOnlyRestatesTheLabelDropsItsDetail() {
        let outcome = ActionOutcome(
            label: "New session", succeeded: true,
            message: "backgrounded · \u{1B}[36mde58c1c5\u{1B}[39m\n"
                + "\u{1B}[2m  claude agents    list sessions\u{1B}[22m",
            successMessageRestatesLabel: true
        )
        XCTAssertNil(outcome.detail)
        XCTAssertTrue(outcome.shouldBeShown, "the toast is still shown")
    }

    func testAFailureKeepsItsDetail() {
        let outcome = ActionOutcome(
            label: "New session", succeeded: false,
            message: "error: option '--permission-mode <mode>' argument 'bogus' is invalid",
            successMessageRestatesLabel: true
        )
        XCTAssertEqual(
            outcome.detail,
            "error: option '--permission-mode <mode>' argument 'bogus' is invalid"
        )
        XCTAssertNil(outcome.dwell, "it stays until dismissed")
    }
}

final class ClaudeExecutableTests: XCTestCase {
    func testExplicitOverrideTakesPrecedence() {

        let resolved = ClaudeExecutable.resolve(environment: ["CLAUDE_BINARY": "/bin/sh"])
        XCTAssertEqual(resolved, "/bin/sh")
    }

    func testIgnoresOverrideThatIsNotExecutable() {
        let resolved = ClaudeExecutable.resolve(
            environment: ["CLAUDE_BINARY": "/nonexistent/claude", "SHELL": "/nonexistent/sh"]
        )
        XCTAssertNotEqual(resolved, "/nonexistent/claude")
    }

    func testFallbackListCoversTheDefaultInstallLocation() {
        XCTAssertTrue(ClaudeExecutable.fallbackLocations.contains("~/.local/bin/claude"))
        XCTAssertTrue(ClaudeExecutable.fallbackLocations.contains("/opt/homebrew/bin/claude"))
    }

    func testAlwaysResolvesToANonEmptyPath() {
        let resolved = ClaudeExecutable.resolve(
            environment: ["SHELL": "/nonexistent/sh"],
            fileManager: FileManager()
        )
        XCTAssertFalse(resolved.isEmpty)
    }

    func testTildeExpansion() {
        XCTAssertFalse(ClaudeExecutable.expand("~/.local/bin/claude").hasPrefix("~"))
    }
}

final class ClaudeExecutableLookupTests: XCTestCase {
    private func shell(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    func testAShellThatRunsOutOfTimeIsNotTakenAsTheAnswer() throws {
        let found = ClaudeExecutable.lookup(environment: ["SHELL": try shell("exec sleep 5")], timeout: 0.3)
        XCTAssertFalse(found.settled)
        XCTAssertFalse(found.path.isEmpty)
    }

    func testAShellThatAnswersSettlesIt() throws {
        let found = ClaudeExecutable.lookup(environment: ["SHELL": try shell("echo /bin/sh")], timeout: 5)
        XCTAssertEqual(found.path, "/bin/sh")
        XCTAssertTrue(found.settled)
    }
}
