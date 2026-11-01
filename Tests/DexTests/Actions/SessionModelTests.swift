import XCTest
@testable import DexCore

final class SessionModelTests: XCTestCase {

    func testAliasSendsTheFlag() {
        XCTAssertEqual(SessionModel.alias("fable").flagArguments, ["--model", "fable"])
    }

    func testInheritedSendsNothing() {
        XCTAssertEqual(SessionModel.inherited.flagArguments, [])
    }

    func testStoredRoundTrips() {
        XCTAssertEqual(SessionModel(stored: "fable"), .alias("fable"))
        XCTAssertEqual(SessionModel.alias("fable").stored, "fable")
    }

    func testNothingStoredReadsAsInherited() {
        XCTAssertEqual(SessionModel(stored: nil), .inherited)
        XCTAssertEqual(SessionModel(stored: ""), .inherited)
        XCTAssertEqual(SessionModel(stored: "   "), .inherited)
        XCTAssertNil(SessionModel.inherited.stored)
    }

    func testPickerLeadsWithNoChoice() {
        XCTAssertEqual(SessionModel.offered().first, .inherited)
    }

    /// The menu is a choice between classes. Everything else `--model` takes is
    /// either not a class or not one worth reaching for.
    func testPickerOffersTheThreeClassesAndNothingElse() {
        XCTAssertEqual(SessionModel.offered().map(\.menuLabel),
                       ["Default", "Sonnet", "Opus", "Fable"])
    }

    /// A bare `opus` is the narrow one — offering it hands back context the
    /// default keeps.
    func testEachClassIsOfferedAtItsWidest() {
        XCTAssertEqual(SessionModel.offered().compactMap(\.label),
                       ["sonnet[1m]", "opus[1m]", "fable[1m]"])
    }

    /// A class the CLI stopped listing drops out of the menu rather than being
    /// offered and failing at dispatch, so the probe list has to keep covering
    /// the three or the picker quietly gets shorter.
    func testEveryClassIsStillOnTheProbedList() {
        for family in SessionModel.classes {
            XCTAssertTrue(
                ModelAliases.all.contains(family) || ModelAliases.all.contains("\(family)[1m]"),
                family
            )
        }
    }

    /// The picker used to offer `sonnet` beside `sonnet[1m]`, so a name stored
    /// by that build comes back as a class this one already offers. Kept as its
    /// own row it would read "Sonnet" twice, and the row without the tick would
    /// send the other flag.
    func testANameStoredBeforeWidthsSettlesOntoItsClass() {
        XCTAssertEqual(SessionModel.alias("sonnet").settled, .alias("sonnet[1m]"))
        XCTAssertEqual(SessionModel.alias("opus[1m]").settled, .alias("opus[1m]"))
        XCTAssertEqual(SessionModel.inherited.settled, .inherited)
        XCTAssertEqual(SessionModel.offered(keeping: .alias("sonnet")),
                       SessionModel.offered())
    }

    /// A name that is not one of the classes has nothing to settle onto and is
    /// still worth keeping — it is what the next session would have gone out on.
    func testANameFromOutsideTheClassesIsLeftAlone() {
        let stray = SessionModel.alias("opusplan")
        XCTAssertEqual(stray.settled, stray)
        XCTAssertTrue(SessionModel.offered(keeping: stray).contains(stray))
    }

    func testNoTwoRowsReadTheSame() {
        for stored in [SessionModel.inherited, .alias("sonnet"), .alias("opusplan"),
                       .alias("claude-opus-4-1-20250805")] {
            let labels = SessionModel.offered(keeping: stored).map(\.menuLabel)
            XCTAssertEqual(labels.count, Set(labels).count, "\(stored)")
        }
    }

    func testTheWidthIsNotPartOfTheName() {
        XCTAssertEqual(SessionModel.alias("opus[1m]").menuLabel, "Opus")
        XCTAssertEqual(SessionModel.alias("opus").menuLabel, "Opus")
        XCTAssertEqual(SessionModel.inherited.menuLabel, "Default")
    }

