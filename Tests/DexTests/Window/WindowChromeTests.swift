import AppKit
import XCTest

/// The list insets itself by the traffic-light strip and the pane lays a drag
/// strip over it, both from the same height, derived from AppKit rather than
/// stored as a number. These guard that derivation, and the autosave key the
/// split view's saved width lives under.
final class WindowChromeTests: XCTestCase {

    private static let styleMask: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable]

    /// Mirrors `SessionsWindow.titlebarHeight`.
    @MainActor
    private var derived: CGFloat {
        NSWindow.frameRect(forContentRect: .zero, styleMask: Self.styleMask).height
    }

    @MainActor
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                 styleMask: Self.styleMask, backing: .buffered, defer: false)
    }

    @MainActor
    func testDerivingWithoutAWindowMatchesARealOne() {
        let window = window()
        let actual = window.frame.height - window.contentLayoutRect.height
        XCTAssertEqual(derived, actual, accuracy: 0.01)
    }

    @MainActor
    func testTheInsetClearsTheButtonsRatherThanClippingThem() {
        guard let close = window().standardWindowButton(.closeButton) else {
            return XCTFail("no close button")
        }
        XCTAssertGreaterThan(derived, close.frame.maxY,
                             "the strip would overlap the traffic lights")
    }

    /// Mirrors `SplitColumns.hasSavedPosition`. If AppKit's key moved, every launch
    /// would look unsaved and overwrite a width you had dragged.
    private func key(_ name: String) -> String { "NSSplitView Subview Frames \(name)" }

    @MainActor
    func testAppKitSavesUnderTheKeyTheWindowLooksFor() {
        let name = "test.columns.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key(name)) }

        XCTAssertNil(defaults.object(forKey: key(name)), "a fresh name must read as unsaved")

        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        split.isVertical = true
        split.autosaveName = name
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300)))
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300)))
        split.layoutSubtreeIfNeeded()
        split.setPosition(420, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()

        XCTAssertNotNil(defaults.object(forKey: key(name)),
                        "AppKit no longer autosaves under this key — a dragged width would be lost")
    }
}
