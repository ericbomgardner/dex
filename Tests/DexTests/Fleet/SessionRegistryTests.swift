import XCTest
@testable import DexCore

final class SessionRegistryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var alive: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    func testJoinsTheAddressToTheSessionId() throws {
        try write("2921.json", """
        {"pid":\(alive),"sessionId":"3f1c9a20-7b4e-4d2a-9c11-5e8f0a6b2d47","cwd":"/repo",\
        "name":"copper-agents-worker-91","nameSource":"derived","entrypoint":"sdk-ts"}
        """)

        XCTAssertEqual(
            SessionRegistry.addresses(in: directory),
            ["3f1c9a20-7b4e-4d2a-9c11-5e8f0a6b2d47": "copper-agents-worker-91"]
        )
    }

    func testReadsWhereTheSessionIsAndWhetherItsNameWasMadeUp() throws {
        try write("1.json", """
        {"pid":\(alive),"sessionId":"a","cwd":"/repo/.claude/worktrees/x","name":"repo-91","nameSource":"derived"}
        """)
        try write("2.json", #"{"pid":\#(alive),"sessionId":"b","name":"Fix the loader","nameSource":"user"}"#)
        try write("3.json", #"{"pid":\#(alive),"sessionId":"c","name":"Fix it","nameSource":"auto","cwd":""}"#)

        XCTAssertEqual(SessionRegistry.entries(in: directory), [
            "a": .init(address: "repo-91", cwd: "/repo/.claude/worktrees/x", isDerived: true),
            "b": .init(address: "Fix the loader"),
            "c": .init(address: "Fix it"),
        ])
    }

    func testReadsOnlyPidNamedRecords() throws {
        try write("2921.json", #"{"pid":\#(alive),"sessionId":"a","name":"one"}"#)
        try write("2921.beb7c347.key", #"{"peerToken":"5ee7"}"#)
        try write("notes.json", #"{"pid":\#(alive),"sessionId":"b","name":"two"}"#)
        try write(".json", #"{"pid":\#(alive),"sessionId":"c","name":"three"}"#)

        XCTAssertEqual(SessionRegistry.addresses(in: directory), ["a": "one"])
    }

    func testSkipsARecordMissingEitherHalfOfTheJoin() throws {
        try write("1.json", #"{"pid":\#(alive),"sessionId":"a"}"#)
        try write("2.json", #"{"pid":\#(alive),"name":"two"}"#)
        try write("3.json", #"{"pid":\#(alive),"sessionId":"c","name":""}"#)
        try write("4.json", "not json")

        XCTAssertEqual(SessionRegistry.addresses(in: directory), [:])
    }

    func testSkipsARecordWhoseProcessIsGone() throws {
        try write("1.json", #"{"pid":\#(alive),"sessionId":"a","name":"live"}"#)
        try write("2.json", #"{"pid":2147483000,"sessionId":"b","name":"stale"}"#)
        try write("3.json", #"{"sessionId":"c","name":"unsaid"}"#)

        XCTAssertEqual(SessionRegistry.addresses(in: directory), ["a": "live", "c": "unsaid"])
    }

    func testReadsNothingFromAMissingDirectory() {
        let missing = directory.appendingPathComponent("absent")
        XCTAssertEqual(SessionRegistry.addresses(in: missing), [:])
    }
}
