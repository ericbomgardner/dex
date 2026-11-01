import XCTest

@testable import DexCore

/// The asymmetry between the two lists is the whole of this type, and it is
/// measured rather than reasoned: `Sidecar/test/output-style-probe.ts` asks for
/// `max` at launch and the session comes back thinking at `xhigh`. Where it
/// lands is measured separately from where the launch list ends — the probe
/// asks for `xhigh` at launch too and gets `xhigh`, so the two are not one
/// reading: on CLI v2.1.278 they disagreed, and on v2.1.280 they agree again.
final class EffortLevelTests: XCTestCase {

    func testTheComposerStopsShortOfMaxAndTheDialDoesNot() {
        let launch = EffortLevel.offered().compactMap(\.label)
        let dial = EffortLevel.dialled().compactMap(\.label)

        XCTAssertFalse(launch.contains("max"), "max at launch silently becomes xhigh")
        XCTAssertTrue(dial.contains("max"))
        XCTAssertEqual(dial.dropLast(), ArraySlice(launch))
        // The launch list ends where the SDK's own settings type does.
        XCTAssertEqual(launch.last, "xhigh")
    }

    /// Only the composer can leave it to the settings files, because only the
    /// composer can send nothing. A Default row on the dial had no name to send
    /// and so took the click and did nothing at all.
    func testOnlyTheComposerOffersLeavingItToTheSettingsFiles() {
        XCTAssertEqual(EffortLevel.offered().first, .inherited)
        XCTAssertFalse(EffortLevel.dialled().contains(.inherited))
        XCTAssertFalse(EffortLevel.dialled(keeping: .inherited).contains(.inherited))
        XCTAssertTrue(EffortLevel.dialled().allSatisfy { $0.hostEffortID != nil })
    }

    /// Kept the way the composer keeps one, so a session moved to a level this
    /// host has never heard of still shows where it is sitting.
    func testTheDialKeepsALevelItIsAlreadyOn() {
        XCTAssertEqual(
            EffortLevel.dialled(keeping: .named("ludicrous"), accepting: ["low"])
                .compactMap(\.label),
            ["low", "ludicrous"]
        )
    }

    /// The host outlives the app, so one started before this existed refuses
    /// every level by name. Empty is nothing having said, not nothing on offer.
    func testAHostThatNamesNoLevelsIsNotAHostThatRefusesThemAll() {
        XCTAssertEqual(EffortLevel.offered(accepting: []).count, EffortLevel.offered().count)
        XCTAssertEqual(
            EffortLevel.offered(accepting: ["low", "high"]).compactMap(\.label),
            ["low", "high"]
        )
    }

    /// Dropping a stored level moves the next session somewhere nobody asked
    /// for, so it is kept even when the host has never heard of it.
    func testALevelTheHostDoesNotTakeIsStillShownWhenItIsTheOneChosen() {
        let offered = EffortLevel.offered(keeping: .named("ludicrous"), accepting: ["low"])
        XCTAssertEqual(offered.compactMap(\.label), ["low", "ludicrous"])
    }

    func testABlankStoredLevelReadsAsNoChoice() {
        XCTAssertEqual(EffortLevel(stored: nil), .inherited)
        XCTAssertEqual(EffortLevel(stored: "   "), .inherited)
        XCTAssertEqual(EffortLevel(stored: "xhigh"), .named("xhigh"))
        XCTAssertEqual(EffortLevel(stored: "xhigh").stored, "xhigh")
        XCTAssertNil(EffortLevel.inherited.stored)
    }

    /// Nothing is sent for `.inherited`, which is what leaves `effortLevel` in
    /// the settings files in charge.
    func testInheritedSendsNothing() {
        XCTAssertNil(EffortLevel.inherited.hostEffortID)
        XCTAssertEqual(EffortLevel.named("max").hostEffortID, "max")
    }

    func testTheMenuNamesTheLevelWithoutRewritingIt() {
        XCTAssertEqual(EffortLevel.inherited.menuLabel, "Default")
        XCTAssertEqual(EffortLevel.named("xhigh").menuLabel, "Xhigh")
    }

    /// The composer draws one more row than it will send. Both halves matter:
    /// off the list entirely, `max` read as a level the app hasn't got, and
    /// live on it the pick would come back `high` without saying so.
    func testTheComposerDrawsMaxAndStillWillNotSendIt() {
        let shown = EffortLevel.shown().compactMap(\.label)
        let offered = EffortLevel.offered().compactMap(\.label)

        XCTAssertTrue(shown.contains("max"))
        XCTAssertFalse(offered.contains("max"))
        XCTAssertEqual(shown.filter { $0 != "max" }, offered)
        XCTAssertFalse(EffortLevel.named("max").isLaunchable)
        XCTAssertTrue(shown.dropLast().allSatisfy { EffortLevel.named($0).isLaunchable })
    }

    /// Leaving it to the settings files is startable — it is the one row that
    /// sends nothing at all, and reading `hostEffortID == nil` as unsendable
    /// would grey the Default row.
    func testDefaultIsLaunchableEvenThoughItSendsNothing() {
        XCTAssertTrue(EffortLevel.inherited.isLaunchable)
        XCTAssertNil(EffortLevel.inherited.hostEffortID)
    }

    /// A host that has never heard of `max` gets no row explaining it: the row
    /// is there to say why the level is out of reach here, and on that host it
    /// is out of reach for a different reason nothing on this row would name.
    func testAHostWithoutMaxIsNotToldAboutIt() {
        let shown = EffortLevel.shown(accepting: ["low", "high"]).compactMap(\.label)
        XCTAssertEqual(shown, ["low", "high"])
    }

    /// It is added once, not once per row: `offered` already keeps a stored
    /// level, so a session sitting on `max` would otherwise draw it twice.
    func testMaxIsNotDrawnTwiceWhenItIsAlreadyTheStoredLevel() {
        let shown = EffortLevel.shown(keeping: .named("max")).compactMap(\.label)
        XCTAssertEqual(shown.filter { $0 == "max" }.count, 1)
    }

    /// A resume is a launch, and `max` cannot be launched at: asked for it the
    /// CLI runs `xhigh` and says nothing about the swap, so replaying it would
    /// leave a resumed session recorded at a level it is not thinking at.
    ///
    /// The probe measures this apart from the top of the launch list: on
    /// v2.1.278 `max` came back `high` while `xhigh` came back `xhigh`, and on
    /// v2.1.280 both come back `xhigh`. Only the first reading decides this.
    func testAResumedMaxSessionAsksForTheLevelItWillActuallyRunAt() {
        XCTAssertEqual(EffortLevel.named("max").launchable, .named("xhigh"))
        XCTAssertEqual(EffortLevel.named("xhigh").launchable, .named("xhigh"))
        XCTAssertEqual(EffortLevel.named("low").launchable, .named("low"))
        XCTAssertEqual(EffortLevel.inherited.launchable, .inherited)
    }
}
