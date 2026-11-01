import DexCore
import AppKit
import SwiftUI

/// The keys a surface built over the field might want before the text does.
enum ComposerKey {
    case up
    case down
    case accept
    case dismiss

    private static let upArrow = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
    private static let downArrow = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)

    init?(_ event: NSEvent) {
        let typed = event.charactersIgnoringModifiers

        // Shift-return is the text's, so nothing shifted is a key a surface
        // over the field takes.
        if event.modifierFlags.contains(.shift) { return nil }

        switch typed {
        case "\r", "\t": self = .accept
        case "\u{1b}": self = .dismiss
        case Self.upArrow: self = .up
        case Self.downArrow: self = .down
        default: return nil
        }
    }
}

/// SwiftUI's own editor asks for focus and waits its turn, which whatever holds
/// the window wins. This one takes the responder itself, the way the palette's
/// field does, and reports how tall the text has grown so the card can
/// follow it.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    /// First refusal on a keypress, for a surface with something open over the
    /// field — a menu that return and the arrow keys belong to while it is up.
    var intercept: (@MainActor (ComposerKey) -> Bool)?

    let onSend: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onHeightChange: @MainActor (CGFloat) -> Void

    /// The tallest the surface will let the field grow. Below it the field
    /// follows the text and there is nothing to scroll, so no scroller is
    /// offered: the frame catches up a pass after the text grows, and a
    /// scroller shown for that pass narrows the text and re-wraps the line
    /// being typed.
    let scrollsPast: CGFloat

    /// Where a pasted screenshot goes. Without one the field pastes as it always
    /// did, which for an image is nothing at all.
    var onAttach: (@MainActor ([ComposerAttachment]) -> Void)?

    /// Whose draft this is — a session, the new-session composer. A draft
    /// under another identity is a different draft, not an edit of this one.
    var draftIdentity: AnyHashable?

    /// Whether to take the caret on the way in. The composer's own field is what
    /// the pane is for and takes it; a field a card opens on a button is drawn
    /// again every time its page is turned back to, and would take the caret
    /// each time off a move the reader made for another reason.
    var claimsFocus = true

    /// Whether the caret is in here, for a surface that binds return to
    /// something of its own while it isn't.
    var onFocusChange: (@MainActor (Bool) -> Void)?

    /// The draft up to the caret, for menus that complete what is being typed
    /// wherever in the text that is.
    var onCaretChange: (@MainActor (String) -> Void)?

    /// One line of the face the editor is set in. Asked of the font rather than
    /// measured off the view, since whatever is sizing the field has to know it
    /// before there is a field to measure.
    static var lineHeight: CGFloat {
        let font = ChromeType.Reading.editorFont
        return font.ascender - font.descender + font.leading
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCancel: onCancel, onHeightChange: onHeightChange,
                    onCaretChange: onCaretChange, scrollsPast: scrollsPast)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true

        let editor = ComposerTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.intercept = intercept
        editor.onAttach = onAttach
        editor.onFocusChange = onFocusChange
        editor.placeholder = placeholder

        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = ChromeType.Reading.editorFont
        editor.textStorage?.setAttributedString(ChipText.attributed(text, attributes: editor.baseAttributes))
        editor.resumeLinkLookups()
        editor.textContainerInset = NSSize(width: ChromeMetrics.fieldHorizontal,
                                           height: ChromeMetrics.fieldVertical)

        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        let unbounded = CGFloat.greatestFiniteMagnitude
        editor.minSize = .zero
        editor.maxSize = NSSize(width: unbounded, height: unbounded)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                     height: unbounded)
        scroll.documentView = editor

        context.coordinator.shownIdentity = draftIdentity
        let claims = claimsFocus
        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            if claims { context.coordinator.claimFocus(editor) }
            context.coordinator.report(editor)
            context.coordinator.reportCaret(editor)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.follow(context.environment.colorScheme)
        guard let editor = scroll.documentView as? ComposerTextView else { return }

        context.coordinator.text = $text
        context.coordinator.onCancel = onCancel
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onCaretChange = onCaretChange
        context.coordinator.scrollsPast = scrollsPast
        editor.onSend = onSend
        editor.intercept = intercept
        editor.onAttach = onAttach
        editor.onFocusChange = onFocusChange

        if editor.placeholder != placeholder {
            editor.placeholder = placeholder
            editor.needsDisplay = true
        }

        context.coordinator.show(text, as: draftIdentity, in: editor)
        if claimsFocus { context.coordinator.claimFocus(editor) }

        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            context.coordinator.report(editor)
            context.coordinator.reportCaret(editor)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCancel: @MainActor () -> Void
        var onHeightChange: @MainActor (CGFloat) -> Void
        var onCaretChange: (@MainActor (String) -> Void)?
        var scrollsPast: CGFloat

        /// The editor's own undo stack, which has to go when the editor does.
        /// Left to the responder chain, the actions are registered on the
        /// *window's* manager against a target it does not retain, so a Cmd-Z
        /// after the editor has gone pops an action into freed memory and
        /// takes the app with it.
        private let undo = UndoManager()

        private var hasFocus = false
        private var reported: CGFloat = 0
        private var reportedCaret: String?

        /// Set while the draft is being written into the field, which is the
        /// draft already and has nothing to hand back. Nor is its height
        /// reported then: that is mid view-update, where SwiftUI drops the
        /// write, and `report` would remember a height nobody heard.
        private var showing = false

        /// Whose draft the field is showing.
        var shownIdentity: AnyHashable?

        init(text: Binding<String>,
             onCancel: @escaping @MainActor () -> Void,
             onHeightChange: @escaping @MainActor (CGFloat) -> Void,
             onCaretChange: (@MainActor (String) -> Void)?,
             scrollsPast: CGFloat) {
            self.text = text
            self.onCancel = onCancel
            self.onHeightChange = onHeightChange
            self.onCaretChange = onCaretChange
            self.scrollsPast = scrollsPast
        }

        /// Runs until it lands: the editor is asked before SwiftUI has put it in a window.
        func claimFocus(_ editor: NSTextView) {
            guard !hasFocus, let window = editor.window else { return }
            hasFocus = window.makeFirstResponder(editor)
        }

        /// Laid out rather than counted, so wrapped lines and pasted blocks both
        /// give the card the height they actually need.
        func report(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else {
                return
            }
            manager.ensureLayout(for: container)

            let height = manager.usedRect(for: container).height + editor.textContainerInset.height * 2
            editor.enclosingScrollView?.hasVerticalScroller = height > scrollsPast
            guard height != reported else { return }
            reported = height
            onHeightChange(height)
        }

        func reportCaret(_ editor: NSTextView) {
            guard let onCaretChange, let storage = editor.textStorage else { return }
            let caret = min(NSMaxRange(editor.selectedRange()), storage.length)
            let head = ChipText.draft(from: storage, in: NSRange(location: 0, length: caret))
            guard head != reportedCaret else { return }
            reportedCaret = head
            onCaretChange(head)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// A draft put in from outside. Another draft altogether — the field
        /// outlives a session switch — takes the undo stack with it, or an undo
        /// would land one session's typing in another's. The same draft changed
        /// from outside — a menu row taken, a send clearing the box — is an
        /// edit like any other and can be undone. Only what differs is
        /// replaced, so chips either side keep their attachments and the
        /// caret lands after the change.
        func show(_ draft: String, as identity: AnyHashable?, in editor: ComposerTextView) {
            let switched = identity != shownIdentity
            shownIdentity = identity
            if switched {
                editor.breakUndoCoalescing()
                undo.removeAllActions()
                editor.forgetFailedLinks()
            }
            guard let storage = editor.textStorage, ChipText.draft(from: storage) != draft else { return }
            let wanted = ChipText.attributed(draft, attributes: editor.baseAttributes)

            let old = storage.length
            let new = wanted.length
            var prefix = 0
            while prefix < min(old, new), ChipText.sameUnit(storage, prefix, wanted, prefix) { prefix += 1 }
            var suffix = 0
            while suffix < min(old, new) - prefix,
                  ChipText.sameUnit(storage, old - 1 - suffix, wanted, new - 1 - suffix) { suffix += 1 }

            let replaced = NSRange(location: prefix, length: old - prefix - suffix)
            let inserted = wanted.attributedSubstring(from: NSRange(location: prefix, length: new - prefix - suffix))
            showing = true
            if switched || !editor.shouldChangeText(in: replaced, replacementString: inserted.string) {
                storage.replaceCharacters(in: replaced, with: inserted)
                editor.didChangeText()
                undo.removeAllActions()
            } else {
                storage.replaceCharacters(in: replaced, with: inserted)
                editor.didChangeText()
            }
            editor.setSelectedRange(NSRange(location: switched ? storage.length : prefix + inserted.length, length: 0))
            showing = false
            editor.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !showing else { return }
            reportCaret(editor)
            if let storage = editor.textStorage {
                text.wrappedValue = ChipText.draft(from: storage)
            }
            report(editor)
        }

        /// A chip's attributes are not ones to go on typing in.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView else { return }
            editor.typingAttributes = editor.baseAttributes
            if !showing { reportCaret(editor) }
        }

        func textView(_ editor: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            onCancel()
            return true
        }
    }
}

