import AppKit
import XCTest
@testable import DexCore
@testable import DexUI

@MainActor
final class ComposerLinkPasteTests: XCTestCase {

    private final class Host: LinkChipHost {
        var inserted: [(Mention, NSRange)] = []
        var updated: [Mention] = []
        var unchipped: [String] = []
        var refuses = false
        var settled: XCTestExpectation?

        func insertLinkChip(_ mention: Mention, replacing range: NSRange) -> Bool {
            guard !refuses else { return false }
            inserted.append((mention, range))
            return true
        }

        func updateLinkChips(for url: String, to mention: Mention) {
            updated.append(mention)
            settled?.fulfill()
        }

        func unchipLinks(for url: String) {
            unchipped.append(url)
            settled?.fulfill()
        }
    }

    private struct Answer: ExternalLinkLookup {
        let answer: LinkResolution?
        func resolve(_ link: PastedLink) async throws -> LinkResolution? { answer }
    }

    private func paste(_ text: String, answer: LinkResolution?, host: Host) async -> Bool {
        let resolver = PastedLinkResolver(lookups: [.github: Answer(answer: answer)])
        let paste = ComposerLinkPaste(host: host, resolver: resolver)
        host.settled = expectation(description: "settled")
        let took = paste.paste(text, replacing: NSRange(location: 3, length: 0))
        if took { await fulfillment(of: [host.settled!], timeout: 2) }
        return took
    }

    func testALoneLinkBecomesAPlaceholderThenItsTitle() async {
        let host = Host()
        let took = await paste(" https://github.com/acme/app/pull/12\n",
                               answer: LinkResolution(title: "Fix the sidebar", state: .merged), host: host)
        XCTAssertTrue(took)
        XCTAssertEqual(host.inserted.first?.0.title, "acme/app#12")
        XCTAssertEqual(host.inserted.first?.0.isPending, true)
        XCTAssertEqual(host.inserted.first?.1, NSRange(location: 3, length: 0))
        XCTAssertEqual(host.updated.first?.title, "Fix the sidebar")
        XCTAssertEqual(host.updated.first?.typed, "[Fix the sidebar](https://github.com/acme/app/pull/12)")
    }

    func testAFailedLookupLeavesThePlainURL() async {
        let host = Host()
        let took = await paste("https://github.com/acme/app/pull/12", answer: nil, host: host)
        XCTAssertTrue(took)
        XCTAssertEqual(host.unchipped, ["https://github.com/acme/app/pull/12"])
        XCTAssertTrue(host.updated.isEmpty)
    }

    func testTextThatIsNotALoneLinkPastesAsText() {
        let host = Host()
        let paste = ComposerLinkPaste(host: host, resolver: PastedLinkResolver())
        XCTAssertFalse(paste.paste("see https://github.com/acme/app/pull/12", replacing: NSRange()))
        XCTAssertFalse(paste.paste("https://example.com", replacing: NSRange()))
        XCTAssertTrue(host.inserted.isEmpty)
    }

    func testWithoutAHostThatTakesChipsItPastesAsText() {
        let refusing = Host()
        refusing.refuses = true
        XCTAssertFalse(ComposerLinkPaste(host: refusing, resolver: PastedLinkResolver())
            .paste("https://github.com/acme/app/pull/12", replacing: NSRange()))
        XCTAssertFalse(ComposerLinkPaste(host: nil, resolver: PastedLinkResolver())
            .paste("https://github.com/acme/app/pull/12", replacing: NSRange()))
    }


}
