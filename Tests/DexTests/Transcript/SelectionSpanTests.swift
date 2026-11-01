import XCTest
@testable import DexCore

final class SelectionSpanTests: XCTestCase {

    private func point(_ path: [Int], _ offset: Int) -> SelectionPoint {
        SelectionPoint(path: path, offset: offset)
    }

    /// The ordinary case: a drag inside one paragraph takes the characters
    /// between where it started and where it let go.
    func testOnePieceTakesTheCharactersBetween() {
        let span = SelectionSpan(from: point([3, 0], 4), to: point([3, 0], 11))
        XCTAssertEqual(span.range(in: [3, 0], length: 40), 4..<11)
    }

    /// Dragged back up the pane rather than down it. The span is the same
    /// stretch, so the piece is asked the same question and answers it the same.
    func testABackwardsDragTakesTheSameStretch() {
        let span = SelectionSpan(from: point([3, 0], 11), to: point([3, 0], 4))
        XCTAssertEqual(span.range(in: [3, 0], length: 40), 4..<11)
    }

    /// What the whole thing is for: the piece the drag started in gives up its
    /// tail, everything between goes whole, and the piece it ended in gives up
    /// its head.
    func testAStretchAcrossPiecesTakesTailWholeHead() {
        let span = SelectionSpan(from: point([1, 0], 6), to: point([4, 2], 3))
        XCTAssertEqual(span.range(in: [1, 0], length: 20), 6..<20)
        XCTAssertEqual(span.range(in: [2], length: 12), 0..<12)
        XCTAssertEqual(span.range(in: [3, 1], length: 8), 0..<8)
        XCTAssertEqual(span.range(in: [4, 2], length: 30), 0..<3)
    }

    /// A piece outside the stretch is taken from at neither end.
    func testAPieceOutsideTheStretchIsUntouched() {
        let span = SelectionSpan(from: point([2, 0], 0), to: point([2, 0], 5))
        XCTAssertNil(span.range(in: [1, 9], length: 10))
        XCTAssertNil(span.range(in: [3], length: 10))
    }

    /// Paths are read a level at a time, so a block inside an item sorts under
    /// that item rather than beside it.
    func testDeeperPathsSortUnderTheirItem() {
        let span = SelectionSpan(from: point([2], 0), to: point([2, 4], 2))
        XCTAssertEqual(span.range(in: [2, 0], length: 6), 0..<6)
        XCTAssertNil(span.range(in: [1, 7], length: 6))
    }

    /// A drag that never moved selects nothing, rather than an empty range at
    /// the point it was pressed.
    func testAClickTakesNothing() {
        let span = SelectionSpan(from: point([0], 3), to: point([0], 3))
        XCTAssertTrue(span.isEmpty)
        XCTAssertNil(span.range(in: [0], length: 10))
    }

    /// A stretch that stops exactly where a piece begins leaves that piece out —
    /// the alternative is a highlight on a card the drag only just reached.
    func testAStretchStoppingAtAnEdgeLeavesThePieceOut() {
        let span = SelectionSpan(from: point([0], 2), to: point([1], 0))
        XCTAssertEqual(span.range(in: [0], length: 9), 2..<9)
        XCTAssertNil(span.range(in: [1], length: 9))
    }

    /// Offsets are clamped rather than trusted: a piece that shrank between the
    /// drag and the copy is a shorter piece, not a crash.
    func testOffsetsPastTheEndAreClamped() {
        let span = SelectionSpan(from: point([0], 0), to: point([0], 99))
        XCTAssertEqual(span.range(in: [0], length: 5), 0..<5)
    }

    /// A card or a tool row is one character long, so the same question answers
    /// whether it was crossed rather than how far into it the mouse got.
    func testAWholePieceReadsAsOneCharacter() {
        let span = SelectionSpan(from: point([0], 1), to: point([2], 4))
        XCTAssertEqual(span.range(in: [1], length: 1), 0..<1)
    }
}