/// Return sends; shift-Return breaks the line. The
/// break is typed rather than left to AppKit, whose own shift-Return inserts a
/// line separator the CLI would never see as a newline.
package final class ComposerTextView: NSTextView {
    var onSend: @MainActor () -> Void = {}
    var intercept: (@MainActor (ComposerKey) -> Bool)?
    var onAttach: (@MainActor ([ComposerAttachment]) -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    package var placeholder = ""

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? ChromeType.Reading.editorFont, .foregroundColor: NSColor.textColor]
    }

    /// Puts a chip in the text as though it had been typed there, undo and
    /// all, for anything that makes one other than the menus: at the caret, or
    /// over `range`, with a space after it unless one is already there.
    @discardableResult
    func insertChip(_ mention: Mention, replacing range: NSRange? = nil) -> Bool {
        let target = range ?? rangeForUserTextChange
        guard target.location != NSNotFound, let storage = textStorage else { return false }
        let chip = NSMutableAttributedString(
            attributedString: ChipText.chip(mention, attributes: baseAttributes, font: chipFont)
        )
        let after = NSMaxRange(target)
        let spaced = after < storage.length
            && (storage.string as NSString).substring(with: NSRange(location: after, length: 1))
                .rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        if !spaced { chip.append(NSAttributedString(string: " ", attributes: baseAttributes)) }
        return insert(chip, replacing: target)
    }

    @discardableResult
    func insert(_ text: NSAttributedString, replacing range: NSRange) -> Bool {
        guard shouldChangeText(in: range, replacementString: text.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        return true
    }

    private var chipFont: NSFont { font ?? ChromeType.Reading.editorFont }

    private lazy var linkPaste = ComposerLinkPaste(host: self)

    /// Every pasted link's chip still waiting on a lookup, last first so each
    /// can be replaced without moving the ones before it.
    fileprivate func waitingLinks(for url: String? = nil) -> [(NSRange, LinkMention)] {
        guard let storage = textStorage else { return [] }
        var found: [(NSRange, LinkMention)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let chip = value as? MentionChipAttachment, case .link(let link) = chip.mention,
                  !link.isResolved, url == nil || link.url == url
            else { return }
            for offset in 0..<range.length {
                found.append((NSRange(location: range.location + offset, length: 1), link))
            }
        }
        return found.reversed()
    }

    func forgetFailedLinks() {
        linkPaste.forgetFailures()
    }

    /// Starts a lookup for any waiting chip nothing is looking up.
    func resumeLinkLookups() {
        let waiting = waitingLinks().compactMap { PastedLink(url: $0.1.url) }
        guard !waiting.isEmpty else { return }
        linkPaste.resume(waiting)
    }

    /// Copied with its chips, so pasting back in here gives chips again; what
    /// another app gets is the text the chips stand for.
    package override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ChipText.pasteboardType, .string]
    }

    package override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        pboard.declareTypes(types, owner: nil)
        return types.map { writeSelection(to: pboard, type: $0) }.contains(true)
    }

    package override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage else { return false }
        let draft = selectedRanges.map { ChipText.draft(from: storage, in: $0.rangeValue) }.joined()
        switch type {
        case ChipText.pasteboardType: return pboard.setString(draft, forType: type)
        case .string: return pboard.setString(ComposerChips.sentence(draft), forType: .string)
        default: return super.writeSelection(to: pboard, type: type)
        }
    }

    package override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ChipText.pasteboardType] + super.readablePasteboardTypes
    }

    package override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == ChipText.pasteboardType, let draft = pboard.string(forType: type) else {
            return super.readSelection(from: pboard, type: type)
        }
        let target = rangeForUserTextChange
        guard target.location != NSNotFound else { return false }
        insert(ChipText.attributed(draft, attributes: baseAttributes), replacing: target)
        return true
    }

    package override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocusChange?(true) }
        return took
    }

    package override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { onFocusChange?(false) }
        return gave
    }

    /// A plain-text field drops an image on the floor, so one is caught here and
    /// attached instead.
    package override func paste(_ sender: Any?) {
        let attached = FileDrop.pasted(from: .general)
        if !attached.isEmpty, let onAttach {
            onAttach(attached)
            return
        }
        if linkPaste.paste(from: .general, replacing: rangeForUserTextChange) { return }
        super.paste(sender)
    }

    package override func keyDown(with event: NSEvent) {
        // Nothing is intercepted mid-composition: every one of these keys means
        // something to the input method first.
        if !hasMarkedText(),
           let key = ComposerKey(event),
           intercept?(key) == true {
            return
        }

        // Return belongs to the input method while it is composing: there it
        // confirms the candidate rather than the message.
        guard event.charactersIgnoringModifiers == "\r", !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift) {
            insertText("\n", replacementRange: selectedRange())
        } else {
            onSend()
        }
    }

    package override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        resumeLinkLookups()
    }

    package override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        placeholder.draw(
            at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                        y: textContainerInset.height),
            withAttributes: [
                .font: font ?? ChromeType.Reading.editorFont,
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }
}

extension ComposerTextView: LinkChipHost {
    func insertLinkChip(_ mention: Mention, replacing range: NSRange) -> Bool {
        insertChip(mention, replacing: range)
    }

    /// Not an edit of the reader's, so nothing for undo: the chip they pasted
    /// has only learned its name.
    func updateLinkChips(for url: String, to mention: Mention) {
        let waiting = waitingLinks(for: url)
        guard !waiting.isEmpty, let storage = textStorage else { return }
        let selection = selectedRanges
        for (range, _) in waiting {
            storage.replaceCharacters(in: range, with: ChipText.chip(mention, attributes: baseAttributes, font: chipFont))
        }
        selectedRanges = selection
        didChangeText()
    }

    func unchipLinks(for url: String) {
        let waiting = waitingLinks(for: url)
        guard !waiting.isEmpty, let storage = textStorage else { return }
        var selection = selectedRange()
        let shift = (url as NSString).length - 1
        for (range, _) in waiting {
            guard shouldChangeText(in: range, replacementString: url) else { continue }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: url, attributes: baseAttributes))
            didChangeText()
            if selection.location >= NSMaxRange(range) { selection.location += shift }
        }
        setSelectedRange(selection)
    }
}
