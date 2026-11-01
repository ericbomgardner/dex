import XCTest
@testable import DexCore

/// The composer's column is 340pt wide less its 14pt insets, and a chip is capped
/// near a third of that, so three names already need a second line.
final class ChipFlowTests: XCTestCase {
    private let spacing: CGFloat = 3
    private let width: CGFloat = 312

    private func chips(_ widths: [CGFloat], height: CGFloat = 18) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    private func lines(_ sizes: [CGSize]) -> [ChipFlow.Line] {
        ChipFlow.lines(sizes: sizes, spacing: spacing, within: width)
    }

    func testChipsThatFitStayOnOneLine() {
        XCTAssertEqual(lines(chips([120, 140])).count, 1)
    }

    func testAChipThatWouldOverhangStartsANewLine() {
        let broken = lines(chips([120, 140, 150]))

        XCTAssertEqual(broken.map(\.indices), [[0, 1], [2]])
    }

    func testAChipWiderThanTheColumnGetsItsOwnLineRatherThanVanishing() {
        let broken = lines(chips([400, 400]))

        XCTAssertEqual(broken.map(\.indices), [[0], [1]])
    }

    func testNoChipsMeasuresAsNoHeight() {
        XCTAssertEqual(ChipFlow.height(of: lines([]), spacing: spacing), 0)
    }

    func testEachExtraLineCostsOneChipPlusTheGap() {
        let one = ChipFlow.height(of: lines(chips([120])), spacing: spacing)
        let two = ChipFlow.height(of: lines(chips([120, 140, 150])), spacing: spacing)

        XCTAssertEqual(two - one, 18 + spacing, accuracy: 0.01)
    }

    func testALineIsAsTallAsItsTallestChip() {
        let sizes = [CGSize(width: 100, height: 18), CGSize(width: 100, height: 30)]

        XCTAssertEqual(lines(sizes).first?.height, 30)
    }

    func testChipsRunLeftToRightThenDownward() {
        let sizes = chips([120, 140, 150])
        let origins = ChipFlow.origins(of: lines(sizes), sizes: sizes, spacing: spacing)

        XCTAssertEqual(origins, [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 120 + spacing, y: 0),
            CGPoint(x: 0, y: 18 + spacing),
        ])
    }

    func testTheMeasuredWidthMatchesWhereTheLastChipEnds() {
        let sizes = chips([120, 140])
        let line = lines(sizes)[0]
        let origins = ChipFlow.origins(of: lines(sizes), sizes: sizes, spacing: spacing)

        XCTAssertEqual(line.width, origins[1].x + sizes[1].width, accuracy: 0.01)
        XCTAssertLessThanOrEqual(line.width, width, "a line measured wider than the column")
    }
}
