import XCTest
@testable import DexUI
@testable import DexCore
@testable import DexProbes

/// A copy is assembled by place, so the rows the pane stands in for at the end
/// have to be numbered in the order they are drawn.
@MainActor
final class TranscriptPaneRowsTests: XCTestCase {

    private func feed() async throws -> (TranscriptFeed, any TranscriptSource) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("s.jsonl")
        try """
        {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
        {"type":"queue-operation","operation":"enqueue","content":"taken one"}
        {"type":"queue-operation","operation":"enqueue","content":"still waiting"}
        {"type":"queue-operation","operation":"dequeue"}

        """.write(to: file, atomically: true, encoding: .utf8)

        let feed = TranscriptFeed()
        let source = LiveProbe.Source(path: file.path)
        let run = Task { await feed.run(sessionID: "s", source: source) }
        for _ in 0..<400 where feed.items.isEmpty || feed.queued.isEmpty || feed.taken.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        run.cancel()
        await run.value
        XCTAssertEqual(feed.queued.map(\.text), ["still waiting"])
        XCTAssertEqual(feed.taken.map(\.text), ["taken one"])
        return (feed, source)
    }

    private func pane(_ feed: TranscriptFeed, _ source: any TranscriptSource) -> TranscriptPane {
        TranscriptPane(
            attachment: PaneAttachment(hostKey: "s", workingDirectory: nil, sessionID: "s"),
            feed: feed, isWorking: true, isLive: true, source: source,
            saying: [
                SessionPane.Said(text: "started it", intoTurn: false),
                SessionPane.Said(text: "sent into it", intoTurn: true),
            ]
        )
    }

    private func kinds(_ rows: [ColumnRow]) -> [String] {
        rows.map { $0.id.components(separatedBy: ":").first ?? $0.id }
    }

    func testTheTailIsNumberedInTheOrderItIsDrawn() async throws {
        let (feed, source) = try await feed()

        let thinking = pane(feed, source).rows
        XCTAssertEqual(kinds(thinking).suffix(5), ["said", "taken", "working", "said", "queued"])
        XCTAssertEqual(thinking.map(\.place), thinking.map(\.place).sorted())
        XCTAssertEqual(Set(thinking.map(\.place)).count, thinking.count)
    }
}
