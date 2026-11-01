import XCTest
@testable import DexCore

final class ConfigDirectoryTests: XCTestCase {
    func testDefaultsToDotClaudeUnderHome() {
        let resolved = ConfigDirectory.resolve(environment: [:], home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(resolved.path, "/Users/me/.claude")
    }

    func testHonoursConfigDirOverride() {
        let resolved = ConfigDirectory.resolve(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/alt-claude"],
            home: URL(fileURLWithPath: "/Users/me")
        )
        XCTAssertEqual(resolved.path, "/opt/alt-claude")
    }

    func testIgnoresEmptyOverride() {
        let resolved = ConfigDirectory.resolve(
            environment: ["CLAUDE_CONFIG_DIR": ""],
            home: URL(fileURLWithPath: "/Users/me")
        )
        XCTAssertEqual(resolved.path, "/Users/me/.claude")
    }
}
