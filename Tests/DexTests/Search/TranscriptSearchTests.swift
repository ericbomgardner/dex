import XCTest

@testable import DexCore

final class TranscriptSearchTests: XCTestCase {
    private var config: URL!

    override func setUpWithError() throws {
        config = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: config)
    }


    /// In the order the CLI flushes them: the queue record before the turn it
    /// opens, the tool result before the reply that reads it, the title last.
    private func write(
        _ id: String,
        cwd: String = "/Users/someone/repo",
        entrypoint: String = "sdk-ts",
        user: String,
        toolOutput: String = "",
        reply: String,
        title: String? = nil,
        written: Date = Date()
    ) throws {
        func record(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let common: [String: Any] = ["cwd": cwd, "entrypoint": entrypoint, "sessionId": id, "isSidechain": false]
        var lines = [
            record(["type": "queue-operation", "operation": "enqueue", "sessionId": id, "content": user]),
            record(common.merging(["type": "user", "uuid": "u1", "message": ["role": "user", "content": user]]) { $1 }),
            record(common.merging(["type": "assistant", "uuid": "a1", "message": [
                "role": "assistant", "model": "claude-opus-5",
                "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]],
            ]]) { $1 }),
            record(common.merging(["type": "user", "uuid": "u2", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": toolOutput],
            ]]]) { $1 }),
            record(common.merging(["type": "assistant", "uuid": "a2", "message": [
                "role": "assistant", "model": "claude-opus-5",
                "content": [["type": "text", "text": reply]],
            ]]) { $1 }),
        ]
        if let title { lines.append(record(["type": "ai-title", "aiTitle": title, "sessionId": id])) }

        let folder = config.appendingPathComponent("projects")
            .appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
    }

    private func search(_ query: String) -> [TranscriptHit] {
        TranscriptSearch(configDirectory: config, reopenable: { _ in true }).search(query)
    }


    func testFindsWhatWasTypedAndWhatWasSaidIgnoringCase() throws {
        try write("typed", user: "Can we plan the Lisbon trip?", reply: "Sure.")
        try write("said", user: "Where next?", reply: "How about LISBON in spring")

        XCTAssertEqual(Set(search("lisbon").map(\.sessionID)), ["typed", "said"])
    }

    func testToolOutputIsNotAMatch() throws {
        try write("noisy", user: "list it", toolOutput: "lisbon.txt", reply: "Done.")
        XCTAssertTrue(search("lisbon").isEmpty)
    }

    func testTerminalSessionsAreLeftOut() throws {
        try write("terminal", entrypoint: "cli", user: "lisbon", reply: "ok")
        try write("old-dex", entrypoint: "sdk-cli", user: "lisbon", reply: "ok")
        XCTAssertEqual(search("lisbon").map(\.sessionID), ["old-dex"])
    }


    func testNewestFirstWithEveryMatchCounted() throws {
        try write("older", user: "lisbon", reply: "ok", written: Date(timeIntervalSinceNow: -86_400))
        try write("newer", user: "lisbon please", reply: "lisbon it is")

        let hits = search("lisbon")
        XCTAssertEqual(hits.map(\.sessionID), ["newer", "older"])
        XCTAssertEqual(hits.first?.matches, 2)
    }

    func testAQueryWithQuotesMatchesThroughTheJSONEscaping() throws {
        try write("quoted", user: #"rename it to "Blue Moon" please"#, reply: "ok")
        XCTAssertEqual(search(#""blue moon""#).map(\.sessionID), ["quoted"])
    }

    func testTheSnippetMarksTheMatch() throws {
        try write("one", user: "first line\nwe should visit Lisbon soon", reply: "ok")
        let hit = try XCTUnwrap(search("lisbon").first)
        let characters = Array(hit.snippet)
        XCTAssertEqual(String(characters[hit.highlight]), "Lisbon")
        XCTAssertFalse(hit.snippet.contains("\n"))
    }

    func testOnlyAFolderThatIsStillThereAndIsNotScratchCanBeReopened() {
        XCTAssertTrue(TranscriptSearch.isReopenable(NSHomeDirectory()))
        XCTAssertFalse(TranscriptSearch.isReopenable("/no/such/folder"))
        XCTAssertFalse(TranscriptSearch.isReopenable(NSTemporaryDirectory()))
        XCTAssertFalse(TranscriptSearch.isReopenable(config.path))
    }

    func testCaseFoldsBeyondASCII() throws {
        try write("accent", user: "das ist über alles", reply: "ok")
        XCTAssertEqual(search("Über").map(\.sessionID), ["accent"])
    }

    func testToolTrafficDoesNotCrowdOutWhatWasSaid() throws {
        try write("busy", user: "list it", toolOutput: "x", reply: "SessionStore it is")
        let file = config.appendingPathComponent("projects/-Users-someone-repo/busy.jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        let tool = #"{"type":"assistant","cwd":"/Users/someone/repo","entrypoint":"sdk-ts","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Grep","input":{"pattern":"SessionStore"}}]}}"#
        lines.insert(contentsOf: Array(repeating: tool, count: TranscriptSearch.decodedPerFile + 10), at: 2)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(search("sessionstore").first?.matches, 1)
    }

    func testASessionFiledUnderTwoFoldersIsOneHit() throws {
        try write("moved", cwd: "/Users/someone/repo", user: "lisbon", reply: "ok", written: Date(timeIntervalSinceNow: -60))
        try write("moved", cwd: "/Users/someone/repo-worktree", user: "lisbon", reply: "ok")

        let hits = search("lisbon")
        XCTAssertEqual(hits.map(\.sessionID), ["moved"])
        XCTAssertEqual(hits.first?.cwd, "/Users/someone/repo-worktree")
    }


    func testOneCharacterSearchesNothing() throws {
        try write("one", user: "a", reply: "a")
        XCTAssertTrue(search("a").isEmpty)
    }

}
