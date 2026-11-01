import AppKit
import XCTest
@testable import DexUI
@testable import DexCore

@MainActor
final class ProseLinkMenuTests: XCTestCase {

    private func menu(
        _ markdown: String, x: CGFloat = 5
    ) -> NSMenu? {
        let prose = ProseView()
        prose.show(.markdown(Markdown.blocks(in: markdown)), face: ProseFace())
        let size = prose.used(forWidth: 600)
        prose.frame = CGRect(origin: .zero, size: CGSize(width: 600, height: size.height))

        let window = NSWindow(contentRect: prose.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = NSView(frame: prose.frame)
        window.contentView?.addSubview(prose)
        prose.layoutSubtreeIfNeeded()

        let point = prose.convert(CGPoint(x: x, y: size.height / 2), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        return prose.menu(for: event)
    }

    func testAWebLinkOffersOpenAndCopy() {
        let items = menu("[source](https://example.com/a)")?.items.map(\.title)
        XCTAssertEqual(items, ["Open Link", "Copy Link"])
    }

    func testPlainTextHasNoLinkMenu() {
        XCTAssertNil(menu("nothing linked here"))
    }

    func testBlankSpaceBesideALinkIsNotTheLink() {
        XCTAssertNil(menu("[source](https://example.com/a)", x: 500))
    }
}
