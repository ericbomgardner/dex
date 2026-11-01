import XCTest
@testable import DexUI
@testable import DexCore

/// What a switch back to a session costs: nothing, since the feed keeps what
/// its last run read and starts from there.
@MainActor
final class TranscriptFeedTests: XCTestCase {

    /// A source whose read can be made to hang, so the only way items reach
    /// the pane is out of what the feed kept.
    private final class Source: TranscriptSource, @unchecked Sendable {
        var lines: [String: [Data]] = [:]
        var hangs = false
        /// Per path, so one session's read can outlast a switch to another.
        var delays: [String: Duration] = [:]
        let interval = Duration.milliseconds(10)

        func locate(sessionID: String) async -> String? { "/\(sessionID).jsonl" }

        func read(_ path: String, from offset: Int) async -> TranscriptRead {
            if hangs {
                try? await Task.sleep(for: .seconds(10))
                return TranscriptRead(offset: offset)
            }
            if let delay = delays[path] { try? await Task.sleep(for: delay) }
            let all = lines[path] ?? []
            let rest = Array(all.dropFirst(offset))
            return TranscriptRead(lines: rest, offset: all.count)
        }

        func subagentDirectory(besideParent path: String) -> String? { nil }
        func locateAgent(_ agentID: String, in directory: String) async -> String? { nil }
        func identity(agentID: String, in directory: String) async -> SubagentIdentity? { nil }
        func context(agentID: String, in directory: String) async -> SessionContext? { nil }
        func changes(to path: String) -> AsyncStream<Void>? { nil }
    }

    private func turn(_ text: String) -> Data {
        Data("""
        {"type":"user","uuid":"\(text)","message":{"content":"\(text)"}}
        """.utf8)
    }

    private func settle(_ feed: TranscriptFeed, until done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testComingBackToASessionDrawsItBeforeTheFileIsRead() async {
        let source = Source()
        source.lines["/a.jsonl"] = [turn("hello")]
        let feed = TranscriptFeed()

        let first = Task { await feed.run(sessionID: "a", source: source) }
        await settle(feed) { !feed.items.isEmpty }
        XCTAssertEqual(feed.items.count, 1)
        first.cancel()
        await first.value

        source.hangs = true
        let elsewhere = Task { await feed.run(sessionID: "b", source: source) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(feed.items.isEmpty, "another session's conversation must not draw under this one")
        elsewhere.cancel()
        await elsewhere.value

        let back = Task { await feed.run(sessionID: "a", source: source) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.phase, .reading)
        XCTAssertEqual(feed.heardOf, "a")
        back.cancel()
        await back.value
    }

    /// One feed outlives a switch. A read that outlasts the switch ends its run
    /// late, and what that run keeps has to be its own, not whatever the next
    /// session has since drawn on the feed.
    func testARunEndingAfterTheSwitchKeepsNothingOfTheNextSession() async {
        let source = Source()
        source.lines["/s.jsonl"] = [turn("s")]
        source.lines["/p.jsonl"] = [turn("p")]
        source.delays["/p.jsonl"] = .milliseconds(100)
        let feed = TranscriptFeed()

        let s = Task { await feed.run(sessionID: "s", source: source) }
        await settle(feed) { !feed.items.isEmpty }
        s.cancel()
        await s.value

        let p = Task { await feed.run(sessionID: "p", source: source) }
        try? await Task.sleep(for: .milliseconds(20))
        p.cancel()
        let back = Task { await feed.run(sessionID: "s", source: source) }
        await p.value
        XCTAssertEqual(feed.items.count, 1)
        back.cancel()
        await back.value

        source.hangs = true
        let again = Task { await feed.run(sessionID: "p", source: source) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(feed.items.isEmpty, "p never drew anything, so nothing of s may come back as p")
        again.cancel()
        await again.value
    }

    /// What was kept is a starting point, not the reading: the next pass picks
    /// up from where the last run stopped.
    func testWhatWasWrittenSinceIsReadOnTopOfWhatWasKept() async {
        let source = Source()
        source.lines["/a.jsonl"] = [turn("one")]
        let feed = TranscriptFeed()

        let first = Task { await feed.run(sessionID: "a", source: source) }
        await settle(feed) { !feed.items.isEmpty }
        first.cancel()
        await first.value

        source.lines["/a.jsonl"]?.append(turn("two"))
        let back = Task { await feed.run(sessionID: "a", source: source) }
        await settle(feed) { feed.items.count == 2 }
        XCTAssertEqual(feed.items.count, 2)
        back.cancel()
        await back.value
    }

    /// Found but not yet read draws as nothing, so a switch to a session on
    /// disk does not flash a glyph between two conversations.
    func testAFileFoundButNotYetReadIsOpening() async {
        let source = Source()
        source.hangs = true
        let feed = TranscriptFeed()
        let run = Task { await feed.run(sessionID: "a", source: source) }
        await settle(feed) { feed.phase == .opening }
        XCTAssertEqual(feed.phase, .opening)
        run.cancel()
        await run.value
    }
}