    /// A stored full id has no class name to shorten to, so it reads as itself.
    func testAFullIdKeepsItsOwnName() {
        XCTAssertEqual(SessionModel.alias("claude-opus-4-1-20250805").menuLabel, "Opus 4.1")
    }

    /// The width is a choice about the flag, not about the label — dropping it
    /// on the way to the command line would undo the point of picking it.
    func testTheWidthStillReachesTheCommandLine() {
        XCTAssertEqual(SessionModel.alias("opus[1m]").flagArguments, ["--model", "opus[1m]"])
    }

    /// The CLI takes a full model id too, so a stored name the probe no longer
    /// lists is still worth dispatching — dropping it would silently move the
    /// next session onto a different model.
    func testStoredNameSurvivesFallingOffTheList() {
        let stray = SessionModel.alias("claude-opus-4-8")
        XCTAssertFalse(ModelAliases.all.contains("claude-opus-4-8"))
        XCTAssertTrue(SessionModel.offered(keeping: stray).contains(stray))
    }

    func testPickerListsNoNameTwice() {
        let offered = SessionModel.offered(keeping: .alias("fable"))
        XCTAssertEqual(offered.count, Set(offered).count)
    }

    /// `default` means what sending no flag already means, and the probe drops
    /// it so the picker never offers the same thing twice.
    func testDefaultIsNotAnAlias() {
        XCTAssertFalse(ModelAliases.all.contains("default"))
    }

}

final class ModelNameTests: XCTestCase {

    func testFamilyAndVersionReadAsAName() {
        XCTAssertEqual(ModelName.display(for: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.display(for: "claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.display(for: "claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(ModelName.display(for: "claude-haiku-4-5"), "Haiku 4.5")
    }

    func testTwoWordFamilies() {
        XCTAssertEqual(ModelName.display(for: "claude-mythos-preview"), "Mythos Preview")
    }

    /// init resolves a width variant as `claude-opus-5[1m]` (**CLI v2.1.238**,
    /// pinned by the host-wire fixture). The marker names a context window,
    /// not a model — left in, it reads "Opus 5[1M]".
    func testAWidthVariantReadsAsItsModel() {
        XCTAssertEqual(ModelName.display(for: "claude-opus-5[1m]"), "Opus 5")
        XCTAssertEqual(ModelName.display(for: "claude-sonnet-5[1m]"), "Sonnet 5")
    }

    /// Asking for an alias is enough to get a dated id back: `--model haiku`
    /// answers as `claude-haiku-4-5-20251001` (**CLI v2.1.222**). Left in, the
    /// date reads as part of the version.
    func testTheReleaseDateIsNotPartOfTheVersion() {
        XCTAssertEqual(ModelName.display(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.display(for: "claude-opus-4-1-20250805"), "Opus 4.1")
        XCTAssertEqual(ModelName.display(for: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    /// Only a trailing date, and only something date-shaped — a version part
    /// this rule ate would be worse than a date it kept.
    func testAVersionIsNeverMistakenForADate() {
        XCTAssertEqual(ModelName.display(for: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.display(for: "claude-opus-12345"), "Opus 12345")
        XCTAssertEqual(ModelName.display(for: "claude-opus-123456789"), "Opus 123456789")
    }

    /// The rule is a rule, not a table — a model released after this build still
    /// reads as a name.
    func testAModelThisBuildHasNeverHeardOf() {
        XCTAssertEqual(ModelName.display(for: "claude-parable-9"), "Parable 9")
    }

    /// Naming that leads with the version is a shape this rule would read
    /// backwards, so it doesn't try.
    func testVersionFirstNamingIsLeftAlone() {
        XCTAssertEqual(ModelName.display(for: "claude-3-5-sonnet-20241022"),
                       "claude-3-5-sonnet-20241022")
    }

    func testAnIdFromSomewhereElseIsLeftAlone() {
        XCTAssertEqual(ModelName.display(for: "anthropic.claude-opus-5"),
                       "anthropic.claude-opus-5")
        XCTAssertEqual(ModelName.display(for: ""), "")
    }
}
