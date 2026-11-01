import DexCore
import SwiftUI

/// Everything a session is holding out, one question to a page.
///
/// A turn can raise several asks and each carries up to four questions, which
/// stacked would be most of a screen — so they are paged through instead, and
/// nothing is sent until the send at the end. Answering is what starts the
/// session moving again, so a question passed over is still on the run and can
/// be come back to.
///
/// A permission is a page too, but it answers on its own buttons rather than
/// waiting for the send, and so never holds the rest of the run up.
package struct AskCard: View {
    let asks: [HostAsk]

    /// Height of the pane the card sits at the foot of, which bounds how tall it
    /// may grow before the question inside it starts scrolling.
    let columnHeight: CGFloat

    let onAnswerQuestion: (String, [String: HostAnswerValue], [String: String]) -> Void
    let onAnswerPermission: (String, HostAskOption) -> Void

    /// Which page is being read, held outside the card because the composer
    /// answers the question in front of you and has to be told which that is.
    @Binding var reading: String?

    /// What has been answered so far, keyed by the page. Held by the store
    /// rather than by the card, which is built again whenever the pane is
    /// pointed at another session — where these were state of its own, a turn
    /// away from a half-written answer was the end of it.
    @Binding var drafts: AskDrafts

    /// Where that page was, for the one thing identity cannot answer: the page
    /// being read is taken off the run and there is no page of that name left
    /// to find.
    package init(
        asks: [HostAsk],
        columnHeight: CGFloat,
        onAnswerQuestion: @escaping (String, [String: HostAnswerValue], [String: String]) -> Void,
        onAnswerPermission: @escaping (String, HostAskOption) -> Void,
        reading: Binding<String?>,
        drafts: Binding<AskDrafts>
    ) {
        self.asks = asks
        self.columnHeight = columnHeight
        self.onAnswerQuestion = onAnswerQuestion
        self.onAnswerPermission = onAnswerPermission
        _reading = reading
        _drafts = drafts
    }

    @State private var page = 0

    /// Which field the caret is in, reported by the field itself rather than
    /// held as SwiftUI focus: the editor is AppKit and takes the responder on
    /// its own, so focus asserted from here would be a second answer to a
    /// question the window has already settled.
    @State private var focus: String?

    /// What the question would be if nothing bounded it, and what the card draws
    /// around it — both measured, since either can be any height: a question
    /// carries up to four options and each option can carry a mockup.
    @State private var natural: CGFloat = 0
    @State private var chrome: CGFloat = 0

    package var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.noticeVertical) {
            if let showing {
                header(for: showing)
                    .measuringChrome()

                scrollingBlock(for: showing)

                footer
            }
        }
        .padding(ChromeMetrics.horizontal)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .fill(ChromeColor.optionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .strokeBorder(ChromeColor.optionEdge)
        )
        .animation(.easeOut(duration: 0.16), value: at)
        .onPreferenceChange(AskChromeHeightKey.self) { chrome = $0 }
        .onPreferenceChange(AskQuestionHeightKey.self) { natural = $0 }
        .onChange(of: showing?.id, initial: true) { _, id in
            if reading != id { reading = id }
        }
    }

    /// A question taller than the card's share of the pane scrolls inside it,
    /// rather than growing until the conversation it was raised out of is off
    /// the screen. The heading and the send stay put around it: reading to the
    /// end of a long question is not the same as being ready to answer it, and
    /// the send scrolled off the bottom would make it so.
    private func scrollingBlock(for showing: AskPage) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                block(for: showing)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: AskQuestionHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .frame(height: AskCardHeight.questionHeight(columnHeight: columnHeight,
                                                        chrome: chromeHeight,
                                                        natural: max(natural, 1)))
            .scrollBounceBehavior(.basedOnSize)
            // A field opened at the foot of a long question opens below the
            // fold, so the caret would be somewhere off the card with the
            // keystrokes going into it.
            .onChange(of: focus) { _, field in
                guard let field else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(field, anchor: .bottom)
                }
            }
        }
        // Per page rather than per card, so a question turned to is read from
        // its own top and not from where the last one was left.
        .id(showing.id)
        .transition(.opacity)
    }

    /// Everything of the card that isn't the question: the rows measured around
    /// it, the gaps the stack puts between them, and the card's own padding. A
    /// run of nothing but permissions draws no footer and so has one gap rather
    /// than two — counted, since a gap charged for and not drawn is a strip of
    /// the card the question is kept out of for no reason.
    private var chromeHeight: CGFloat {
        let gaps = ChromeMetrics.noticeVertical * (hasFooter ? 2 : 1)
        return chrome + gaps + ChromeMetrics.horizontal * 2
    }

    private var pages: [AskPage] { AskPages.read(asks) }

    /// Found by name rather than counted to, because an ask answered from
    /// anywhere — the composer, a withdrawal, another window on the same host —
    /// takes its pages off the run and renumbers every page after them. Holding
    /// the number through that leaves the same index pointing at a different
    /// question, with nothing on screen to say the page moved underneath.
    private var at: Int {
        if let reading, let found = pages.firstIndex(where: { $0.id == reading }) { return found }
        return min(page, max(pages.count - 1, 0))
    }

    private var showing: AskPage? {
        pages.indices.contains(at) ? pages[at] : nil
    }

    // MARK: - Chrome

    private func header(for showing: AskPage) -> some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Text(showing.question == nil ? "Permission" : "Claude is asking")
                .font(ChromeType.badge)
                .foregroundStyle(.secondary)

            Spacer()

            if pages.count > 1 {
                Text("\(at + 1) of \(pages.count)")
                    .font(ChromeType.badge)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(at == 0)
                    .help("Previous question")

                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(at + 1 >= pages.count)
                    .help("Next question")
            }
        }
        .buttonStyle(.borderless)
        .font(ChromeType.control)
    }

    @ViewBuilder
    private func block(for showing: AskPage) -> some View {
        switch showing {
        case .question(_, let question):
            QuestionBlock(
                question: question,
                chosen: drafts[showing.id].picked,
                typed: field(showing.id, \.typed),
                isWritingOwn: drafts[showing.id].isWritingOwn,
                note: field(showing.id, \.note),
                isNoting: drafts[showing.id].isNoting,
                answerField: showing.id + "\u{0}answer",
                noteField: showing.id + "\u{0}note",
                focus: $focus,
                onPick: { pick(showing, question, $0) },
                onWriteOwn: { writeOwn(showing, question) },
                onAddContext: { addContext(showing) },
                onCommit: commit
            )

        case .permission(let askId, let request):
            PermissionBlock(request: request) { onAnswerPermission(askId, $0) }
        }
    }

    /// Nothing to draw on a run of permissions, which answer on their own
    /// buttons: no page to count through, and a send that could never light up.
    @ViewBuilder
    private var footer: some View {
        if hasFooter { footerRow }
    }

    private var hasFooter: Bool { pages.count > 1 || hasQuestions }

    private var hasQuestions: Bool { pages.contains { $0.question != nil } }

    private var footerRow: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            if pages.count > 1 {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, dot in
                    Button { move(to: index) } label: {
                        Circle()
                            .fill(colour(of: dot, at: index))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help(dot.question?.question ?? "Permission")
                }
            }

            Spacer()

            if hasQuestions { sendButton }
        }
        .measuringChrome()
    }

    /// The return is the send's only while nothing is being written into: in a
    /// field it means the end of the answer rather than the end of the run.
    @ViewBuilder
    private var sendButton: some View {
        let button = Button("Send", action: send).disabled(!isComplete)
        if focus == nil {
            button.keyboardShortcut(.return, modifiers: [])
        } else {
            button
        }
    }

    private func colour(of dot: AskPage, at index: Int) -> Color {
        if index == at { return ChromeColor.accent }
        return isAnswered(dot) ? ChromeColor.optionLabel.opacity(0.5) : ChromeColor.optionEdge
    }

    // MARK: - Moving

    private func move(_ step: Int) {
        move(to: at + step)
    }

    /// Return inside a field is the card's return, held back until the field has
    /// had it: it turns to the next question, or sends once there is none left
    /// to turn to. Nothing is said here about where the caret went — the field
    /// still holds it, and it is the field that says so.
    private func commit() {
        if at + 1 < pages.count {
            move(1)
        } else if isComplete {
            send()
        }
    }

    private func move(to destination: Int) {
        guard pages.indices.contains(destination) else { return }
        focus = nil
        page = destination
        reading = pages[destination].id
    }

    // MARK: - Answering

    private func pick(_ showing: AskPage, _ question: HostQuestion, _ label: String) {
        var chosen = drafts[showing.id].picked
        if question.multiSelect {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = [label]
            drafts[showing.id].isWritingOwn = false
        }
        drafts[showing.id].picked = chosen

        // A question taking several answers is not finished being answered by
        // one of them, so only a plain pick moves the page on.
        if !question.multiSelect { move(1) }
    }

    private func writeOwn(_ showing: AskPage, _ question: HostQuestion) {
        drafts[showing.id].isWritingOwn = true
        if !question.multiSelect { drafts[showing.id].picked = [] }
        focus = showing.id + "\u{0}answer"
    }

    private func addContext(_ showing: AskPage) {
        drafts[showing.id].isNoting = true
        focus = showing.id + "\u{0}note"
    }

    private func isAnswered(_ showing: AskPage) -> Bool {
        // A permission answers on its own buttons, so it is never what the send
        // is waiting for.
        guard showing.question != nil else { return true }
        if !drafts[showing.id].picked.isEmpty { return true }
        return drafts[showing.id].isWritingOwn && said(drafts[showing.id].typed) != nil
    }

    /// Every question has to be answered before the session can go on, so the
    /// send stays disabled rather than sending a partial set the model would
    /// have to guess at.
    private var isComplete: Bool {
        // `allSatisfy` is vacuously true on an empty run, and a question whose
        // options failed to parse is dropped — so without the first half this
        // sends an empty answer set, which the host reads as a plain allow.
        pages.contains { $0.question != nil } && pages.allSatisfy(isAnswered)
    }

    private func send() {
        guard isComplete else { return }

        var answers: [String: [String: HostAnswerValue]] = [:]
        var context: [String: [String: String]] = [:]

        for showing in pages {
            guard let question = showing.question else { continue }
            answers[showing.askId, default: [:]][question.question] = answer(to: showing, question)
            if let note = said(drafts[showing.id].note) {
                context[showing.askId, default: [:]][question.question] = note
            }
        }

        for (askId, answers) in answers {
            onAnswerQuestion(askId, answers, context[askId] ?? [:])
        }
    }

    private func answer(to showing: AskPage, _ question: HostQuestion) -> HostAnswerValue {
        let chosen = drafts[showing.id].picked
        var ordered = question.options.map(\.label).filter { chosen.contains($0) }
        if drafts[showing.id].isWritingOwn, let own = said(drafts[showing.id].typed) {
            ordered.append(own)
        }
        return question.multiSelect ? .many(ordered) : .one(ordered.first ?? "")
    }

    private func said(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func field(_ id: String, _ text: WritableKeyPath<AskDrafts.Entry, String>) -> Binding<String> {
        Binding(get: { drafts[id][keyPath: text] }, set: { drafts[id][keyPath: text] = $0 })
    }
}

