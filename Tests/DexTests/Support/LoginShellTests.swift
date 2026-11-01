import XCTest
@testable import DexCore

final class LoginShellTests: XCTestCase {

    func testReadsThePathAnInteractiveShellSetsUp() throws {
        let shell = try fakeShell("""
        #!/bin/sh
        PATH=/usr/bin:/bin
        case "$1" in -i) echo "welcome back"; PATH="$HOME/.local/bin:$PATH" ;; esac
        shift; shift; shift
        eval "$1"
        echo "goodbye"
        """)
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }

        let path = LoginShell.probePath(environment: ["SHELL": shell.path])

        XCTAssertEqual(path, NSHomeDirectory() + "/.local/bin:/usr/bin:/bin")
    }

    func testAnInteractiveShellThatNeverRunsTheCommandFallsBackToALoginOne() throws {
        let shell = try fakeShell("""
        #!/bin/sh
        PATH=/usr/bin:/bin
        case "$1" in -i) exec /usr/bin/false ;; esac
        shift; shift
        eval "$1"
        """)
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }

        XCTAssertEqual(LoginShell.probePath(environment: ["SHELL": shell.path]), "/usr/bin:/bin")
    }

    func testReadsAnyVariableTheShellSetsAndNothingForOneItDoesnt() throws {
        let shell = try fakeShell("""
        #!/bin/sh
        case "$1" in -i) export DEX_TEST_VALUE=from-rc ;; esac
        shift; shift; shift
        eval "$1"
        """)
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }

        XCTAssertEqual(LoginShell.probe("DEX_TEST_VALUE", environment: ["SHELL": shell.path]), "from-rc")
        XCTAssertNil(LoginShell.probe("DEX_TEST_UNSET", environment: ["SHELL": shell.path]))
    }

    func testOutputWithoutThePathReadsAsNone() {
        XCTAssertNil(LoginShell.extract(from: "zsh: command not found: rbenv\n"))
    }

    private func fakeShell(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("zsh")
        try script.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        return shell
    }
}
