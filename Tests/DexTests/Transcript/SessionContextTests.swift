import XCTest
@testable import DexCore

final class SessionContextTests: XCTestCase {

    private func digest(_ lines: String...) -> SessionDigest? {
        SessionDigestReader.digest(in: lines.map { Data($0.utf8) })
    }

    private func turn(
        input: Int = 0,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        model: String = "claude-opus-5",
        uuid: String = "a"
    ) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","message":{"model":"\(model)",\
        "content":[{"type":"text","text":"ok"}],\
        "usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheCreation),"output_tokens":40}}}
        """
    }

    // What the transcript says

    /// The three field names the whole feature rests on. A rename in the CLI
    /// reads as a session carrying nothing, which is silent — this is what says
    /// so instead. Same three `Scripts/maintainer/token-audit.py` adds up.
    func testContextIsTheThreeUsageFieldsAdded() {
        let reading = digest(turn(input: 300, cacheRead: 120_000, cacheCreation: 4_700))?.context
        XCTAssertEqual(reading?.tokens, 125_000)
    }

    func testTheModelIsReadOffTheSameTurn() {
        XCTAssertEqual(digest(turn(input: 10, model: "claude-sonnet-5"))?.context?.model,
                       "claude-sonnet-5")
    }

    /// The newest turn is the whole reading, which is what makes compaction need
    /// no special case: it lands as a turn that reads far less than the one
    /// before it, and the session really is carrying less afterwards.
    func testCompactionReadsAsTheDropItIs() {
        let before = turn(cacheRead: 400_000, uuid: "a")
        let after = turn(cacheRead: 30_000, uuid: "b")
        XCTAssertEqual(digest(before, after)?.context?.tokens, 30_000)
    }

    private let boundary = """
        {"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,\
        "isMeta":false,"content":"Conversation compacted",\
        "timestamp":"2026-09-11T04:01:48.322Z","level":"info","compactMetadata":\
        {"trigger":"manual","preTokens":79862,"durationMs":41250,"postTokens":3133,\
        "cumulativeDroppedTokens":76729}}
        """

    /// The boundary's `postTokens` counts the conversation the CLI kept, where
    /// the badge counts what the next request sends — that plus the system
    /// prompt and the tool schemas. A `/compact` writes no assistant turn, so
    /// the boundary is the reading until one lands, marked as the estimate it
    /// is; a turn after it is exact and stands on its own.
    func testTheBoundaryIsAnEstimateUntilTheNextTurnReads() {
        let after = digest(turn(cacheRead: 79_800, uuid: "a"), boundary)?.context
        XCTAssertEqual(after?.tokens, 3_133)
        XCTAssertEqual(after?.isEstimate, true)

        let read = digest(turn(cacheRead: 79_800, uuid: "a"), boundary, turn(cacheRead: 9_000, uuid: "c"))?
            .context
        XCTAssertEqual(read?.tokens, 9_000)
        XCTAssertEqual(read?.isEstimate, false)
    }

    /// A turn that reports nothing is not a session carrying nothing. Reading it
    /// as zero would blank the badge for a turn at a time, every time the CLI
    /// writes a record with usage it hasn't filled in.
    func testATurnThatReadNothingIsSkippedRatherThanBelieved() {
        let empty = turn(uuid: "b")
        XCTAssertEqual(digest(turn(cacheRead: 200_000, uuid: "a"), empty)?.context?.tokens,
                       200_000)
    }

    func testATurnWithNoUsageAtAllIsSkipped() {
        let plain = #"{"type":"assistant","uuid":"b","message":{"content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertEqual(digest(turn(cacheRead: 200_000, uuid: "a"), plain)?.context?.tokens,
                       200_000)
    }

    /// A subagent's context is its own conversation's, and it runs deep in the
    /// parent's turn — reading it would have a row show whatever the last
    /// delegate happened to be carrying.
    func testASubagentsTurnIsNotTheSessionsContext() {
        let sub = """
        {"type":"assistant","uuid":"b","isSidechain":true,"message":{"model":"claude-opus-5",\
        "content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":9000}}}
        """
        XCTAssertEqual(digest(turn(cacheRead: 200_000, uuid: "a"), sub)?.context?.tokens,
                       200_000)
    }

    /// Your own turn carries no usage, so a session read right after you send
    /// still knows what the turn before was carrying.
    func testTheReadingSurvivesAUserTurnLandingLast() {
        let prompt = #"{"type":"user","uuid":"b","message":{"content":"and now?"}}"#
        XCTAssertEqual(digest(turn(cacheRead: 200_000, uuid: "a"), prompt)?.context?.tokens,
                       200_000)
    }

    /// The same rule the title and the message follow: a window that scrolled
    /// past the last turn keeps what it knew rather than blanking it.
    func testALaterReadingWithNoTurnKeepsTheOneItHad() {
        let held = SessionDigest(context: SessionContext(tokens: 200_000))
        XCTAssertEqual(SessionDigest(title: "x").merged(over: held).context?.tokens, 200_000)
    }

    // What counts as expensive

    /// Derived rather than picked: `Scripts/maintainer/token-audit.py --long` calls a
    /// session worth splitting at 150 turns, and a session that has reached that
    /// cut is carrying 150k by the tenth percentile of a thousand-odd
    /// transcripts. Moving it is a decision, not a tidy-up.
    func testTheThresholdIsWhereTheAuditSaysToSplit() {
        XCTAssertEqual(SessionContext.expensive, 150_000)
        XCTAssertFalse(SessionContext(tokens: 149_999).isExpensive)
        XCTAssertTrue(SessionContext(tokens: 150_000).isExpensive)
    }

    /// A fresh session reads about 46k a turn, so the line sits at roughly three
    /// times what starting over would cost — the point of the badge.
    func testAFreshSessionsCarryIsWellUnderTheLine() {
        XCTAssertFalse(SessionContext(tokens: 46_000).isExpensive)
    }

    // What it costs

    /// Cache reads are a tenth of the input rate, which is the arithmetic the
    /// audit prices a re-read at. 150k on Opus at $5/M is 7.5¢ a turn.
    func testTheCarryIsPricedAtTheCacheReadRate() throws {
        let carry = try XCTUnwrap(
            SessionContext(tokens: 150_000, model: "claude-opus-5").carryPerTurn
        )
        XCTAssertEqual(carry, 0.075, accuracy: 0.0001)
    }

    func testEachFamilyIsPricedAsItself() throws {
        func carry(_ model: String) throws -> Double {
            try XCTUnwrap(SessionContext(tokens: 1_000_000, model: model).carryPerTurn)
        }
        XCTAssertEqual(try carry("claude-fable-5"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try carry("claude-opus-5"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try carry("claude-sonnet-5-5"), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try carry("claude-sonnet-5"), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try carry("claude-haiku-4-5"), 0.1, accuracy: 0.0001)
    }

    /// Haiku 5.5 has two rate cards split at a 100k prompt, and the carry is
    /// the prompt: 100k reads at $0.10/M, one token more and all of it at $0.50/M.
    func testHaikuFivePointFivePricesTheWholePromptPastOneHundredThousand() throws {
        func carry(_ tokens: Int) throws -> Double {
            try XCTUnwrap(SessionContext(tokens: tokens, model: "claude-haiku-5-5").carryPerTurn)
        }
        XCTAssertEqual(try carry(100_000), 0.001, accuracy: 0.000001)
        XCTAssertEqual(try carry(100_001), 0.005, accuracy: 0.000001)
        XCTAssertEqual(try carry(1_000_000), 0.05, accuracy: 0.000001)
        XCTAssertEqual(
            try XCTUnwrap(SessionContext(tokens: 1_000_000, model: "claude-haiku-4-5").carryPerTurn),
            0.1, accuracy: 0.0001
        )
    }

    /// Fable 5.1 reads cache at 2.5% of the input rate rather than the usual
    /// tenth, so the same million tokens carries at a quarter of what its
    /// predecessor pays — the one model the flat share would overstate 4x.
    func testFableFivePointOneReadsCacheAtItsOwnShare() throws {
        func carry(_ model: String) throws -> Double {
            try XCTUnwrap(SessionContext(tokens: 1_000_000, model: model).carryPerTurn)
        }
        XCTAssertEqual(try carry("claude-fable-5-1"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try carry("claude-fable-5"), 1.0, accuracy: 0.0001)
    }

    /// A dated id and a width variant price as their family.
    func testADatedIdPricesAsItsFamily() throws {
        let dated = try XCTUnwrap(
            SessionContext(tokens: 1_000_000, model: "claude-opus-4-5-20251101").carryPerTurn
        )
        XCTAssertEqual(dated, 0.5, accuracy: 0.0001)
        let wide = try XCTUnwrap(
            SessionContext(tokens: 1_000_000, model: "claude-opus-5[1m]").carryPerTurn
        )
        XCTAssertEqual(wide, 0.5, accuracy: 0.0001)
    }

    /// Opus 5.5 is $4/M with cache reads at $0.20/M — 5%, where Opus 5 reads at
    /// a tenth of $5. Matched on a bare prefix it priced as Opus 5, 2.5x high.
    func testOpusFivePointFiveIsNotPricedAsOpusFive() throws {
        let carry = try XCTUnwrap(
            SessionContext(tokens: 1_000_000, model: "claude-opus-5-5").carryPerTurn
        )
        XCTAssertEqual(carry, 0.2, accuracy: 0.0001)
    }

    /// The next point release is a model this build hasn't priced, not the
    /// family's first release.
    func testANewPointReleaseIsNotPricedAsItsFamily() {
        XCTAssertNil(SessionContext(tokens: 400_000, model: "claude-opus-5-6").carryPerTurn)
        XCTAssertNil(SessionContext(tokens: 400_000, model: "claude-sonnet-5-1").carryPerTurn)
    }

    /// A model this build has never heard of costs nothing rather than costing
    /// whatever the nearest guess would be. The size still shows; the price
    /// simply goes unsaid.
    func testAnUnknownModelIsNotGuessedAt() {
        XCTAssertNil(SessionContext(tokens: 400_000, model: "claude-something-9").carryPerTurn)
        XCTAssertNil(SessionContext(tokens: 400_000).carryPerTurn)
    }

    // What it says

    func testTheLabelIsTheSizeCompactly() {
        XCTAssertEqual(SessionContext(tokens: 182_400).label, "182.4k ctx")
        XCTAssertEqual(SessionContext(tokens: 5_100, isEstimate: true).label, "~5.1k ctx")
    }

    /// The tooltip has one job past naming the size: saying that the number is
    /// paid again on every turn, and that a fresh session isn't.
    func testTheHelpNamesTheCostAndTheWayOut() {
        let help = SessionContext(tokens: 200_000, model: "claude-opus-5").help
        XCTAssertTrue(help.contains("200k"))
        XCTAssertTrue(help.contains("10¢"))
        XCTAssertTrue(help.contains("the next turn pays it again"))
        XCTAssertTrue(help.contains("fresh session"))
    }

    /// Below the line it is a readout, not a warning — no suggestion to go
    /// anywhere.
    func testACheapSessionIsNotToldToStartOver() {
        let help = SessionContext(tokens: 40_000, model: "claude-opus-5").help
        XCTAssertTrue(help.contains("40k"))
        XCTAssertFalse(help.contains("fresh session"))
    }

    func testAnUnpricedSessionStillSaysTheRereadHappens() {
        let help = SessionContext(tokens: 400_000).help
        XCTAssertTrue(help.contains("every turn reads all of it again"))
        XCTAssertTrue(help.contains("fresh session"))
    }
}
