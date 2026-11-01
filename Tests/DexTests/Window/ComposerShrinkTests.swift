import DexCore
import AppKit
import Observation
import SwiftUI
import XCTest

@testable import DexUI

@MainActor
final class ComposerShrinkTests: XCTestCase {
    @Observable
    final class Model {
        var text = ""
        var height: CGFloat = 0
    }

    private struct Host: View {
        let model: Model
        @State private var height: CGFloat = 0
        var body: some View {
            ComposerField(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                placeholder: "",
                onSend: { model.text = "" },
                onCancel: {},
                onHeightChange: { height = $0 },
                scrollsPast: 400,
                claimsFocus: false
            )
            .frame(width: 480, height: min(max(height, 30), 400))
            .onChange(of: height, initial: true) { model.height = height }
        }
    }

    private var window: NSWindow?

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func find(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let editor = view as? ComposerTextView { return editor }
        return view.subviews.lazy.compactMap { self.find(in: $0) }.first
    }

    func testFieldShrinksAfterSend() throws {
        try check(Array(repeating: "line", count: 12).joined(separator: "\n"))
    }

    func testFieldShrinksAfterSendingWrappedText() throws {
        try check(String(repeating: "a long wrapped sentence of words ", count: 40))
    }

    func testFieldShrinksAfterSendingPastTheCap() throws {
        try check(String(repeating: "a long wrapped sentence of words ", count: 400))
    }

    private func check(_ long: String) throws {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        self.window = window
        settle()
        let editor = try XCTUnwrap(find(in: window.contentView))
        let empty = model.height

        editor.insertText(long,
                          replacementRange: editor.selectedRange())
        settle()
        XCTAssertGreaterThan(model.height, empty)

        editor.onSend()
        settle()
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(model.height, empty)
    }
}
