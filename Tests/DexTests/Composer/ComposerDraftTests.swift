import XCTest
@testable import DexCore

final class ComposerDraftTests: XCTestCase {
    func testAnOrdinaryDraftIsStoredVerbatim() {
        XCTAssertEqual(ComposerDraft.persistable("fix the flaky test"), "fix the flaky test")
    }

    func testSurroundingWhitespaceInsideARealDraftIsKept() {
        let draft = "\n  do the thing:\n\n  - and this one\n"
        XCTAssertEqual(ComposerDraft.persistable(draft), draft)
        XCTAssertEqual(ComposerDraft.restored(draft), draft)
    }

    func testABlankDraftIsNotStored() {
        XCTAssertNil(ComposerDraft.persistable(""))
        XCTAssertNil(ComposerDraft.persistable("   \n\t "))
    }

    func testABlankInTheStoreRestoresAsEmpty() {
        XCTAssertEqual(ComposerDraft.restored(nil), "")
        XCTAssertEqual(ComposerDraft.restored(""), "")
        XCTAssertEqual(ComposerDraft.restored("  \n "), "")
    }

    func testClearingAfterDispatchClearsWhatIsStored() {
        XCTAssertNil(ComposerDraft.persistable(""))
        XCTAssertEqual(ComposerDraft.restored(ComposerDraft.persistable("")), "")
    }
}
