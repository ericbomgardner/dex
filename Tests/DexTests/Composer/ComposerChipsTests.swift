import XCTest
@testable import DexCore

final class ComposerChipsTests: XCTestCase {

    private let probes = SessionMention(title: "Probe rot", sessionID: "uuid-probes",
                                        rowID: "probes", folder: "dex")

    private func draft(_ pieces: ComposerChips.Piece...) -> String {
        ComposerChips.draft(from: pieces)
    }

    // What is sent

    func testAChipIsTypedOutInTheSentenceAndCarriesItsLine() {
        let text = draft(.text("continue "), .chip(.session(probes)), .text(" please"))
        let prompt = ComposerAttachments.prompt(draft: text, attachments: [],
                                                mentions: ComposerChips.named(in: text, known: []))

        XCTAssertEqual(prompt, """
        continue @Probe rot please

        @Probe rot refers to session `uuid-probes`
        """)
    }


    func testAChipAloneIsAMessage() {
        let text = draft(.chip(.session(probes)))
        XCTAssertEqual(ComposerAttachments.prompt(draft: text, attachments: [],
                                                  mentions: ComposerChips.named(in: text, known: [])),
                       "@Probe rot\n\n@Probe rot refers to session `uuid-probes`")
    }

    func testAChipIsNamedOnceHoweverOftenItAppears() {
        let text = draft(.chip(.session(probes)), .text(" vs "), .chip(.session(probes)))
        XCTAssertEqual(ComposerChips.named(in: text, known: []), [.session(probes)])
    }


    func testAChipIsNotReadAgainAsATypedTitle() {
        let other = SessionMention(title: "Probe rot", sessionID: "uuid-other", rowID: "other", folder: "x")
        let text = draft(.chip(.session(probes)))
        XCTAssertEqual(ComposerChips.named(in: text, known: [.session(other)]), [.session(probes)])
    }

    // What is kept


    func testChipsSurviveTheStoredDrafts() throws {
        let text = draft(.text("see "), .chip(.session(probes)), .text(" "))
        var drafts = ComposerDrafts()
        drafts["s"] = text

        let stored = try JSONEncoder().encode(drafts)
        let read = try JSONDecoder().decode(ComposerDrafts.self, from: stored)

        XCTAssertEqual(read["s"], text)
        XCTAssertEqual(ComposerChips.chips(in: read["s"]), [.session(probes)])
    }

    func testTheSameChipWritesTheSameToken() {
        XCTAssertEqual(ComposerChips.token(for: .session(probes)), ComposerChips.token(for: .session(probes)))
    }

    func testADraftFromBeforeChipsIsJustText() {
        XCTAssertEqual(ComposerChips.pieces(of: "continue @Probe rot"), [.text("continue @Probe rot")])
        XCTAssertEqual(ComposerChips.sentence("continue @Probe rot"), "continue @Probe rot")
    }

    func testATokenThatNoLongerReadsIsDropped() {
        XCTAssertEqual(ComposerChips.pieces(of: "a\u{E000}bm9wZQ\u{E001}b"), [.text("ab")])
        XCTAssertEqual(ComposerChips.sentence("a\u{E000}unclosed"), "a")
    }

    // What the menus read

    func testTheFieldShowsAChipAsOneCharacter() {
        let text = draft(.text("a "), .chip(.session(probes)), .text(" b"))
        XCTAssertEqual(ComposerChips.visible(text), "a \u{FFFC} b")
    }


    // Taking a menu row

    func testTakingARowPutsAChipWhereTheNameWasBeingTyped() {
        let taken = ComposerChips.accepting(.session(probes), in: "pick up @pro")
        XCTAssertEqual(ComposerChips.pieces(of: taken),
                       [.text("pick up "), .chip(.session(probes)), .text(" ")])
    }


    func testTakingARowMidSentenceKeepsTheRest() {
        let taken = ComposerChips.accepting(.session(probes), in: "see @pro for why", caret: "see @pro")
        XCTAssertEqual(ComposerChips.pieces(of: taken),
                       [.text("see "), .chip(.session(probes)), .text(" for why")])
    }

    func testTakingARowInsideBracketsAddsNoSpaceBeforeTheClose() {
        let taken = ComposerChips.accepting(.session(probes), in: "see (@pro) first", caret: "see (@pro")
        XCTAssertEqual(ComposerChips.sentence(taken), "see (@Probe rot) first")
    }


    func testNothingIsCompletedWithTheCaretInsideAWord() {
        XCTAssertEqual(ComposerChips.completing("cc @dx please", at: "cc @d"), "")
        XCTAssertEqual(ComposerChips.completing("cc @dx please", at: "cc @dx"), "cc @dx")
    }

    func testACaretFromBeforeAnEditReadsAsTheEnd() {
        XCTAssertEqual(ComposerChips.split("abc", at: "xy").head, "abc")
        XCTAssertEqual(ComposerChips.split("abc", at: nil).tail, "")
        XCTAssertEqual(ComposerChips.split("abc", at: "a").tail, "bc")
    }

    // Where a chip comes from

}

