import XCTest
@testable import DexCore

/// The lines here are what **CLI v2.1.241** actually printed, not invented
/// shapes — `Scripts/model-alias-probe.py` prints the same reply.
final class ModelReadoutTests: XCTestCase {

    func testReadsTheNameADefaultResolvesTo() {
        XCTAssertEqual(
            ModelReadout.name(in: """
            Current model: Opus 5 (1M context) (default) (effort: xhigh)
            Usage: /model <name>. Available: sonnet, opus, default, or a full model ID.
            """),
            "Opus 5"
        )
    }

    /// Asked under `--model sonnet`, which is how a class row gets its version.
    func testReadsTheNameAClassResolvesTo() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: Sonnet 5 (effort: xhigh)"),
                       "Sonnet 5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: Fable 5 (effort: xhigh)"),
                       "Fable 5")
    }

    /// The picker chooses between classes, so a note every row could carry says
    /// nothing — and beside one row only it reads as a difference between them.
    func testTheContextWindowComesOff() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: Opus 5 (1M context)"), "Opus 5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: Opus 5 (1M context) (default)"),
                       "Opus 5")
    }

    /// Markers come off by what they say, not by being last — the name can hold
    /// parentheses, and one that isn't a marker ends the stripping.
    func testAnUnknownMarkerIsKeptRatherThanEaten() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: Opus 5 (some new thing)"),
                       "Opus 5 (some new thing)")
        XCTAssertEqual(
            ModelReadout.name(in: "Current model: Opus 5 (some new thing) (default)"),
            "Opus 5 (some new thing)"
        )
    }

    /// Since v2.1.241 the CLI backticks the name, and folds `default` inside
    /// the quoting while leaving `effort:` outside it. Read at face value the
    /// picker drew ``Sonnet 5`` with the marks showing.
    func testTheBackticksComeOff() {
        XCTAssertEqual(
            ModelReadout.name(in: """
            Current model: `Opus 5 (1M context) (default)` (effort: xhigh)
            Usage: /model <name>. Available: sonnet, opus, default, or a full model ID.
            """),
            "Opus 5"
        )
        XCTAssertEqual(ModelReadout.name(in: "Current model: `Sonnet 5` (effort: medium)"),
                       "Sonnet 5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: `Fable 5`"), "Fable 5")
    }

    /// CLI v2.1.312, after 2.1.311 dropped the width label where it changes
    /// nothing: `--model opus[1m]` and `--model fable[1m]` print these too.
    func testReadsRowsThatCarryNoWidth() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: `Opus 5.5 (default)`"), "Opus 5.5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: `Fable 5.1`"), "Fable 5.1")
    }

    /// A lone backtick is not a pair, and a name that keeps one is better than
    /// one silently missing a character.
    func testAnUnpairedBacktickIsLeftAlone() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: `Opus 5"), "`Opus 5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: `"), "`")
    }

    func testPlanModeOverrideComesOff() {
        XCTAssertEqual(
            ModelReadout.name(in: "Current model: Sonnet 5 (session override from plan mode)"),
            "Sonnet 5"
        )
    }

    /// Nothing rather than a guess — the picker would rather say less than
    /// point at the wrong model.
    func testAnAnswerItCannotReadIsNoAnswer() {
        XCTAssertNil(ModelReadout.name(in: ""))
        XCTAssertNil(ModelReadout.name(in: "Model 'zzz' not found"))
        XCTAssertNil(ModelReadout.name(in: "Current model: "))
        XCTAssertNil(ModelReadout.name(in: "Current model: (default)"))
        XCTAssertNil(ModelReadout.name(in: "Current model: (1M context)"))
        XCTAssertNil(ModelReadout.name(in: "Current model: `(default)`"))
        XCTAssertNil(ModelReadout.name(in: "Current model: `` (effort: xhigh)"))
    }

    /// The question is asked of a choice, so the flag the choice would dispatch
    /// with is the one it has to be asked under.
    func testAClassIsAskedAboutUnderItsOwnFlag() {
        XCTAssertEqual(SessionModel.alias("sonnet[1m]").flagArguments,
                       ["--model", "sonnet[1m]"])
        XCTAssertEqual(SessionModel.inherited.flagArguments, [])
    }

    private let rows: [SessionModel] = [.inherited, .alias("sonnet[1m]"), .alias("opus[1m]")]

    func testEveryRowNamedOrNoneIs() {
        let all: [SessionModel: String] = [
            .inherited: "Opus 5", .alias("sonnet[1m]"): "Sonnet 5", .alias("opus[1m]"): "Opus 5",
        ]
        XCTAssertEqual(SessionModel.named(all, covering: rows), all)

        var short = all
        short[.alias("sonnet[1m]")] = nil
        XCTAssertEqual(SessionModel.named(short, covering: rows), [:])
        XCTAssertEqual(SessionModel.named([:], covering: rows), [:])
    }

    /// Nothing to cover is covered, so a picker with no rows says nothing
    /// rather than waiting on an answer that is never coming.
    func testNoRowsNeedNoNames() {
        XCTAssertEqual(SessionModel.named([:], covering: []), [:])
    }
}
