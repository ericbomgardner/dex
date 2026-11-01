import XCTest
@testable import DexCore

final class ComposerHeightTests: XCTestCase {
    private func maxLines(columnHeight: CGFloat,
                          lineHeight: CGFloat = 20,
                          insets: CGFloat = 16,
                          ceiling: Int = 5) -> Int {
        ComposerHeight.maxLines(columnHeight: columnHeight,
                                lineHeight: lineHeight,
                                insets: insets,
                                minLines: 3,
                                ceiling: ceiling)
    }

    func testTheFieldStopsAtTheCeilingItIsGiven() {
        XCTAssertEqual(maxLines(columnHeight: 616), 5)
        XCTAssertEqual(maxLines(columnHeight: 616, ceiling: 8), 8)
    }

    func testATallColumnNoLongerBuysMoreLines() {
        XCTAssertEqual(maxLines(columnHeight: 1200), maxLines(columnHeight: 620))
    }

    func testAShortWindowStillGivesUpLinesToTheList() {
        XCTAssertEqual(maxLines(columnHeight: 200), 4)
        XCTAssertEqual(maxLines(columnHeight: 120), 3)
        XCTAssertEqual(maxLines(columnHeight: 40), 3)
    }

    func testTheMinimumOutranksACeilingBelowIt() {
        XCTAssertEqual(maxLines(columnHeight: 616, ceiling: 1), 3)
    }

    func testWithoutACeilingTheColumnIsTheOnlyBound() {
        let unbounded = ComposerHeight.maxLines(columnHeight: 616,
                                                lineHeight: 20,
                                                insets: 16,
                                                minLines: 3)
        XCTAssertEqual(unbounded, 14)
    }

    func testAnUnmeasuredColumnFallsBackToTheMinimum() {
        XCTAssertEqual(maxLines(columnHeight: 0), 3)
        XCTAssertEqual(maxLines(columnHeight: 620, lineHeight: 0), 3)
    }
}
