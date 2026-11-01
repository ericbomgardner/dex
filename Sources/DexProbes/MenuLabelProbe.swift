import DexUI
import AppKit
import SwiftUI

/// What a borderless `Menu` keeps of its label, measured rather than reasoned
/// from the type.
///
/// The composer's chip names two things — the model and the effort — and drawn
/// as `HStack { Text; Text }` it showed only the first, with nothing logged and
/// nothing to read in the source that says why. AppKit draws a borderless menu's
/// label as a button title, and a stack has no single title to give it.
///
/// Run as `DexProbes --menu-label-probe`. It prints what each shape renders,
/// so a SwiftUI release that starts keeping both fails here rather than in the
/// composer.
@MainActor
enum MenuLabelProbe {

    private static let lead = "Opus 5"
    private static let tail = "Xhigh"

    private static func rendered<V: View>(_ view: V) -> [String] {
        let host = NSHostingView(rootView: view.frame(width: 240, height: 28))
        host.layoutSubtreeIfNeeded()
        var found: [String] = []
        walk(host, into: &found)
        return found
    }

    private static func walk(_ view: NSView, into found: inout [String]) {
        for text in [
            view.accessibilityLabel(), view.accessibilityTitle(),
            view.accessibilityValue() as? String,
            (view as? NSButton)?.title, (view as? NSTextField)?.stringValue,
        ] {
            guard let text, !text.isEmpty, !found.contains(text) else { continue }
            found.append(text)
        }
        for child in view.subviews { walk(child, into: &found) }
    }

    private static func menu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("Low") {}
            Button("High") {}
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The other half of the chip — the effort submenu and the `max` row drawn
    /// dead — and the reason it is reported rather than asserted: **it cannot be
    /// measured from here.** SwiftUI builds a `Menu`'s `NSMenu` when the button
    /// is clicked, not when the view is laid out, so an offscreen host has no
    /// items to walk and this comes back empty whether the rows are right or
    /// wrong. Kept because an empty reading is itself worth printing: it says
    /// which half of the chip has a measurement behind it and which half is
    /// still only eyeballed.
    private static func rows() -> [String] {
        let view = Menu {
            Button("Sonnet") {}
            Divider()
            Menu("Effort: Xhigh") {
                Button("Low") {}
                Button("Xhigh (Default)") {}
                Button("Max — only once a session is running") {}.disabled(true)
            }
        } label: {
            Text("Opus 5  Xhigh")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        let host = NSHostingView(rootView: view.frame(width: 240, height: 28))
        host.layoutSubtreeIfNeeded()
        var menus: [NSMenu] = []
        collect(host, into: &menus)
        return menus.flatMap { describe($0, depth: 0) }
    }

    private static func collect(_ view: NSView, into menus: inout [NSMenu]) {
        if let menu = (view as? NSPopUpButton)?.menu ?? (view as? NSButton)?.menu {
            menus.append(menu)
        }
        for child in view.subviews { collect(child, into: &menus) }
    }

    private static func describe(_ menu: NSMenu, depth: Int) -> [String] {
        menu.items.flatMap { item -> [String] in
            let pad = String(repeating: "  ", count: depth)
            let mark = item.isSeparatorItem ? "—" : (item.isEnabled ? " " : "x")
            let line = item.isSeparatorItem ? "\(pad)—" : "\(pad)[\(mark)] \(item.title)"
            return [line] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
        }
    }

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let stacked = rendered(
            menu {
                HStack(spacing: 6) {
                    Text(lead)
                    Text(tail)
                }
            })

        let joined = rendered(
            menu {
                Text(lead).foregroundColor(.primary)
                    + Text("  ")
                    + Text(tail).foregroundColor(.secondary)
            })

        func says(_ shape: String, _ found: [String]) -> Bool {
            let whole = found.joined(separator: " | ")
            let keeps = whole.contains(lead) && whole.contains(tail)
            print("\(shape): \(keeps ? "both" : "dropped one")  ->  [\(whole)]")
            return keeps
        }

        let stackedKeeps = says("HStack of two Texts ", stacked)
        let joinedKeeps = says("One concatenated Text", joined)

        print("")
        let drawn = rows()
        for line in drawn { print(line) }
        print(
            drawn.isEmpty
                ? "menu content: not measurable offscreen — SwiftUI builds the NSMenu on click"
                : "menu content: \(drawn.count) rows readable, so this can be asserted now")

        guard joinedKeeps else {
            print("FAIL: the shape the composer uses drops half its label")
            return 1
        }
        if stackedKeeps {
            print("NOTE: the stack renders both now — the concatenation is no longer load-bearing")
        }
        return 0
    }
}
