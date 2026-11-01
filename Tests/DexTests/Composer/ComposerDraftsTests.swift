import XCTest
@testable import DexCore

final class ComposerDraftsTests: XCTestCase {
    func testADraftComesBackForTheSessionItWasTypedFor() {
        var drafts = ComposerDrafts()
        drafts["job-a"] = "look at the failing test"
        drafts["job-b"] = "ship it"

        XCTAssertEqual(drafts["job-a"], "look at the failing test")
        XCTAssertEqual(drafts["job-b"], "ship it")
    }

    func testASessionWithNothingTypedForItReadsAsEmpty() {
        XCTAssertEqual(ComposerDrafts()["job-a"], "")
    }

    func testSendingClearsOnlyThatSessionsDraft() {
        var drafts = ComposerDrafts()
        drafts["job-a"] = "ship it"
        drafts["job-b"] = "hold on"

        drafts["job-a"] = ""

        XCTAssertEqual(drafts["job-a"], "")
        XCTAssertEqual(drafts["job-b"], "hold on")
        XCTAssertEqual(drafts.stored.keys.sorted(), ["job-b"])
    }

    func testWhitespaceIsNotSomethingLeftToSay() {
        var drafts = ComposerDrafts()
        drafts["job-a"] = "  \n\t "

        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(drafts["job-a"], "")
    }

    func testDraftsSurviveARoundTripThroughTheStore() throws {
        var drafts = ComposerDrafts()
        drafts["job-a"] = "\n  do the thing:\n\n  - and this one\n"

        let data = try JSONEncoder().encode(drafts)
        let restored = try JSONDecoder().decode(ComposerDrafts.self, from: data)

        XCTAssertEqual(restored, drafts)
    }

    func testABlankLeftInTheStoreStillReadsAsEmpty() {
        let drafts = ComposerDrafts(texts: ["job-a": "  "])

        XCTAssertEqual(drafts["job-a"], "")
    }

    private let shot = ComposerAttachment(path: "/tmp/shot.png")
    private let other = ComposerAttachment(path: "/tmp/other.png")

    func testWhatWasDroppedComesBackForTheSessionItWasDroppedOn() {
        var drafts = ComposerDrafts()
        drafts.setAttachments([shot], for: "job-a")
        drafts.setAttachments([other], for: "job-b")

        XCTAssertEqual(drafts.attachments(for: "job-a"), [shot])
        XCTAssertEqual(drafts.attachments(for: "job-b"), [other])
        XCTAssertEqual(drafts.attachments(for: "job-c"), [])
    }

    func testAnAttachmentSurvivesWithoutAnythingTyped() throws {
        var drafts = ComposerDrafts()
        drafts.setAttachments([shot, other], for: "job-a")

        XCTAssertFalse(drafts.isEmpty)

        let data = try JSONEncoder().encode(drafts)
        let restored = try JSONDecoder().decode(ComposerDrafts.self, from: data)

        XCTAssertEqual(restored.attachments(for: "job-a"), [shot, other])
    }

    func testDetachingTheLastChipLeavesNothingBehind() {
        var drafts = ComposerDrafts()
        drafts.setAttachments([shot], for: "job-a")
        drafts.setAttachments([], for: "job-a")

        XCTAssertTrue(drafts.isEmpty)
    }

    /// The upgrade from before the pane took attachments: drafts written then
    /// carry no files key, and losing them would empty every box.
    func testDraftsWrittenBeforeAttachmentsExistedStillRead() throws {
        let data = Data(#"{"texts":{"job-a":"ship it"}}"#.utf8)

        let restored = try JSONDecoder().decode(ComposerDrafts.self, from: data)

        XCTAssertEqual(restored["job-a"], "ship it")
        XCTAssertEqual(restored.attachments(for: "job-a"), [])
    }

    func testFilesThatVanishedWhileTheAppWasClosedAreDropped() {
        var drafts = ComposerDrafts()
        drafts["job-a"] = "look at these"
        drafts.setAttachments([shot, other], for: "job-a")

        let kept = drafts.present { $0 == self.shot.path }

        XCTAssertEqual(kept.attachments(for: "job-a"), [shot])
        XCTAssertEqual(kept["job-a"], "look at these")
    }
}