private struct QuestionBlock: View {
    let question: HostQuestion
    let chosen: Set<String>
    @Binding var typed: String
    let isWritingOwn: Bool
    @Binding var note: String
    let isNoting: Bool
    let answerField: String
    let noteField: String
    @Binding var focus: String?

    let onPick: (String) -> Void
    let onWriteOwn: () -> Void
    let onAddContext: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            HStack(spacing: ChromeMetrics.badgeGap) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(ChromeType.badge)
                        .padding(.horizontal, ChromeMetrics.badgeHorizontal)
                        .padding(.vertical, ChromeMetrics.badgeVertical)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(ChromeColor.optionEdge)
                        )
                }
                if question.multiSelect {
                    Text("choose any")
                        .font(ChromeType.badge)
                        .foregroundStyle(.secondary)
                }
            }

            Text(question.question)
                .font(ChromeType.Reading.body)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                OptionRow(
                    option: option,
                    isChosen: chosen.contains(option.label),
                    onPick: { onPick(option.label) }
                )
            }

            ownAnswer
            context
        }
    }

    private var ownAnswer: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            Button(action: onWriteOwn) {
                Text("Something else…")
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(isWritingOwn ? ChromeColor.accent : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ChromeMetrics.controlGap)
                    // The box around this is drawn outside the button, so
                    // without a shape of its own only the words are clickable.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isWritingOwn
                            ? ChromeColor.accentTint.opacity(ChromeMetrics.optionTint)
                            : ChromeColor.optionFill
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isWritingOwn ? ChromeColor.accent : ChromeColor.optionEdge,
                        style: StrokeStyle(lineWidth: ChromeMetrics.hairline, dash: [3, 2])
                    )
            )

            if isWritingOwn {
                CardField(
                    text: $typed,
                    prompt: "Your answer",
                    field: answerField,
                    focus: $focus,
                    onCommit: onCommit
                )
            }
        }
    }

    @ViewBuilder
    private var context: some View {
        if isNoting {
            CardField(
                text: $note,
                prompt: "Anything to add?",
                field: noteField,
                focus: $focus,
                onCommit: onCommit
            )
        } else {
            Button("Add context", action: onAddContext)
                .buttonStyle(.borderless)
                .font(ChromeType.badge)
                .foregroundStyle(.secondary)
        }
    }
}

