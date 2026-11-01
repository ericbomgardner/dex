import XCTest
@testable import DexCore

final class ModelChipTests: XCTestCase {

    /// The transcript is the model that actually answered, so it outranks
    /// every launch-time reading.
    func testAnsweredOutranksEverything() {
        let chip = ModelChip.reading(
            answered: "claude-opus-5",
            resolved: "claude-fable-5",
            launched: .alias("fable[1m]"),
            names: [.alias("fable[1m]"): "Fable 5"]
        )
        XCTAssertEqual(chip?.label, "Opus 5")
        XCTAssertEqual(chip?.help, "This session is answering as claude-opus-5")
    }

    /// Before a first reply the init-resolved id already names the model —
    /// Default launches included, which the alias never could.
    func testResolvedIdSpeaksBeforeTheFirstReply() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: "claude-fable-5",
            launched: .inherited
        )
        XCTAssertEqual(chip?.label, "Fable 5")
        XCTAssertEqual(chip?.help, "This session is starting as claude-fable-5")
    }

    /// Before init, the launch alias reads through the picker's CLI-given
    /// name, so the chip says "Fable 5" the way its first reply will.
    func testLaunchAliasWearsThePickerName() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .alias("fable[1m]"),
            names: [.alias("fable[1m]"): "Fable 5"]
        )
        XCTAssertEqual(chip?.label, "Fable 5")
        XCTAssertEqual(chip?.help, "This session was launched as fable[1m]")
    }

    /// With nothing cached the alias still names its class — a chip reading
    /// "Fable" beats no chip for the second before init corrects it.
    func testLaunchAliasFallsBackToItsClass() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .alias("fable[1m]")
        )
        XCTAssertEqual(chip?.label, "Fable")
    }

    /// A resume relaunches under the full id the archive kept — width marker
    /// and all, since init is what the archive heard — which reads by rule
    /// rather than through the picker's table.
    func testAFullIdLaunchReadsByRule() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .alias("claude-opus-5")
        )
        XCTAssertEqual(chip?.label, "Opus 5")

        let wide = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .alias("claude-opus-5[1m]")
        )
        XCTAssertEqual(wide?.label, "Opus 5")
    }

    /// The init-resolved id carries the width variant, which names a context
    /// window rather than a model.
    func testAResolvedWidthVariantReadsAsItsModel() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: "claude-opus-5[1m]",
            launched: nil
        )
        XCTAssertEqual(chip?.label, "Opus 5")
    }

    /// A folder whose settings pin a model names a Default launch at once,
    /// routed through the picker's table so "sonnet" reads "Sonnet 5" the way
    /// init will, not "Sonnet" on the way there.
    func testAFolderPinNamesADefaultLaunch() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .inherited,
            defaultModel: .named("sonnet"),
            names: [.alias("sonnet[1m]"): "Sonnet 5"]
        )
        XCTAssertEqual(chip?.label, "Sonnet 5")
        XCTAssertEqual(chip?.help, "This session was launched on Default — this folder's settings say sonnet")

        let bare = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .inherited,
            defaultModel: .named("sonnet")
        )
        XCTAssertEqual(bare?.label, "Sonnet")
    }

    /// The folder's own pin outranks the picker's cached Default name — the
    /// pin is that directory's answer, the cache is wherever the app ran.
    func testAFolderPinOutranksTheCachedDefaultName() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .inherited,
            defaultModel: .named("sonnet"),
            names: [.alias("sonnet[1m]"): "Sonnet 5", .inherited: "Opus 5"]
        )
        XCTAssertEqual(chip?.label, "Sonnet 5")
    }

    /// The resolver answering "no file names one" means the CLI's built-in
    /// default, which no directory moves — so the picker's Default-row name
    /// is safe exactly here.
    func testAnUnpinnedDefaultWearsTheCachedName() {
        let chip = ModelChip.reading(
            answered: nil,
            resolved: nil,
            launched: .inherited,
            defaultModel: .unnamed,
            names: [.inherited: "Opus 5"]
        )
        XCTAssertEqual(chip?.label, "Opus 5")
        XCTAssertEqual(chip?.help, "This session was launched on Default — currently Opus 5")
    }

    /// An unanswered resolver — an older host, an SDK without one — proves
    /// nothing about this folder, so the cached name is not asserted even
    /// when it is sitting right there. This is the case where the folder may
    /// pin a model the app cannot see.
    func testAnUnansweredDefaultIgnoresTheCachedName() {
        XCTAssertNil(
            ModelChip.reading(
                answered: nil,
                resolved: nil,
                launched: .inherited,
                defaultModel: .unanswered,
                names: [.inherited: "Opus 5"]
            )
        )
    }

    /// A blank pin names nothing: absent, not a chip reading "Default".
    func testABlankPinStaysAbsent() {
        XCTAssertNil(
            ModelChip.reading(
                answered: nil,
                resolved: nil,
                launched: .inherited,
                defaultModel: .named(""),
                names: [.inherited: "Opus 5"]
            )
        )
    }

    /// Nothing on disk and nothing over the wire is the one absence left.
    func testADefaultLaunchNothingHasNamedStaysAbsent() {
        XCTAssertNil(ModelChip.reading(answered: nil, resolved: nil, launched: .inherited))
        XCTAssertNil(ModelChip.reading(answered: nil, resolved: nil, launched: nil))
        XCTAssertNil(
            ModelChip.reading(answered: nil, resolved: nil, launched: .inherited, defaultModel: .unnamed)
        )
    }
}
