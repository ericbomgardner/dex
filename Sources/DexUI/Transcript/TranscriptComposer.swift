import DexCore
import AppKit
import SwiftUI

/// Answer the session without leaving the transcript — a message, or a pick from
/// whatever it is holding up for.
struct TranscriptComposer: View {
    let pane: SessionPane
    @Bindable var store: SessionStore

    /// Height of the pane the composer sits at the foot of, which bounds how tall
    /// the field — and the card above it — may grow before they start scrolling.
    let columnHeight: CGFloat

    /// What the session is answering as, for the line under the field.
    let model: String?

    /// What it is carrying, for the same line.
    let context: SessionContext?

    /// An ask the pane above is answering — a plan, which is decided on the plan
    /// itself. Kept out of the card so its buttons are in one place; still what
    /// words typed here are addressed to, since a plan sent back is a plan sent
    /// back with a reason.
    var decidedInPane: String?

    /// Whether the pane above is drawing the session as working, which decides
    /// where a message stands in: over that line if it starts the turn, under
    /// it if the turn was already going.
    var sessionIsWorking = false

    @State private var menu = SlashMenu()
    @State private var mentions = MentionMenu()
    @State private var searched = MentionSearch()
    @State private var fieldHeight: CGFloat = 0
    @State private var caret: String?
    @State private var isDropTarget = false

    /// The page the card above is on. Free text typed here answers that
    /// question, so which ask it is addressed to follows what is being read
    /// rather than which ask has been waiting longest.
    @State private var reading: String?

    private static var lineHeight: CGFloat { ComposerField.lineHeight }

    private static var minHeight: CGFloat {
        lineHeight + ChromeMetrics.fieldVertical * 2
    }