/// The same editor the composer under the card is, for the same reason it is
/// there: an answer in your own words is prose, and SwiftUI's own field will not
/// take a typed newline on macOS — return ends the edit whether or not anything
/// is listening for it, so an answer could only ever be one paragraph long.
/// Here as there, return commits and shift-return breaks the line.
private struct CardField: View {
    @Binding var text: String
    let prompt: String
    let field: String
    @Binding var focus: String?
    let onCommit: () -> Void

    @State private var height: CGFloat = 0

    private static var minHeight: CGFloat {
        ComposerField.lineHeight + ChromeMetrics.fieldVertical * 2
    }

    /// Six lines of answer, past which the field scrolls rather than pushing the
    /// question it belongs to off the top of the card.
    private static var maxHeight: CGFloat {
        ComposerField.lineHeight * 6 + ChromeMetrics.fieldVertical * 2
    }

    var body: some View {
        ComposerField(
            text: $text,
            placeholder: prompt,
            onSend: { onCommit() },
            // Escape is the pane's, and there is nothing here for it to undo.
            onCancel: {},
            onHeightChange: { height = $0 },
            scrollsPast: Self.maxHeight,
            // Only where the card says the caret belongs: this field is drawn
            // again on every turn back to its page, and would take the caret
            // each time from a move made to read rather than to write.
            claimsFocus: focus == field,
            onFocusChange: { taken in
                // The responder can change inside a SwiftUI update, and state
                // set from in there is state set while it is being read.
                DispatchQueue.main.async {
                    if taken { focus = field } else if focus == field { focus = nil }
                }
            }
        )
        .frame(height: min(max(height, Self.minHeight), Self.maxHeight))
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    focus == field ? ChromeColor.accent : ChromeColor.optionEdge,
                    lineWidth: ChromeMetrics.hairline
                )
        )
        .id(field)
    }
}

