import DexCore
import AppKit
import SwiftUI

/// Sits over a whole surface — the list column, or the composer overlay — to catch
/// dropped files. SwiftUI's own `onDrop` hangs its destination view *behind* the
/// content, so a focused text field — whose field editor takes file and image
/// drags — would swallow the drop first.
struct ComposerDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let attach: ([ComposerAttachment]) -> Void

    func makeNSView(context: Context) -> DropCatchingView {
        let view = DropCatchingView()
        view.registerForDraggedTypes(FileDrop.acceptedTypes)
        return view
    }

    func updateNSView(_ view: DropCatchingView, context: Context) {
        view.attach = attach
        view.targeted = { isTargeted = $0 }
    }
}

final class DropCatchingView: NSView {
    var attach: ([ComposerAttachment]) -> Void = { _ in }
    var targeted: (Bool) -> Void = { _ in }

    /// Clicks belong to the field, the send button and the chips underneath. Drags
    /// still land here: AppKit picks a dragging destination by walking registered
    /// views front to back, without consulting `hitTest`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard FileDrop.canRead(sender.draggingPasteboard) else { return [] }
        targeted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        targeted(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        targeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targeted(false)

        let dropped = FileDrop.attachments(from: sender.draggingPasteboard)
        guard !dropped.isEmpty else { return false }

        attach(dropped)
        return true
    }
}