    private var maxHeight: CGFloat {
        let lines = ComposerHeight.maxLines(columnHeight: columnHeight,
                                            lineHeight: Self.lineHeight,
                                            insets: ChromeMetrics.fieldVertical * 2,
                                            minLines: 1)
        return CGFloat(lines) * Self.lineHeight + ChromeMetrics.fieldVertical * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.inlineGap) {
            HostAskOverlay(
                key: pane.attachment?.hostKey,
                excluding: decidedInPane,
                columnHeight: columnHeight,
                reading: $reading,
                drafts: $store.askDrafts,
                host: store.host
            )
            if let aside = pane.aside {
                AsideCard(aside: aside, columnHeight: columnHeight,
                          onDraft: { pane.draftAside() }, onClose: { pane.closeAside() })
            }
            if menu.isOpen {
                SlashMenuList(menu: menu, accept: accept)
            }
            if mentions.isOpen {
                MentionMenuList(menu: mentions, accept: accept)
            }
            if !pane.attachments.isEmpty {
                AttachmentChips(attachments: pane.attachments) { pane.detach($0) }
            }
            composer
            ComposerStatusLine(pane: pane, store: store, model: model, context: context)
        }
        // Squared to the column the transcript is read in, so the caret starts
        // where the last line of the conversation ended.
        .frame(maxWidth: ChromeMetrics.readingMeasure)
        .padding(.horizontal, ChromeMetrics.readingInset)
        .padding(.vertical, ChromeMetrics.rowVertical)
        .frame(maxWidth: .infinity)
        .background(dropHighlight)
        .overlay(ComposerDropCatcher(isTargeted: $isDropTarget) { pane.attach($0) })
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .task(id: pane.attachment?.workingDirectory) {
            menu.dismiss(for: typedTo)
            await menu.load(
                project: pane.attachment?.workingDirectory
            )
            menu.sessionRuns(sessionRuns)
            menu.draftChanged(to: typedTo)
        }
        .onChange(of: sessionRuns) { menu.sessionRuns(sessionRuns) }
        .task(id: LinkedSearch(query: SessionMentions.query(in: shown), revision: store.linkedWork.revision)) {
            searched = await LinkedSearch.run(for: SessionMentions.query(in: shown), in: store) ?? searched
            offerMentions()
        }
        // Dismissed rather than closed: the draft a session is picked back up on
        // is not one the menu should open over, but typing on it is.
        .onChange(of: pane.attachment?.id) {
            caret = nil
            menu.dismiss(for: typedTo)
            mentions.dismiss(for: shown)
        }
    }

    /// What the attached session's own CLI says it will run. Nil on a row with
    /// no host behind it — an archived conversation, which is read off disk and
    /// has nobody to ask — and the menu offers everything rather than nothing.
    private var sessionRuns: [String]? {
        guard let key = pane.attachment?.hostKey else { return nil }
        let holder = store.host
        // The app answers `/btw` itself, so the CLI's list doesn't get a say.
        return holder.sessions[key]?.commands.map { holder.canAskSideQuestions ? $0 + ["btw"] : $0 }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: ChromeMetrics.inlineGap) {
            field

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: ChromeMetrics.sendButton))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? ChromeColor.accent : ChromeColor.muted)
            .disabled(!canSend)
            .help(sendHelp)
        }
    }

    /// While a question is up, an answer is what the session is waiting on —
    /// and free text is an answer in its own right, so writing one here is
    /// allowed and says so.
    private var sendHelp: String {
        if sideQuestion != nil { return "Ask on the side, without the session hearing it" }
        switch spokenTo?.kind {
        case .question: return "Answer in your own words, dropping the picks above"
        case .none: return isAsking ? "Answer the question above to send" : "Send to this session"
        default: return "Refuse this, with what you wrote as the reason"
        }
    }

    private var placeholder: String {
        switch spokenTo?.kind {
        case .question: return "Answer in your own words"
        case .none: break
        default: return "Say no, and why"
        }
        if isAsking { return "Answer the question above" }
        // Said rather than left blank: the box looks the same either way, and
        // what goes in it is about to restart a session rather than speak to one
        // already listening.
        // Not while a message of theirs is on its way to it: picking the
        // session up is exactly what that message is doing, and offering it
        // again reads as the message having gone nowhere.
        if pane.awaitsResume, pane.saying(for: attachmentKey).isEmpty {
            return "Pick up where this left off"
        }
        return ""
    }

    private var attachmentKey: String? { pane.attachment?.hostKey }

    private var field: some View {
        ComposerField(
            text: draft,
            placeholder: placeholder,
            intercept: intercept,
            onSend: send,
            // Escape reaches here only with the menu closed, which is the one
            // other thing that wants it. Nothing running, nothing happens.
            onCancel: { pane.interrupt() },
            onHeightChange: { fieldHeight = $0 },
            scrollsPast: maxHeight,
            onAttach: { pane.attach($0) },
            draftIdentity: attachmentKey,
            onCaretChange: {
                caret = $0
                offerCompletions()
            }
        )
        .frame(height: min(max(fieldHeight, Self.minHeight), maxHeight))
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: ChromeMetrics.hairline)
        )
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTarget { DropHighlight(corner: ChromeMetrics.fieldCorner) }
    }

    private var draft: Binding<String> {
        Binding(
            get: { pane.draft },
            set: {
                pane.draft = $0
                offerCompletions()
            }
        )
    }

    private func offerCompletions() {
        menu.draftChanged(to: typedTo)
        offerMentions()
    }

    /// The draft up to the caret, which is where a name or command is being typed.
    private var typedTo: String { ComposerChips.completing(pane.draft, at: caret) }

    /// The same as the field shows it, which is what the mention menus read.
    private var shown: String { ComposerChips.visible(typedTo) }

    private func offerMentions() {
        mentions.draftChanged(to: shown, offering: store.mentionable(excluding: attachmentKey, searched: searched))
    }

    /// While a menu is up it owns the keys that work it. Everything else, and
    /// every key when both are closed, belongs to the text. The two are never
    /// open together: a command is the whole first word, and an `@` inside a
    /// word is not a mention.
    private func intercept(_ key: ComposerKey) -> Bool {
        if menu.isOpen { return interceptSlash(key) }
        // Before the field's own escape, which interrupts the session.
        if !mentions.isOpen, key == .dismiss, !pane.openAgents.isEmpty {
            pane.closeAgents()
            return true
        }
        if !mentions.isOpen, key == .dismiss, pane.aside != nil {
            pane.closeAside()
            return true
        }
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

    private func interceptSlash(_ key: ComposerKey) -> Bool {
        switch key {
        case .up: menu.move(-1)
        case .down: menu.move(1)
        case .accept:
            guard let command = menu.selected else { return false }
            accept(command)
        case .dismiss: menu.dismiss(for: typedTo)
        }
        return true
    }

    private func accept(_ command: Command) {
        pane.draft = SlashCompletion.accepting(command, in: pane.draft, caret: caret)
        menu.close()
    }

    private func accept(_ mention: Mention) {
        pane.draft = ComposerChips.accepting(mention, in: pane.draft, caret: caret)
        mentions.close()
    }

    /// The sessions and tasks the draft names, for the lines under the message.
    private var named: [Mention] {
        store.mentions(in: pane.draft)
    }

    /// What is riding along goes in as `Attached:` lines under the text, the way
    /// the new-session composer sends them — a message is the only thing the
    /// session takes.
    private var message: String? {
        ComposerAttachments.prompt(draft: pane.draft, attachments: pane.attachments,
                                   mentions: named)
    }

    private var canSend: Bool {
        if let sideQuestion { return !sideQuestion.isEmpty }
        return message != nil && (!isAsking || spokenTo != nil)
    }

    private var sideQuestion: String? { Aside.question(in: ComposerChips.visible(pane.draft)) }

    /// Whether this session is holding anything out, off the socket.
    private var isAsking: Bool {
        guard let key = pane.attachment?.hostKey else { return false }
        return !store.host
            .asks.pending(forKey: key).isEmpty
    }

    /// The ask a message typed here answers rather than waits on.
    ///
    /// A question takes free text as an answer in its own right. A permission
    /// takes it as the reason it was refused — the one thing the CLI records
    /// beside a refusal, and the only way to say *not that, do this* without
    /// waiting for the model to come back and ask. Either way the words reach
    /// it, so either way the box stays open.
    private var spokenTo: HostAsk? {
        guard let key = pane.attachment?.hostKey else { return nil }
        let mine = store.host
            .asks.pending(forKey: key)

        // A page taken by the pane — a plan, decided on the plan itself — is
        // still what is being read, and is still what these words are for.
        guard let reading, let owner = AskPages.owner(of: reading, in: mine) else {
            return mine.count == 1 ? mine.first : nil
        }
        return owner
    }

    private func send() {
        guard canSend else { return }
        if let sideQuestion {
            pane.askAside(sideQuestion)
            pane.draft = ""
            menu.close()
            return
        }
        // The message with anything riding along named by a path the session
        // can type back, built here rather than in `message`, which SwiftUI asks
        // for on every keystroke and which has no business writing to disk.
        deliver(ComposerAttachments.outgoing(draft: pane.draft, attachments: pane.attachments, mentions: named))
    }

    private func answer(_ ask: HostAsk, with message: String) {
        if ask.kind == .question {
            store.host
                .respond(askId: ask.askId, text: message)
        } else {
            store.host
                .deny(askId: ask.askId, message: message)
        }
    }

    private func deliver(_ message: String?) {
        guard let message else { return }

        // Said instead of answering, which is the whole of what the CLI records
        // for the ask — so the card's picks go nowhere and it comes down.
        if let ask = spokenTo {
            answer(ask, with: message)
            pane.clear()
            pane.spoke()
            menu.close()
            mentions.close()
            return
        }

        pane.send(message, intoTurn: sessionIsWorking)
        menu.close()
        mentions.close()
    }
}