private struct OptionRow: View {
    let option: HostQuestion.Option
    let isChosen: Bool
    let onPick: () -> Void

    @State private var previewHeight = AskPreview.placeholder

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                Text(option.label)
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(ChromeColor.optionLabel)

                if let detail = option.detail {
                    Text(detail)
                        .font(ChromeType.Reading.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let preview = option.preview {
                    AskPreview(html: preview) { previewHeight = $0 }
                        .frame(height: min(previewHeight, AskPreview.maxHeight))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ChromeMetrics.controlGap)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isChosen ? ChromeColor.accentTint.opacity(ChromeMetrics.optionTint) : ChromeColor.optionFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isChosen ? ChromeColor.accent : ChromeColor.optionEdge)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionBlock: View {
    let request: HostPermissionRequest
    let onPick: (HostAskOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            Text(request.title)
                .font(ChromeType.Reading.headingSmall)

            if let screen = request.screen {
                DrivingLine(screen: screen)
            }

            if let summary = request.fullSummary {
                SubjectPanel(text: summary, emphasis: request.screen?.line)
            }

            HStack(spacing: ChromeMetrics.controlGap) {
                ForEach(request.options) { option in
                    Button(option.name) { onPick(option) }
                        .buttonStyle(.bordered)
                        .tint(option.kind.isAllow ? ChromeColor.accent : nil)
                }
            }
            .padding(.top, ChromeMetrics.lineGap)
        }
    }
}

/// What is being agreed to, in full and wrapped rather than cut to a line. It is
/// bounded here rather than left to the card's own scroll because the buttons
/// that answer it are inside that scroll: past a certain length the decision
/// itself would be below the fold.
private struct SubjectPanel: View {
    let text: String
    /// A line of `text` to pick out, the way the driving line is picked out of
    /// a takeover's command.
    var emphasis: String? = nil

