import XCTest

@testable import DexCore

final class HostLocationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostLocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheBundledNodeIsTheHelperInsideTheApp() throws {
        let app = scratch.appendingPathComponent("Dex.app")
        let helper = app.appendingPathComponent(HostIdentity.code.helperExecutable)
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        XCTAssertEqual(HostLocation.bundledNode(bundleURL: app), helper.path)
        XCTAssertEqual(helper.path.hasSuffix("DexHost.app/Contents/MacOS/DexHost"), true)
    }

    func testAnAppWithoutTheHelperFallsBackToTheSearch() {
        XCTAssertNil(HostLocation.bundledNode(bundleURL: scratch.appendingPathComponent("Dex.app")))
        XCTAssertNil(HostLocation.bundledNode(bundleURL: nil))
    }

    func testALocalHostStillNamesWhatRunsIt() {
        let location = HostLocation(
            socket: "/tmp/host.sock", entry: "/a/Sidecar/src/host.ts", node: "/bin/node")
        XCTAssertEqual(location.node, "/bin/node")
        XCTAssertEqual(location.entry, "/a/Sidecar/src/host.ts")
    }

    func testTheHostSocketAndTheFleetFileShareTheSupportFolder() {
        let environment = ["CLAUDE_CONFIG_DIR": "/c"]
        let folder = "/c/" + BundleIdentity.supportFolder
        XCTAssertEqual(HostLocation.socketPath(identity: .code, environment: environment), folder + "/host.sock")
        XCTAssertEqual(SupportDirectory.url(configDirectory: URL(fileURLWithPath: "/c")).path, folder)
    }

    /// The host derives its state folder and the fleet file from its own constant.
    func testTheHostNamesTheSameSupportFolder() throws {
        let support = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sidecar/src/support.ts")
        let source = try String(contentsOf: support, encoding: .utf8)
        XCTAssertTrue(
            source.contains("export const SUPPORT_FOLDER = \"\(BundleIdentity.supportFolder)\";"), source)
    }

}
