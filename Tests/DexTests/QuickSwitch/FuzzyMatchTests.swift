import XCTest
@testable import DexCore

final class FuzzyMatchTests: XCTestCase {

    private func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatch.match(query, in: candidate)?.score
    }

    func testInitialsMatchAcrossWords() {
        let match = FuzzyMatch.match("caw", in: "copper-agents-worker")
        XCTAssertEqual(match?.matched, [0, 7, 14])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.match("AGENT", in: "copper-agents-worker"))
        XCTAssertNotNil(FuzzyMatch.match("agent", in: "AGENTS"))
    }

    func testCharactersOutOfOrderDoNotMatch() {
        XCTAssertNil(FuzzyMatch.match("wac", in: "copper-agents-worker"))
    }

    func testAQueryLongerThanTheNameDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.match("agents", in: "ag"))
    }

    func testSpacesInTheQueryAreIgnored() {
        XCTAssertNotNil(FuzzyMatch.match("copper agents", in: "copper-agents-worker"))
    }

    func testAnEmptyQueryMatchesEverythingWithoutHighlights() {
        let match = FuzzyMatch.match("", in: "anything")
        XCTAssertEqual(match?.matched, [])
    }

    func testWordStartsBeatCharactersBuriedMidWord() {
        let atWordStart = score("mem", "orchard/memory")
        let buried = score("mem", "premembered")
        XCTAssertGreaterThan(atWordStart!, buried!)
    }

    func testAnUnbrokenRunBeatsAScatteredMatch() {
        XCTAssertGreaterThan(score("agent", "agent")!, score("agent", "a-g-e-n-t")!)
    }

    func testAMatchAtTheStartBeatsTheSameMatchLater() {
        XCTAssertGreaterThan(score("agent", "agentdesk")!, score("agent", "xxxxagentdesk")!)
    }

    func testCamelHumpsCountAsWordStarts() {
        XCTAssertGreaterThan(score("sm", "SessionMonitor")!, score("sm", "seismic")!)
    }

    func testHighlightsIndexTheOriginalName() {
        let name = "Claude-Agents"
        let match = FuzzyMatch.match("ca", in: name)
        let characters = Array(name)
        XCTAssertEqual(match?.matched.map { characters[$0] }, ["C", "A"])
    }
}
