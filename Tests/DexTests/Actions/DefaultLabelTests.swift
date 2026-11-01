import XCTest

@testable import DexCore

/// The two halves of one row: what it says when you can only see the label, and
/// what it says when the menu is down and there is room for the rest.
final class DefaultLabelTests: XCTestCase {

    /// The whole point of the change. A label reading "Default" spends the
    /// widest line in the composer saying nothing the grey doesn't already say,
    /// where the level is what you are about to pay for a turn.
    func testTheClosedLabelIsTheValueAndNothingElse() {
        XCTAssertEqual(DefaultLabel.text(for: "Xhigh", open: false), "Xhigh")
        XCTAssertFalse(DefaultLabel.text(for: "Xhigh", open: false).contains("Default"))
    }

    /// Opened, both. Without the marker the Default row and a row for the same
    /// level read identically, and they do different things — one sends nothing
    /// and follows the settings files, the other pins the level.
    func testTheOpenRowSaysWhichOneIsTheDefault() {
        XCTAssertEqual(DefaultLabel.text(for: "Xhigh", open: true), "Xhigh (Default)")
    }

    /// The two rows land on the same level and are still distinguishable, which
    /// is the case the marker exists for.
    func testTheDefaultRowIsTellableFromTheRowItLandsOn() {
        XCTAssertNotEqual(
            DefaultLabel.text(for: "Xhigh", open: true),
            EffortLevel.named("xhigh").menuLabel
        )
    }

    /// Nothing invents a value. Where the cascade sets the key in no file, or
    /// the CLI hasn't named a model yet, the callers never reach this and fall
    /// back to the bare word — so it is the enum's own label that has to hold
    /// the fallback, not this.
    func testTheBareWordIsStillWhatTheTypesSayWithNothingResolved() {
        XCTAssertEqual(EffortLevel.inherited.menuLabel, "Default")
        XCTAssertEqual(SessionModel.inherited.menuLabel, "Default")
    }

    /// The complaint the collapse answers: the menu carried the same level
    /// twice, one row sending nothing and one sending what nothing resolves to.
    /// Neither list has a row for it any more.
    func testNeitherMenuOffersDefaultAsARowOfItsOwn() {
        XCTAssertFalse(EffortLevel.shown().contains(.inherited))
        XCTAssertFalse(SessionModel.picking().contains(.inherited))
    }

    /// `offered` keeps it, and has to: Default's own name is what says which
    /// class it lands on, so dropping it there would take the marker with it.
    func testTheNamingListStillCarriesDefault() {
        XCTAssertTrue(SessionModel.offered().contains(.inherited))
    }

    func testTheMarkerLandsOnTheLevelTheFilesResolveTo() {
        let rows = EffortLevel.shown()
        XCTAssertEqual(
            EffortLevel.matchingDefault(in: rows, resolved: "high"), .named("high")
        )
        XCTAssertNil(EffortLevel.matchingDefault(in: rows, resolved: nil))
    }

    /// A settings file can name anything. Marking the nearest row would be the
    /// app claiming a level it is not going to run at.
    func testALevelNoRowCarriesMarksNothing() {
        XCTAssertNil(EffortLevel.matchingDefault(in: EffortLevel.shown(), resolved: "ludicrous"))
    }

    /// Two rows the CLI names alike are one choice — the only thing that says
    /// so, since the aliases differ.
    func testTheModelMarkerIsFoundByTheNameTheCLIGivesEachRow() {
        let rows = SessionModel.picking()
        guard let opus = rows.first(where: { $0.label?.hasPrefix("opus") == true }) else {
            return XCTFail("expected an opus row")
        }
        let names: [SessionModel: String] = [
            .inherited: "Opus 5", opus: "Opus 5", .alias("fable[1m]"): "Fable 5",
        ]
        XCTAssertEqual(SessionModel.matchingDefault(in: rows, names: names), opus)
    }

    /// Before the CLI has answered there is no name to match on, so nothing is
    /// marked rather than the first row being guessed at.
    func testNothingIsMarkedBeforeTheNamesLand() {
        XCTAssertNil(SessionModel.matchingDefault(in: SessionModel.picking(), names: [:]))
    }

    /// The effort never sends `default`: a pick sends itself, an unmoved picker
    /// sends what the files resolved to, and only a Default nothing named still
    /// sends nothing. Lossless because the cascade answers with the level, not
    /// with a name for it.
    func testTheEffortNeverSendsDefaultItself() {
        XCTAssertEqual(EffortLevel.inherited.launching(default: .named("xhigh")), "xhigh")
        XCTAssertEqual(EffortLevel.named("low").launching(default: .named("xhigh")), "low")
        XCTAssertNil(EffortLevel.inherited.launching(default: nil))
    }

    /// Why the model's Default is sent from the cascade's alias and never from
    /// the CLI's name for it: `ModelReadout` strips the context window, so the
    /// picker's `opus[1m]` and a settings file's bare `opus` are one string by
    /// the time this app compares them. Resolving a pin through that name would
    /// launch a deliberately narrow model at 1M.
    func testTheTwoOpusWidthsAreOneNameOnceTheWindowIsStripped() {
        XCTAssertEqual(ModelReadout.name(in: "Current model: Opus 5 (1M context)"), "Opus 5")
        XCTAssertEqual(ModelReadout.name(in: "Current model: Opus 5 (default)"), "Opus 5")
        XCTAssertNotEqual(
            SessionModel.alias("opus").hostModelID, SessionModel.alias("opus[1m]").hostModelID
        )
    }

    /// The alias keeps what the name loses, which is the whole reason the flag
    /// is sent from one and not the other.
    func testAPinnedAliasStillSaysWhichWidthWasAskedFor() {
        XCTAssertEqual(HostDefaults(cwd: "/p", outputStyle: nil, effort: nil).model, .unanswered)
        let narrow = HostDefaults(
            cwd: "/p", outputStyle: nil, effort: nil, model: .named("opus")
        )
        guard case .named(let alias) = narrow.model else { return XCTFail("expected a pin") }
        XCTAssertEqual(alias, "opus")
        XCTAssertNotEqual(alias, "opus[1m]")
    }

    /// Three states, and only one of them is a thing to send. A host that never
    /// answered and a cascade that names nothing both mean no flag — the CLI's
    /// own built-in default is not a thing this app can spell.
    func testOnlyANamedPinIsSomethingToSend() {
        func pin(_ model: HostDefaults.Model) -> String? {
            guard case .named(let alias) = model else { return nil }
            return alias
        }
        XCTAssertNil(pin(.unanswered))
        XCTAssertNil(pin(.unnamed))
        XCTAssertEqual(pin(.named("fable[1m]")), "fable[1m]")
    }
}
