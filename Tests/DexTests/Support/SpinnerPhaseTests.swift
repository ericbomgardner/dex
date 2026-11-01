import XCTest
@testable import DexCore

final class SpinnerPhaseTests: XCTestCase {
    private let period = SpinnerPhase.period

    private func gap(_ lhs: Double, _ rhs: Double) -> Double {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    func testAPeriodIsAWholeTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 900.0)
        XCTAssertEqual(SpinnerPhase.turns(at: start), 0, accuracy: 1e-12)
        XCTAssertLessThan(gap(SpinnerPhase.turns(at: start.addingTimeInterval(period)), 0), 1e-12)
    }

    func testItAdvancesWithTheClock() {
        let start = Date(timeIntervalSinceReferenceDate: 900.0)
        XCTAssertEqual(SpinnerPhase.turns(at: start.addingTimeInterval(period / 4)), 0.25, accuracy: 1e-12)
        XCTAssertEqual(SpinnerPhase.turns(at: start.addingTimeInterval(period / 2)), 0.5, accuracy: 1e-12)
    }

    func testTheAngleNeverGoesBackwards() {

        for seconds in [-86_400.6, -1.25, -0.001, 0, 0.001, 1.25, 86_400.6] {
            let turns = SpinnerPhase.turns(at: Date(timeIntervalSinceReferenceDate: seconds))
            XCTAssertGreaterThanOrEqual(turns, 0, "at \(seconds)")
            XCTAssertLessThan(turns, 1, "at \(seconds)")
        }
    }

    func testADegeneratePeriodDoesNotDivideByZero() {
        XCTAssertEqual(SpinnerPhase.turns(at: Date(), period: 0), 0)
        XCTAssertEqual(SpinnerPhase.turns(at: Date(), period: -1), 0)
    }

    private func seededRing(seedReadAt: Date, restartedAt: Date, now: Date) -> Double {
        let seed = SpinnerPhase.turns(at: seedReadAt)
        let advanced = seed + now.timeIntervalSince(restartedAt) / period
        return advanced - advanced.rounded(.down)
    }

    func testSeedingOffsetsTheAngleAsExpected() {

        let born = Date(timeIntervalSinceReferenceDate: 4_242.37)
        for elapsed in stride(from: 0.0, through: 3.0, by: 0.17) {
            let now = born.addingTimeInterval(elapsed)
            XCTAssertLessThan(
                gap(seededRing(seedReadAt: born, restartedAt: born, now: now),
                    SpinnerPhase.turns(at: now)),
                1e-9
            )
        }
    }

    func testSeedingHoldsOnlyWhileTheStartTimeIsUnchanged() {

        let born = Date(timeIntervalSinceReferenceDate: 4_242.37)
        let now = born.addingTimeInterval(10)
        let restarted = born.addingTimeInterval(9.6)

        XCTAssertGreaterThan(
            gap(seededRing(seedReadAt: born, restartedAt: restarted, now: now),
                SpinnerPhase.turns(at: now)),
            0.2,
            "a re-anchored ring is no longer showing the clock"
        )
    }

    func testRowsReRenderIndependentlyAndDriftApart() {

        let born = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = born.addingTimeInterval(30)

        let a = seededRing(seedReadAt: born, restartedAt: now.addingTimeInterval(-0.9), now: now)
        let b = seededRing(seedReadAt: born, restartedAt: now.addingTimeInterval(-0.4), now: now)
        XCTAssertGreaterThan(gap(a, b), 0.2, "two rings re-rendered independently give different angles")

        XCTAssertEqual(SpinnerPhase.turns(at: now), SpinnerPhase.turns(at: now))
    }
}
