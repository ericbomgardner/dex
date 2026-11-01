import AppKit

/// A view a selection can be started in, and answered from once it is.
///
/// Two of them: the runs of prose, and the empty pane behind and around the
/// column. They share this because whichever one the drag began in is the one
/// holding the caret when ⌘C arrives.
package class SelectionSurface: NSView {

    private(set) weak var owner: TranscriptSelection?

    package override var isFlipped: Bool { true }

    package override var acceptsFirstResponder: Bool { true }

    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Tabbing through a conversation a paragraph at a time is nobody's idea of
    /// getting anywhere.
    package override var canBecomeKeyView: Bool { false }

    func hold(_ selection: TranscriptSelection?) {
        owner = selection
    }

    @objc func copy(_ sender: Any?) {
        owner?.copyToPasteboard()
    }

    package override func selectAll(_ sender: Any?) {
        owner?.selectEverything()
    }

    /// Copy stays in the menu with nothing selected, greyed out, the way a text
    /// view keeps it.
    package override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(selectionItem("Copy", #selector(copy(_:)), enabled: !owner.isEmpty))
        menu.addItem(selectionItem("Select All", #selector(selectAll(_:)), enabled: true))
        return menu
    }

    func selectionItem(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    package override func cancelOperation(_ sender: Any?) {
        owner?.clear()
    }

    /// A key equivalent is offered to every view in the window, not to the one
    /// holding the caret, so this answers only while the selection is ours —
    /// otherwise the transcript would take the copy out of the composer.
    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers {
        case "c": return owner?.copyToPasteboard() ?? false
        case "a": owner?.selectEverything(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
