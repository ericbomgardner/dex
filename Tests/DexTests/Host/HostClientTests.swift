import XCTest

@testable import DexCore

/// Drives a real host over a real socket. No session is started, so nothing
/// here reaches the network — it is the connect, spawn, handshake and reconnect
/// path only, which is the part that cannot be tested from a fixture.
final class HostClientTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("host-client-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Keeps the hosts these spawn writing their log here, not in the real config directory.
        setenv("DEX_HOST_STATE_DIR", scratch.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DEX_HOST_STATE_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A machine without node, or a checkout without the sidecar installed,
    /// should skip rather than fail: neither says anything about this code.
    /// Anchored on this file rather than on `HostLocation.entryPath()`, whose
    /// job is finding the sidecar beside a built app: under `swift test` the
    /// running executable is the toolchain's, nowhere near the checkout.
    private static var sidecarEntry: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Host
            .deletingLastPathComponent()  // DexTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("Sidecar/src/host.ts")
            .path
    }

    private func location() throws -> HostLocation {
        let entry = Self.sidecarEntry
        guard FileManager.default.isReadableFile(atPath: entry) else {
            throw XCTSkip("Sidecar not found at \(entry)")
        }
        guard
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: entry)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("node_modules").path
            )
        else {
            throw XCTSkip("Sidecar dependencies are not installed (npm install in Sidecar/)")
        }
        guard let node = HostLocation.node(searching: LoginShell.path()) else {
            throw XCTSkip("node was not found")
        }
        return HostLocation(
            socket: scratch.appendingPathComponent("host.sock").path,
            entry: entry,
            node: node
        )
    }

    private func makeClient(
        _ location: HostLocation,
        onEvent: @escaping @Sendable (HostEvent) -> Void = { _ in },
        onStatus: @escaping @Sendable (HostClient.Status) -> Void = { _ in }
    ) -> HostClient {
        HostClient(location: location, delivery: .main, onStatus: onStatus, onEvent: onEvent)
    }

    func testTheHostGetsTheLoginPathRatherThanLaunchds() {
        let location = HostLocation(socket: "/tmp/h.sock", entry: "/e", node: "/n")
        let environment = HostClient.hostEnvironment(
            for: location,
            inherited: ["PATH": LoginShell.guiFallbackPath, "HOME": "/Users/x"],
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin"
        )
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(environment["HOME"], "/Users/x")
        XCTAssertEqual(environment["DEX_HOST_SOCKET"], "/tmp/h.sock")
    }

    func testAnUnreadableLoginShellLeavesTheInheritedPath() {
        let location = HostLocation(socket: "/tmp/h.sock", entry: "/e", node: "/n")
        let environment = HostClient.hostEnvironment(
            for: location,
            inherited: ["PATH": LoginShell.guiFallbackPath],
            loginPath: nil
        )
        XCTAssertEqual(environment["PATH"], LoginShell.guiFallbackPath)
    }

    func testSpawnsTheHostWhenNobodyIsHoldingTheSocket() throws {
        let location = try location()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.socket))

        let connected = expectation(description: "connected")
        let welcomed = expectation(description: "welcome")
        let seen = UncheckedBox<HostWelcome?>(nil)

        let client = makeClient(
            location,
            onEvent: { event in
                if case .welcome(let welcome) = event {
                    seen.value = welcome
                    welcomed.fulfill()
                }
            },
            onStatus: { status in
                if case .connected = status { connected.fulfill() }
            }
        )
        addTeardownBlock { client.stop() }

        setenv("DEX_HOST_IDLE_MS", "1500", 1)
        client.start()
        wait(for: [connected, welcomed], timeout: 30)

        let welcome = try XCTUnwrap(seen.value)
        XCTAssertEqual(welcome.protocolVersion, HostProtocol.version)
        XCTAssertTrue(welcome.sessions.isEmpty)
        XCTAssertTrue(welcome.pending.isEmpty)
    }

    func testASecondClientJoinsTheHostAlreadyRunningRatherThanStartingAnother() throws {
        let location = try location()
        setenv("DEX_HOST_IDLE_MS", "4000", 1)

        let first = expectation(description: "first")
        let one = makeClient(location, onStatus: { if case .connected = $0 { first.fulfill() } })
        addTeardownBlock { one.stop() }
        one.start()
        wait(for: [first], timeout: 30)

        let second = expectation(description: "second")
        let two = makeClient(location, onStatus: { if case .connected = $0 { second.fulfill() } })
        addTeardownBlock { two.stop() }
        two.start()
        wait(for: [second], timeout: 15)
    }

    func testAnUnreachableHostIsReportedRatherThanRetriedForever() throws {
        let location = HostLocation(
            socket: scratch.appendingPathComponent("nothing.sock").path,
            entry: scratch.appendingPathComponent("absent.ts").path,
            node: "/usr/bin/false"
        )

        let gaveUp = expectation(description: "unavailable")
        let client = makeClient(location, onStatus: { status in
            if case .unavailable = status { gaveUp.fulfill() }
        })
        addTeardownBlock { client.stop() }

        client.start()
        wait(for: [gaveUp], timeout: 30)
    }

    func testASocketPathTooLongForTheKernelIsNamedRatherThanFailingAtBind() {
        let deep = "/tmp/" + String(repeating: "a", count: 120) + "/host.sock"
        XCTAssertThrowsError(
            try HostLocation.resolve(environment: ["DEX_HOST_SOCKET": deep], loginPath: { nil })
        ) { error in
            guard case HostLocation.Failure.socketPathTooLong = error else {
                return XCTFail("expected socketPathTooLong, got \(error)")
            }
        }
    }
}

/// A box for a value crossing the delivery queue in a test. The client hands
/// events to `.main`, and the test reads them after `wait(for:)` has run it.
private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
