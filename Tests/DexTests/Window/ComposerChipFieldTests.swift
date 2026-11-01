import DexCore
import AppKit
import Observation
import SwiftUI
import XCTest

@testable import DexUI

/// The real field, hosted offscreen and bound to a draft the way the composers
/// bind it, so what is read back is what the composer would store and send.
@MainActor
final class ComposerChipFieldTests: XCTestCase {

    /// Kept the way `SessionPane` keeps a draft: whitespace alone is no draft.
    @Observable
    final class Draft {
        var text: String
        var identity = "A"
        var caret: String?
        init(_ text: String) { self.text = text }
    }

    private struct Host: View {
        let draft: Draft
        var body: some View {
            ComposerField(
                text: Binding(get: { draft.text },
                              set: { draft.text = ComposerDraft.restored(ComposerDraft.persistable($0)) }),
                placeholder: "",
                onSend: {},
                onCancel: {},
                onHeightChange: { _ in },
                scrollsPast: 400,
                draftIdentity: draft.identity,
                claimsFocus: false,
                onCaretChange: { draft.caret = $0 }
            )
            .frame(width: 480, height: 120)
        }
    }

    private let probes = SessionMention(title: "Probe rot", sessionID: "uuid-probes",
                                        rowID: "probes", folder: "dex")

    private var window: NSWindow?

