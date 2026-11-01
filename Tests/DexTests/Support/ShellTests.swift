import XCTest
@testable import DexCore

final class ShellTests: XCTestCase {

    func testReadsBothStreamsAndTheExitCode() throws {
        let result = try Shell.run(["sh", "-c", "printf out; printf err >&2; exit 3"])
        XCTAssertEqual(result.stdoutText, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 3)
    }

    func testOutputLargerThanAPipeBufferDoesNotDeadlock() throws {
        let result = try Shell.run(["sh", "-c", "yes abcdefghij | head -40000"])
        XCTAssertEqual(result.stdout.count, 40_000 * 11)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunsInTheDirectoryItIsGiven() throws {
        let result = try Shell.run(["pwd"], workingDirectory: "/usr")
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "/usr")
    }

    func testTheEnvironmentIsAddedOverThisProcesss() throws {
        let result = try Shell.run(["sh", "-c", "printf '%s|%s' \"$DEX_SHELL_TEST\" \"$HOME\""],
                                   environment: ["DEX_SHELL_TEST": "yes"])
        XCTAssertEqual(result.stdoutText, "yes|\(ProcessInfo.processInfo.environment["HOME"] ?? "")")
    }

    /// A chunk that ends mid-line has to reach the reader before the line is
    /// finished — `recheck.sh` holds a probe's line open for as long as the
    /// probe runs, and that name is the whole point of streaming.
    func testOutputIsStreamedBeforeTheLineIsFinished() throws {
        let seen = Lock<[String]>([])
        let result = try Shell.run(
            ["sh", "-c", "printf 'name   '; sleep 0.3; printf 'ok\\n'; printf 'err\\n' >&2"],
            onOutput: { data, stream in
                seen.withLock { $0.append("\(stream):" + String(decoding: data, as: UTF8.self)) }
            }
        )
        XCTAssertEqual(result.stdoutText, "name   ok\n")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(seen.value.first, "stdout:name   ", "the first chunk arrived only once the line was complete")
        XCTAssertTrue(seen.value.contains("stderr:err\n"))
    }

    func testACommandPastItsTimeoutIsEnded() throws {
        let started = Date()
        let result = try Shell.run(["sh", "-c", "printf early; exec sleep 30"], timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.stdoutText, "early")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testACommandThatIgnoresTheTerminateIsKilled() throws {
        let started = Date()
        let result = try Shell.run(["sh", "-c", "trap '' TERM; printf early; exec sleep 30"], timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.stdoutText, "early")
    }

    func testAMissingExecutableIsAnExitCodeNotAThrow() throws {
        XCTAssertNotEqual(try Shell.run(["definitely-not-a-command-xyz"]).exitCode, 0)
    }

    func testACommandCostsNothingBeyondTheCommand() throws {
        let runs = 20

        // What waiting on a run loop rather than on the exit costs, per command.
        let aRunLoopStep = 0.05

        let started = Date()
        for _ in 0..<runs { _ = try Shell.run(["true"]) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, Double(runs) * aRunLoopStep,
            "\(Int(elapsed * 1000))ms for \(runs) runs of `true` — that is a wait per command"
        )
    }
}
