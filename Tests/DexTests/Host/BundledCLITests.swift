import XCTest

@testable import DexCore

/// Finding the `claude` the SDK ships, which is a different binary from the one
/// on your PATH and the one every hosted session actually runs.
final class BundledCLITests: XCTestCase {

    /// A sidecar tree with a platform package in it, named for whichever
    /// architecture the caller asks for.
    private func sidecar(platform: String?, executable: Bool = true) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bundled-cli-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Sidecar/src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let entry = source.appendingPathComponent("host.ts")
        try Data().write(to: entry)

        if let platform {
            let package = root.appendingPathComponent(
                "Sidecar/node_modules/@anthropic-ai/claude-agent-sdk-\(platform)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let binary = package.appendingPathComponent("claude")
            try Data().write(to: binary)
            if executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: binary.path
                )
            }
        }
        return entry.path
    }

    func testFoundBesideTheHostItIsShippedWith() throws {
        let entry = try sidecar(platform: "darwin-arm64")
        let cli = HostLocation.bundledCLI(entry: entry)

        XCTAssertEqual((cli as NSString?)?.lastPathComponent, "claude")
        XCTAssertTrue(cli?.contains("node_modules/@anthropic-ai") == true)
    }

    /// npm installs one platform package or the other, so naming a single one
    /// answers nil on the machine that has the other — and the app would quietly
    /// fall back to describing the CLI you type instead.
    func testTheOtherArchitectureIsFoundToo() throws {
        let entry = try sidecar(platform: "darwin-x64")
        XCTAssertNotNil(HostLocation.bundledCLI(entry: entry))
    }

    func testNoSidecarAndNoPackageAnswerNothingRatherThanAPathThatIsNotThere() throws {
        XCTAssertNil(HostLocation.bundledCLI(entry: nil))
        XCTAssertNil(HostLocation.bundledCLI(entry: try sidecar(platform: nil)))
    }

    /// A file that cannot be run is not a CLI. Dependencies half-installed is a
    /// state a build can leave behind, and `--version` on it would just fail.
    func testAPackageWithNothingRunnableInItIsNotAnAnswer() throws {
        let entry = try sidecar(platform: "darwin-arm64", executable: false)
        XCTAssertNil(HostLocation.bundledCLI(entry: entry))
    }
}
