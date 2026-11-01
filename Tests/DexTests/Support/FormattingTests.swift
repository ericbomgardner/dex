import XCTest
@testable import DexCore

final class FormattingTests: XCTestCase {
    func testAgeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            Format.age(since: now.addingTimeInterval(-secondsAgo), now: now)
        }
        XCTAssertEqual(age(3_599), "59m")
        XCTAssertEqual(age(3_600), "1h")
        XCTAssertEqual(age(86_399), "23h")
        XCTAssertEqual(age(86_400), "1d")
    }

    /// Cents under a dollar: the amounts this is for are pennies, and "$0.09"
    /// reads as a rounding error rather than as something paid every turn.
    func testMoneyIsCentsUnderADollarAndDollarsOver() {
        XCTAssertEqual(Format.money(0.075), "8¢")
        XCTAssertEqual(Format.money(0.5), "50¢")
        XCTAssertEqual(Format.money(0.999), "$1.00")
        XCTAssertEqual(Format.money(1.5), "$1.50")
        XCTAssertEqual(Format.money(12), "$12.00")
    }

    func testSubMinuteAgesCollapseToOneLabel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            Format.age(since: now.addingTimeInterval(-secondsAgo), now: now)
        }
        XCTAssertEqual(age(0), "<1m")
        XCTAssertEqual(age(5), "<1m")
        XCTAssertEqual(age(59), "<1m")
        XCTAssertEqual(age(59.9), "<1m")

        XCTAssertEqual(age(60), "1m")
    }

    func testPreciseAgeKeepsSecondsAndMatchesAboveAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func precise(_ secondsAgo: TimeInterval) -> String {
            Format.preciseAge(since: now.addingTimeInterval(-secondsAgo), now: now)
        }
        XCTAssertEqual(precise(0), "0s")
        XCTAssertEqual(precise(16), "16s")
        XCTAssertEqual(precise(59), "59s")

        for secondsAgo in [60.0, 3_599, 3_600, 86_399, 86_400, 500_000] {
            XCTAssertEqual(
                precise(secondsAgo),
                Format.age(since: now.addingTimeInterval(-secondsAgo), now: now)
            )
        }
    }

    func testClockSkewDoesNotProduceNegativeAges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.age(since: now.addingTimeInterval(60), now: now), "<1m")
        XCTAssertEqual(Format.preciseAge(since: now.addingTimeInterval(60), now: now), "0s")
    }

    /// The terminal's own wording for a subagent's run, which the pane repeats.
    func testElapsedReadsTheWayTheTerminalWritesIt() {
        XCTAssertEqual(Format.elapsed(0), "0s")
        XCTAssertEqual(Format.elapsed(57), "57s")
        XCTAssertEqual(Format.elapsed(59.6), "1m")
        XCTAssertEqual(Format.elapsed(60), "1m")
        XCTAssertEqual(Format.elapsed(64), "1m 4s")
        XCTAssertEqual(Format.elapsed(119.7), "2m")
        XCTAssertEqual(Format.elapsed(3_599), "59m 59s")
    }

    func testElapsedPastAnHourCountsHours() {
        XCTAssertEqual(Format.elapsed(3_600), "1h")
        XCTAssertEqual(Format.elapsed(4_320), "1h 12m")
        XCTAssertEqual(Format.elapsed(4_325), "1h 12m 5s")
        XCTAssertEqual(Format.elapsed(3_605), "1h 0m 5s")
        XCTAssertEqual(Format.elapsed(90_000), "25h")
    }

    func testElapsedIgnoresAClockThatRanBackwards() {
        XCTAssertEqual(Format.elapsed(-5), "0s")
    }

    func testCompactCountsDropDigitsThatSayNothing() {
        XCTAssertEqual(Format.compact(0), "0")
        XCTAssertEqual(Format.compact(999), "999")
        XCTAssertEqual(Format.compact(1_000), "1k")
        XCTAssertEqual(Format.compact(37_449), "37.4k")
        XCTAssertEqual(Format.compact(1_000_000), "1M")
        XCTAssertEqual(Format.compact(1_260_000), "1.3M")
    }

    func testShortPathKeepsPathsThatAlreadyFit() {
        XCTAssertEqual(Format.shortPath("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(Format.shortPath("/Users/me/Projects", home: "/Users/me"), "~/Projects")

        XCTAssertEqual(
            Format.shortPath("/Users/me/Projects/garden-planner", home: "/Users/me"),
            "~/Projects/garden-planner"
        )
    }

    func testShortPathElidesDeepPaths() {
        XCTAssertEqual(
            Format.shortPath("/Users/me/Projects/garden-planner/Sources/Views", home: "/Users/me"),
            "…/Sources/Views"
        )
        XCTAssertEqual(Format.shortPath("/private/tmp/a/b/c", home: "/Users/me"), "…/b/c")
    }
}
