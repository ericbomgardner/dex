import XCTest
@testable import DexCore

final class ComposerAttachmentTests: XCTestCase {
    private let shot = ComposerAttachment(path: "/Users/me/Desktop/Screen Shot 1.png")
    private let other = ComposerAttachment(path: "/Users/me/Desktop/Screen Shot 2.png")

    func testWithNothingDroppedThePromptIsJustTheDraft() {
        XCTAssertEqual(ComposerAttachments.prompt(draft: "fix the sidebar", attachments: []),
                       "fix the sidebar")
        XCTAssertNil(ComposerAttachments.prompt(draft: "  \n ", attachments: []))
    }

    func testEachDroppedFileGetsItsOwnLineAfterTheDraft() {
        XCTAssertEqual(
            ComposerAttachments.prompt(draft: "fix the sidebar", attachments: [shot, other]),
            """
            fix the sidebar

            Attached: `/Users/me/Desktop/Screen Shot 1.png`
            Attached: `/Users/me/Desktop/Screen Shot 2.png`
            """
        )
    }

    func testTheBlankLineBeforeThePathsIsExactlyOne() {
        let prompt = ComposerAttachments.prompt(draft: "look at this:\n\n\n", attachments: [shot])

        XCTAssertEqual(prompt, "look at this:\n\nAttached: `\(shot.path)`")
        XCTAssertFalse(prompt?.contains("\n\n\n") ?? true, "the draft's trailing blank lines survived")
    }

    func testAFileDroppedWithNoDraftStillDispatches() {
        XCTAssertEqual(ComposerAttachments.prompt(draft: "", attachments: [shot]),
                       "Attached: `\(shot.path)`")
    }

    func testTheSameFileDroppedTwiceIsAttachedOnce() {
        let kept = ComposerAttachments.adding([shot, other], to: [shot])

        XCTAssertEqual(kept, [shot, other])
    }

    func testDroppedFilesKeepTheOrderTheyArrivedIn() {
        XCTAssertEqual(ComposerAttachments.adding([other], to: [shot]), [shot, other])
    }

    func testAttachmentsThatVanishedWhileTheAppWasClosedAreDropped() {
        let kept = ComposerAttachments.present([shot, other]) { $0 == self.shot.path }

        XCTAssertEqual(kept, [shot])
    }

    func testTheChipShowsTheFileName() {
        XCTAssertEqual(shot.name, "Screen Shot 1.png")
    }

    func testAnOrdinaryPathGoesOutExactlyAsItWasDropped() {
        XCTAssertEqual(ComposerAttachments.outgoing(draft: "look", attachments: [shot]),
                       ComposerAttachments.prompt(draft: "look", attachments: [shot]))
    }

    func testAScreenshotIsSentUnderAPathTheSessionCanTypeBack() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Screenshot 2026-09-07 at 11.34.01\u{202F}PM.png")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: folder) }

        let message = ComposerAttachments.outgoing(
            draft: "what colour is the rail",
            attachments: [ComposerAttachment(path: source.path)]
        )

        let sent = try XCTUnwrap(message?
            .components(separatedBy: "Attached: `").last?
            .dropLast())
        XCTAssertTrue(ComposerStash.typesAsWritten(String(sent)), "\(sent) cannot be typed back")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: String(sent))),
                       Data("pixels".utf8))
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: String(sent)).deletingLastPathComponent()
        )
    }

    /// The link is written at the send, so what a draft keeps against a session
    /// is the reader's own path — one left for a week points at the file, not at
    /// a link the scratch space has since swept up.
    func testWhatIsHeldInADraftIsNotTouchedBySendingIt() throws {
        let held = [ComposerAttachment(
            path: "/Users/me/Desktop/Screenshot 2026-09-07 at 11.34.01\u{202F}PM.png"
        )]

        _ = ComposerAttachments.outgoing(draft: "look", attachments: held)

        XCTAssertEqual(held.map(\.path).first,
                       "/Users/me/Desktop/Screenshot 2026-09-07 at 11.34.01\u{202F}PM.png")
    }
}
