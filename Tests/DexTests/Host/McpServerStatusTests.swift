import XCTest

@testable import DexCore

final class McpServerStatusTests: XCTestCase {

    private func session(_ key: String, _ servers: [HostMcpServer]?) -> HostSessionSummary {
        HostSessionSummary(key: key, sessionId: nil, cwd: "/tmp", name: nil, state: .running,
                           model: nil, permissionMode: "default", startedAt: "2026-09-27T00:00:00Z",
                           mcpServers: servers)
    }

    // On the wire

    func testTheEventDecodesAsALevel() throws {
        let line = Data(#"{"type":"session.mcp","key":"k","servers":[{"name":"notes","status":"failed","error":"ECONNREFUSED"},{"name":"memory","status":"connected"}]}"#.utf8)
        guard case .sessionMcp(let key, let servers) = try JSONDecoder().decode(HostEvent.self, from: line)
        else { return XCTFail("not session.mcp") }
        XCTAssertEqual(key, "k")
        XCTAssertEqual(servers, [HostMcpServer(name: "notes", status: "failed", error: "ECONNREFUSED"),
                                 HostMcpServer(name: "memory", status: "connected")])
    }

    func testAnInitFromAnOlderHostHasNoServers() throws {
        let line = Data(#"{"type":"session.init","key":"k","sessionId":"s","cwd":"/tmp","model":null,"permissionMode":"default","tools":[],"commands":null}"#.utf8)
        guard case .sessionInit(let start) = try JSONDecoder().decode(HostEvent.self, from: line)
        else { return XCTFail("not an init") }
        XCTAssertNil(start.mcpServers)
    }

    /// Init has statuses and no errors; the report behind it has the errors.
    /// Whichever came last is what is held.
    func testTheReportReplacesWhatInitSaid() {
        var index = HostSessionIndex()
        index.apply(.welcome(HostWelcome(host: "0.1.0", sdk: "0.3.283", sdkOnDisk: nil, build: nil, busy: nil,
                                         modes: [], efforts: nil, outputStyles: nil, pid: 1,
                                         sessions: [session("k", [HostMcpServer(name: "notes", status: "failed")])],
                                         pending: [], protocolVersion: 1)))
        index.apply(.sessionMcp(key: "k", servers: [HostMcpServer(name: "notes", status: "failed", error: "refused")]))
        XCTAssertEqual(index.sessions["k"]?.mcpServers?.first?.error, "refused")
    }

    // In Settings

    func testTheWorstStatusIsShownWithHowManySayIt() {
        let rows = McpServerSummary.of([
            session("a", [HostMcpServer(name: "notes", status: "connected")]),
            session("b", [HostMcpServer(name: "notes", status: "failed", error: "refused")]),
            session("c", [HostMcpServer(name: "notes", status: "connected")]),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, "failed")
        XCTAssertEqual(rows[0].error, "refused")
        XCTAssertEqual(rows[0].agreeing, 1)
        XCTAssertEqual(rows[0].reporting, 3)
    }

    func testTroubleComesFirstThenByName() {
        let rows = McpServerSummary.of([
            session("a", [HostMcpServer(name: "alpha", status: "connected"),
                          HostMcpServer(name: "zeta", status: "needs-auth"),
                          HostMcpServer(name: "beta", status: "pending")]),
        ])
        XCTAssertEqual(rows.map(\.name), ["beta", "zeta", "alpha"])
    }

    func testSessionsThatHaveNotSaidAddNothing() {
        XCTAssertEqual(McpServerSummary.of([session("a", nil)]), [])
    }

}