    @State private var natural: CGFloat = 0

    private static var maxHeight: CGFloat {
        ChromeType.Reading.monoLine * CGFloat(ChromeMetrics.previewMaxLines)
    }

    private var attributed: AttributedString {
        var whole = AttributedString(text)
        guard let emphasis, !emphasis.isEmpty, let range = whole.range(of: emphasis) else {
            return whole
        }
        whole[range].backgroundColor = ChromeColor.screenDriveFill
        whole[range].font = ChromeType.Reading.mono.weight(.bold)
        return whole
    }

    var body: some View {
        ScrollView {
            Text(attributed)
                .font(ChromeType.Reading.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: AskSubjectHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: min(max(natural, 1), Self.maxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(AskSubjectHeightKey.self) { natural = $0 }
    }
}

/// The one line of the command that takes the pointer or keyboard, out from
/// under the rest of it. The command a takeover asks about can be a script
/// with that line at the very bottom — the one that found this was a heredoc
/// whose mark sat below the fold of the panel — and the panel's first lines
/// then say nothing about the screen at all.
private struct DrivingLine: View {
    let screen: HostScreenDrive

    private var attributed: AttributedString {
        var line = AttributedString(screen.line)
        if let range = line.range(of: screen.match) {
            line[range].foregroundColor = ChromeColor.screenDrive
        }
        return line
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.inlineGap) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(ChromeColor.screenDrive)
            Text(attributed)
                .font(ChromeType.Reading.mono.weight(.bold))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ChromeMetrics.inlineGap)
        .padding(.vertical, ChromeMetrics.lineGap)
        .background(
            ChromeColor.screenDriveFill,
            in: RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner / 2, style: .continuous)
        )
    }
}

private struct AskSubjectHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension HostAskOption: Identifiable {
    public var id: String { optionId }
}

/// What the question would be given its head, off the content inside the scroll
/// view rather than the scroll view itself, which is the height being decided.
private struct AskQuestionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The rows the question scrolls under, added up: the card has two of them and
/// one comes and goes.
private struct AskChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    func measuringChrome() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: AskChromeHeightKey.self, value: proxy.size.height)
            }
        )
    }
}