    private func field(_ text: String) throws -> (Draft, ComposerTextView) {
        let draft = Draft(text)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(draft: draft))
        window.contentView?.layoutSubtreeIfNeeded()
        self.window = window
        settle()
        let editor = try XCTUnwrap(find(in: window.contentView))
        return (draft, editor)
    }

    private func find(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let editor = view as? ComposerTextView { return editor }
        return view.subviews.lazy.compactMap { self.find(in: $0) }.first
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func chips(in editor: ComposerTextView) -> Int {
        var count = 0
        editor.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
            if value is MentionChipAttachment { count += 1 }
        }
        return count
    }

    private func pieces(_ pieces: ComposerChips.Piece...) -> String {
        ComposerChips.draft(from: pieces)
    }


    func testTypingAfterAChipIsPlainText() throws {
        let (draft, editor) = try field(pieces(.chip(.session(probes))))
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText("!", replacementRange: editor.selectedRange())

        XCTAssertEqual(draft.text, pieces(.chip(.session(probes)), .text("!")))
        XCTAssertEqual(chips(in: editor), 1)
    }

    func testAChipDeletesAsOne() throws {
        let (draft, editor) = try field(pieces(.text("a "), .chip(.session(probes))))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.deleteBackward(nil)

        XCTAssertEqual(draft.text, "a ")
    }

    func testTakingARowShowsAChipAndUndoGivesBackWhatWasTyped() throws {
        let (draft, editor) = try field("pick up @pro")
        draft.text = ComposerChips.accepting(.session(probes), in: draft.text)
        settle()

        XCTAssertEqual(editor.string, "pick up \u{FFFC} ")
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)

        editor.undoManager?.undo()
        settle()
        XCTAssertEqual(draft.text, "pick up @pro")
    }

    func testTakingARowMidSentenceKeepsWhatFollows() throws {
        let (draft, editor) = try field("see for details")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText(" (@pro", replacementRange: editor.selectedRange())
        settle()
        XCTAssertEqual(draft.caret, "see (@pro")

        draft.text = ComposerChips.accepting(.session(probes), in: draft.text, caret: draft.caret)
        settle()

        XCTAssertEqual(editor.string, "see (\u{FFFC} for details")
        XCTAssertEqual(editor.selectedRange().location, 6)
        XCTAssertEqual(draft.caret, pieces(.text("see ("), .chip(.session(probes))))
    }

    func testMovingTheCaretIsReported() throws {
        let (draft, editor) = try field("one two")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(draft.caret, "one")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertEqual(draft.caret, "one")
    }

    func testAnotherDraftPutsTheCaretAtItsEnd() throws {
        let (draft, editor) = try field("/simplify")
        draft.identity = "B"
        draft.text = "/verify"
        settle()
        XCTAssertEqual(editor.selectedRange().location, 7)
        XCTAssertEqual(draft.caret, "/verify")
    }

    /// Everything but a newline taken out leaves a draft the pane keeps as
    /// none, which comes back into the field as a change from outside. The
    /// text taken out must still be one undo away.
    func testWhatWasTakenOutLeavingOnlyWhitespaceCanBeUndone() throws {
        let (draft, editor) = try field("hello\n")
        editor.insertText("", replacementRange: NSRange(location: 0, length: 5))
        settle()
        XCTAssertEqual(draft.text, "")

        editor.undoManager?.undo()
        settle()
        editor.undoManager?.undo()
        settle()
        XCTAssertEqual(draft.text, "hello\n")
    }

    /// The field outlives a session switch, so a draft put in from outside is
    /// another session's, and undo must not carry this one's typing into it.
    func testUndoCannotReachBackPastADraftPutInFromOutside() throws {
        let (draft, editor) = try field("")
        editor.insertText("for session A", replacementRange: editor.selectedRange())
        XCTAssertEqual(draft.text, "for session A")

        draft.identity = "B"
        draft.text = "session B's own draft"
        settle()
        XCTAssertEqual(editor.string, "session B's own draft")

        editor.undoManager?.undo()
        settle()
        XCTAssertEqual(draft.text, "session B's own draft")
        XCTAssertEqual(editor.string, "session B's own draft")
    }

    func testCopyingKeepsTheChipsAndGivesOtherAppsTheText() throws {
        let original = pieces(.text("see "), .chip(.session(probes)))
        let (draft, editor) = try field(original)
        let board = NSPasteboard(name: NSPasteboard.Name("dex-chip-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(editor.writeSelection(to: board, types: editor.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "see @Probe rot")

        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(editor.readSelection(from: board, type: ChipText.pasteboardType))

        XCTAssertEqual(draft.text, original + original)
        XCTAssertEqual(chips(in: editor), 2)
    }

    func testAPastedLinkChipFillsInItsTitleWithoutMovingTheCaret() throws {
        answering(nil)
        let (draft, editor) = try field("see ")
        let link = PastedLink(url: "https://github.com/acme/app/pull/12")!
        XCTAssertTrue(editor.insertLinkChip(.link(LinkMention(link)), replacing: NSRange(location: 4, length: 0)))
        editor.insertText("then", replacementRange: editor.selectedRange())
        let caret = editor.selectedRange()

        let resolved = Mention.link(LinkMention(link, resolution: LinkResolution(title: "Fix the sidebar")))
        editor.updateLinkChips(for: link.url, to: resolved)

        XCTAssertEqual(draft.text, pieces(.text("see "), .chip(resolved), .text(" then")))
        XCTAssertEqual(editor.selectedRange(), caret)
    }

    func testAPastedLinkThatCannotBeLookedUpGoesBackToItsURL() throws {
        answering(nil)
        let (draft, editor) = try field("see ")
        let link = PastedLink(url: "https://github.com/acme/app/pull/12")!
        XCTAssertTrue(editor.insertLinkChip(.link(LinkMention(link)), replacing: NSRange(location: 4, length: 0)))
        editor.unchipLinks(for: link.url)

        XCTAssertEqual(draft.text, "see https://github.com/acme/app/pull/12 ")
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
    }

    func testAPastedLinkChipDeletedBeforeItsLookupStaysDeleted() throws {
        answering(nil)
        let (draft, editor) = try field("")
        let link = PastedLink(url: "https://github.com/acme/app/pull/12")!
        XCTAssertTrue(editor.insertLinkChip(.link(LinkMention(link)), replacing: NSRange(location: 0, length: 0)))
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.deleteBackward(nil)
        editor.updateLinkChips(for: link.url, to: .link(LinkMention(link, resolution: LinkResolution(title: "x"))))

        XCTAssertEqual(draft.text, "")
    }

    private struct Answer: ExternalLinkLookup {
        let answer: LinkResolution?
        func resolve(_ link: PastedLink) async throws -> LinkResolution? { answer }
    }

    private func answering(_ answer: LinkResolution?) {
        let saved = ComposerLinkPaste.resolver
        ComposerLinkPaste.resolver = PastedLinkResolver(lookups: [.github: Answer(answer: answer)])
        addTeardownBlock { @MainActor in ComposerLinkPaste.resolver = saved }
    }

    private func wait(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { settle() }
    }

    private let pr = PastedLink(url: "https://github.com/acme/app/pull/12")!

    /// A relaunch with a placeholder saved in the draft, a switch away and back,
    /// the overlay closed and opened: each builds the chip afresh.
    func testAPendingLinkInADraftPutInFromOutsideIsLookedUp() throws {
        answering(LinkResolution(title: "Fix the sidebar"))
        let (draft, _) = try field(pieces(.text("see "), .chip(.link(LinkMention(pr)))))
        let resolved = pieces(.text("see "), .chip(.link(LinkMention(pr, resolution: LinkResolution(title: "Fix the sidebar")))))

        wait { draft.text == resolved }
        XCTAssertEqual(draft.text, resolved)
    }

    /// A chip brought back by undo after its lookup failed is not asked about
    /// again, or every undo would be answered with a fresh unchip and nothing
    /// before the paste could ever be reached.
    func testUndoGetsBackPastALinkWhoseLookupFailed() throws {
        answering(nil)
        let (draft, editor) = try field("")
        XCTAssertTrue(editor.insertLinkChip(.link(LinkMention(pr)), replacing: NSRange(location: 0, length: 0)))
        wait { draft.text == pr.url + " " }
        XCTAssertEqual(draft.text, pr.url + " ")

        editor.undoManager?.undo()
        for _ in 0..<4 { settle() }
        XCTAssertEqual(draft.text, pieces(.chip(.link(LinkMention(pr))), .text(" ")))

        editor.undoManager?.undo()
        for _ in 0..<4 { settle() }
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(editor.undoManager?.canRedo == true)
    }

    func testUndoingAndRedoingAPasteStillFillsInTheTitle() throws {
        answering(LinkResolution(title: "Fix the sidebar"))
        let (draft, editor) = try field("")
        let resolved = pieces(.chip(.link(LinkMention(pr, resolution: LinkResolution(title: "Fix the sidebar")))), .text(" "))
        XCTAssertTrue(editor.insertLinkChip(.link(LinkMention(pr)), replacing: NSRange(location: 0, length: 0)))
        editor.undoManager?.undo()
        for _ in 0..<4 { settle() }
        editor.undoManager?.redo()

        wait { draft.text == resolved }
        XCTAssertEqual(draft.text, resolved)
    }

    func testAPendingLinkThatCannotBeLookedUpAfterARebuildGoesBackToItsURL() throws {
        answering(nil)
        let (draft, _) = try field("")
        draft.text = pieces(.text("see "), .chip(.link(LinkMention(pr))))
        settle()

        wait { draft.text == "see " + pr.url }
        XCTAssertEqual(draft.text, "see " + pr.url)
    }

}
