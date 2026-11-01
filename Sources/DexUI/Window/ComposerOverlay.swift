import DexCore
import AppKit
import SwiftUI

/// Where a new session is written. Reached with ⌘N, from the row at the head of
/// the list, or by dropping files on the list.
///
/// The overlay holds its own copy of the draft while it is up, and hands what is
/// left back to the store when it closes — that is what survives a quit.
struct ComposerOverlay: View {
    let store: SessionStore

    @State private var draft: String
    @State private var caret: String?
    @State private var mentions = MentionMenu()
    @State private var searched = MentionSearch()
    @State private var fieldHeight = ChromeMetrics.composerFieldMinHeight
    @State private var isDropTarget = false
    @State private var didDispatch = false

    init(store: SessionStore) {
        self.store = store
        _draft = State(initialValue: store.composer.draft)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OverlayScrim { store.closeOverlay() }
                panel(ceiling: ceiling(in: proxy.size.height))
            }
        }
        .transition(.opacity)
        .task(id: LinkedSearch(query: SessionMentions.query(in: shown), revision: store.linkedWork.revision)) {
            searched = await LinkedSearch.run(for: SessionMentions.query(in: shown), in: store) ?? searched
            offerMentions()
        }
        // However it closes — dismissed, clicked away, or the window shut on it —
        // the draft goes back to the store, and is there next time it opens.
        // Unless it was sent, in which case there is nothing left to hand back.
        .onDisappear {
            if !didDispatch, keepsDraft { store.composer.draft = draft }
        }
        // Quitting mid-sentence never reaches the close above, and only what the
        // store holds gets written to disk.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification
        )) { _ in
            if keepsDraft { store.composer.draft = draft }
        }
    }

    private var keepsDraft: Bool {
        return true
    }

    private func panel(ceiling: CGFloat) -> some View {
        VStack(spacing: 0) {
            ComposerHeader(store: store)
                .padding(.horizontal, ChromeMetrics.horizontal)
                .padding(.vertical, ChromeMetrics.headerVertical)

            Divider()
            editor(ceiling: ceiling)

            if mentions.isOpen {
                MentionMenuList(menu: mentions, accept: accept)
                    .padding(.horizontal, ChromeMetrics.horizontal)
                    .padding(.bottom, ChromeMetrics.barVertical)
            }

            if !store.composer.attachments.isEmpty {
                Divider()
                AttachmentChips(attachments: store.composer.attachments) { store.composer.detach($0) }
                    .padding(.horizontal, ChromeMetrics.horizontal)
                    .padding(.vertical, ChromeMetrics.barVertical)
            }

            Divider()
            footer
        }
        .overlay {
            if isDropTarget { DropHighlight(corner: ChromeMetrics.paletteCorner) }
        }
        .overlay(ComposerDropCatcher(isTargeted: $isDropTarget) { store.composer.attach($0) })
        .overlayCard(width: ChromeMetrics.composerWidth)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
    }

    private func editor(ceiling: CGFloat) -> some View {
        ComposerField(
            text: Binding(
                get: { draft },
                set: {
                    draft = $0
                    offerCompletions()
                }
            ),
            placeholder: store.flavor.composerPlaceholder,
            intercept: intercept,
            onSend: dispatch,
            onCancel: { store.closeOverlay() },
            onHeightChange: { fieldHeight = $0 },
            scrollsPast: ceiling,
            onAttach: { store.composer.attach($0) },
            onCaretChange: {
                caret = $0
                offerCompletions()
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: min(max(fieldHeight, ChromeMetrics.composerFieldMinHeight), ceiling))
        .paneGround(.textBackgroundColor)
    }

    /// The tallest the field gets: what the window can show around it.
    private func ceiling(in available: CGFloat) -> CGFloat {
        max(
            ChromeMetrics.composerFieldMinHeight,
            min(ChromeMetrics.composerFieldMaxHeight,
                available * ChromeMetrics.composerFieldShare)
        )
    }

    private var footer: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Text("⏎ send · ⇧⏎ new line · esc close")
                .font(ChromeType.badge)
                .foregroundStyle(.tertiary)

            Spacer(minLength: ChromeMetrics.inlineGap)
            ComposerSendButton(store: store, isEnabled: canDispatch, dispatch: dispatch)
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.barVertical)
    }

    /// The draft up to the caret as the field shows it, which is what the menus read.
    private var shown: String { ComposerChips.visible(ComposerChips.completing(draft, at: caret)) }

    private func offerCompletions() {
        offerMentions()
    }

    private func offerMentions() {
        mentions.draftChanged(to: shown, offering: store.mentionable(searched: searched))
    }

    private var canDispatch: Bool {
        store.canDispatch(draft: draft)
    }

    /// The menu owns the keys that work it while it is up; with it closed every
    /// key is the text's, and Escape reaches the overlay's own close.
    private func intercept(_ key: ComposerKey) -> Bool {
        guard mentions.isOpen else { return false }
        switch key {
        case .up: mentions.move(-1)
        case .down: mentions.move(1)
        case .accept:
            guard let mention = mentions.selected else { return false }
            accept(mention)
        case .dismiss: mentions.dismiss(for: shown)
        }
        return true
    }

    private func accept(_ mention: Mention) {
        draft = ComposerChips.accepting(mention, in: draft, caret: caret)
        mentions.close()
    }


    private func dispatch() {
        // The field still takes Return while the overlay fades out.
        guard canDispatch, !didDispatch else { return }

        store.composer.draft = draft
        didDispatch = true
        mentions.close()
        store.dispatchQuick()
    }
}
