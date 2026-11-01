import XCTest
@testable import DexCore

final class AskCardHeightTests: XCTestCase {
    private func height(columnHeight: CGFloat,
                        chrome: CGFloat = 100,
                        natural: CGFloat) -> CGFloat {
        AskCardHeight.questionHeight(columnHeight: columnHeight,
                                     chrome: chrome,
                                     natural: natural)
    }

    func testAQuestionThatFitsIsDrawnWhole() {
        XCTAssertEqual(height(columnHeight: 800, natural: 220), 220)
    }

    func testATallQuestionIsCutToTheCardsShareOfTheColumn() {
        XCTAssertEqual(height(columnHeight: 800, natural: 2000), 380)
    }

    func testTheChromeComesOutOfTheShareRatherThanOutOfTheColumn() {
        let bare = height(columnHeight: 800, chrome: 0, natural: 2000)
        XCTAssertEqual(bare - height(columnHeight: 800, chrome: 100, natural: 2000), 100)
    }

    func testAShortPaneKeepsEnoughToAnswerIn() {
        XCTAssertEqual(height(columnHeight: 240, natural: 2000), 120)
    }

    func testTheFloorNeverStretchesAQuestionPastItself() {
        XCTAssertEqual(height(columnHeight: 240, natural: 40), 40)
    }

    func testAnUnmeasuredColumnBoundsNothing() {
        XCTAssertEqual(height(columnHeight: 0, natural: 2000), 2000)
    }
}
