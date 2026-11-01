import DexCore
import SwiftUI

package struct TranscriptPane: View {
    let attachment: PaneAttachment

    /// Held by the column, which has a composer to put under this that answers
    /// for what has been said so far.
    let feed: TranscriptFeed

    /// What the list row says about the session. The transcript on its own goes
    /// quiet while a reply is being written, so the pane can't tell working from
    /// finished by reading the file alone.
    let isWorking: Bool

    /// The host's word that the CLI is summarising the conversation. Nothing is
    /// written to the transcript for the whole stretch, so the working line is
    /// the only thing on screen that can say what the wait is for.
    var isCompacting = false

    /// Whether anything is still there to write a result — the session's pid.
    /// Separate from `isWorking` on purpose: that one is about whether to draw a
    /// spinner and goes quiet on an idle session, and a call left pending by a
    /// session that is merely idle has not been abandoned.
    let isLive: Bool

    /// Where this session's transcript is read from.
    let source: any TranscriptSource

    /// The plan the session is holding out, if it is holding one out. Answered
    /// here rather than in the card under the composer: the decision is about
    /// the plan, and the plan is up here.
    var planDecision: PlanDecision?

    /// The agents the host says are still out, keyed by the call that spawned
    /// each. The task id doubles as the agent's transcript name (pinned by
    /// `agent-file-probe`), and while a foreground agent runs it is the only
    /// name there is — the transcript's own arrives with the result. Empty for
    /// a session nothing is hosting, which reads exactly as before.
    var runningAgents: [String: String] = [:]

    /// What has been said to this session and not yet read back out of its
    /// transcript, drawn at the end where it will land. See `SessionPane.saying`
    /// for why the pane holds it rather than waiting for the file.
    var saying: [SessionPane.Said] = []

    /// What the reader has said to this session, counted by the composer. The
    /// transcript takes it as the word that they are at the end of the
    /// conversation — the one thing the pane's own geometry can't tell it.
    var sends: Int = 0

    /// The running call the reader last asked to see, from the strip under the
    /// pane.
    var revealing: TranscriptReveal?

    var places: TranscriptPlaces?

    /// Puts an agent's conversation up over this one.
    var openAgent: OpenAgentAction?

    package init(
        attachment: PaneAttachment,
        feed: TranscriptFeed,
        isWorking: Bool,
        isCompacting: Bool = false,
        isLive: Bool,
        source: any TranscriptSource,
        planDecision: PlanDecision? = nil,
        runningAgents: [String: String] = [:],
        saying: [SessionPane.Said] = [],
        sends: Int = 0,
        revealing: TranscriptReveal? = nil,
        places: TranscriptPlaces? = nil,
        openAgent: OpenAgentAction? = nil
    ) {
        self.attachment = attachment
        self.feed = feed
        self.isWorking = isWorking
        self.isCompacting = isCompacting
        self.isLive = isLive
        self.source = source
        self.planDecision = planDecision
        self.runningAgents = runningAgents
        self.saying = saying
        self.sends = sends
        self.revealing = revealing
        self.places = places
        self.openAgent = openAgent
    }

    @State private var flashed: TranscriptReveal?

    /// Each item's hash, kept while the item is unchanged. A tool row carries
    /// everything its call returned, and hashing that afresh on every redraw
    /// of every row was a tenth of a switch.
    @State private var hashes = ItemHashes()


    /// One per pane, and held here because a selection runs through the whole
    /// conversation rather than belonging to any of the views that draw it.
    @State private var selection = TranscriptSelection()

    /// The conversation as read, with anything the host says is still going
    /// stood back out of the runs it was folded into — a backgrounded command
    /// comes back the moment it starts, so the file has it as finished work.
    private var items: [TranscriptItem] {
        TranscriptFlow.marking(
            feed.items,
            running: Set(runningAgents.keys),
            agents: runningAgents
        )
    }

    /// Read off the file rather than off the marked items on purpose: this
    /// stands for what is going on at the end of the conversation, and a
    /// backgrounded command is a row somewhere back up it. Asked the other way,
    /// one long command silences the line below for every turn it outlives.
    private var running: [ToolCall] { TranscriptFlow.waitedOn(in: feed.items) }

    /// The prompt stands in for the conversation only while one is still coming.
    /// A session that opened a transcript and then died without writing a turn
    /// would otherwise spin on "Starting…" for as long as you left it there.
    private var opening: String? {
        guard feed.items.isEmpty, let prompt = attachment.openingPrompt else { return nil }

        switch feed.phase {
        case .looking, .opening: return prompt
        case .reading: return isWorking ? prompt : nil
        case .unavailable: return nil
        }
    }

    package var body: some View {
        Group {
            if !feed.items.isEmpty {
                conversation
                    .onAppear { Timing.log("conversation appeared", feed: feed) }
            } else if let opening {
                OpeningTurn(prompt: opening)
            } else {
                TranscriptPlaceholder(phase: feed.phase
                )
                    .id("\(attachment.id)#\(attachment.sessionID ?? "")")
                    .onAppear { Timing.log("placeholder appeared", feed: feed) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneGround(.textBackgroundColor)
        // Keyed on the transcript id as well as the session: a pane attached
        // before the SDK opened the file adopts the id later, and the feed has
        // to start over to use it.
        .task(id: "\(attachment.id)#\(attachment.sessionID ?? "")") {
            await feed.run(sessionID: attachment.sessionID, source: source)
        }
    }

    private var conversation: some View {
        TranscriptColumn(
            rows: rows,
            sends: sends,
            transcript: feed.heardOf,
            places: places,
            reveal: revealing
        )
        .onChange(of: revealing) { _, reveal in
            if let reveal { flashed = reveal }
        }
        .task(id: flashed) {
            guard flashed != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            withAnimation(.easeOut(duration: 0.6)) { flashed = nil }
        }
        .environment(\.subagentScope, feed.subagents.map {
            SubagentScope(directory: $0, source: source)
        })
        .environment(\.runningAgents, runningAgents)
        .environment(\.openAgent, openAgent)
        .environment(\.transcriptSelection, selection)
        // The selection watches for the click that puts it down, and the
        // pane going is one — nothing else would take the watch off.
        .onDisappear { selection.clear() }
    }

    /// The conversation as the column draws it, row by row, with what the pane
    /// stands in for at the end: what was said and not yet written, what the
    /// session took and has not written, the working line, and the queue.
    ///
    /// A message that started the turn goes over the work, where the file will
    /// put it; one sent into a turn already going goes under, with the queue it
    /// is about to join, since the session has it without having got to it.
    /// Numbered in the order drawn, not the order sent, since a copy is
    /// assembled by number.
    var rows: [ColumnRow] {
        var rows: [ColumnRow] = []
        let items = items
        rows.reserveCapacity(items.count + saying.count + feed.queued.count + 2)

        for (index, item) in items.enumerated() {
            let lead = (index > 0 ? ChromeMetrics.itemGap : 0) + Self.lead(above: item, at: index)
            let native = NativeRow.of(item, isLive: isLive)
            var content = Hasher()
            if let native {
                content.combine(native)
            } else {
                content.combine(hashes.hash(item))
                if case .plan(let plan) = item, planDecision?.planID == plan.id { content.combine(true) }
            }
            content.combine(lead)
            let isFlashed = flashed?.itemID == item.id
            rows.append(ColumnRow(
                id: item.id,
                content: content.finalize(),
                place: index,
                view: AnyView(
                    view(for: item)
                        .background { RevealMark(isShown: isFlashed) }
                        .padding(.top, lead)
                ),
                native: native,
                lead: lead
            ))
        }

        func turn(_ id: String, _ text: String, place: Int, waiting: Bool = false, _ view: some View) {
            var content = Hasher()
            content.combine(text)
            content.combine(waiting)
            content.combine(rows.isEmpty)
            rows.append(ColumnRow(
                id: id,
                content: content.finalize(),
                place: place,
                view: AnyView(view.padding(.top, rows.isEmpty ? 0 : ChromeMetrics.itemGap + ChromeMetrics.turnLead))
            ))
        }

        let starting = saying.filter { !$0.intoTurn }
        let handed = saying.filter { $0.intoTurn }
        for (index, said) in starting.enumerated() {
            turn("said:\(said.id)", said.text, place: Self.saidPlace + index, Prompt(text: said.text))
        }

        // A message the session took off its queue and has not written yet.
        // The stand-in came down when it was queued and the queue row went
        // when it was taken, so without this a `/compact` is on screen nowhere
        // for the whole compaction. Only while the session is working: a slash
        // command the CLI answers with no turn would otherwise stand here
        // until the next record.
        if isWorking {
            for (index, message) in feed.taken.enumerated() {
                turn("taken:\(message.id)", message.text, place: Self.takenPlace + index, Prompt(text: message.text))
            }
        }

        // A call that is out is already a row of its own, with a clock on it —
        // this is for the stretches the transcript has no line for at all.
        if isWorking, running.isEmpty {
            let label = isCompacting ? "Compacting…" : "Thinking…"
            var content = Hasher()
            content.combine(label)
            rows.append(ColumnRow(
                id: "working",
                content: content.finalize(),
                place: Self.workingPlace,
                view: AnyView(WorkingLine(label: label).padding(.top, rows.isEmpty ? 0 : ChromeMetrics.itemGap))
            ))
        }

        for (index, said) in handed.enumerated() {
            turn(
                "said:\(said.id)", said.text, place: Self.handedPlace + index,
                Prompt(text: said.text)
            )
        }

        // A place of their own past the end rather than one counted off the
        // transcript: a turn landing while one of these is selected would take
        // the path the selection is holding, and the highlight would jump to it.
        for (index, message) in feed.queued.enumerated() {
            turn(
                "queued:\(message.id)", message.text, place: Self.queuedPlace + index, waiting: true,
                Group {
                    // A peer's message waits in the same queue, and only its
                    // text says whose it is.
                    if let (name, body) = TranscriptText.peerMessage(parsing: message.text) {
                        PeerExchange(
                            message: PeerMessage(id: message.id, direction: .inbound, name: name, body: body)
                        )
                        .opacity(ChromeMetrics.waitingPrompt)
                    } else {
                        Prompt(text: message.text, isWaiting: true)
                    }
                }
            )
        }
        return rows
    }

    private func view(for item: TranscriptItem) -> some View {
        TranscriptItemView(item: item, isLive: isLive, planDecision: planDecision)
    }

    /// Past any conversation, so a message the pane stands in for keeps the
    /// place a selection found it at however many turns land under it. One
    /// band per kind, in the order `rows` draws them.
    private static let saidPlace = 1_000_000
    private static let takenPlace = 2_000_000
    private static let workingPlace = 3_000_000
    private static let handedPlace = 4_000_000
    private static let queuedPlace = 5_000_000

    /// One turn is a prompt and everything it set off, so the space that says a
    /// new one has started goes above the prompt rather than between every item.
    private static func lead(above item: TranscriptItem, at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch item {
        case .prompt, .compaction: return ChromeMetrics.turnLead
        case .image(let image) where image.startsTurn: return ChromeMetrics.turnLead
        case .peer(let message) where message.direction == .inbound: return ChromeMetrics.turnLead
        default: return 0
        }
    }
}

package struct TranscriptReveal: Equatable {
    let itemID: String

    /// So asking for the same row twice still counts as asking.
    private let asked = UUID()

    init(call: ToolCall) {
        itemID = TranscriptItem.activeTool(call).id
    }
}

private struct RevealMark: View {
    let isShown: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: ChromeMetrics.selectionCorner, style: .continuous)
            .fill(ChromeColor.accentTint.opacity(ChromeMetrics.attachedTint))
            .padding(.horizontal, -ChromeMetrics.selectionInset)
            .padding(.vertical, -ChromeMetrics.selectionVertical)
            .opacity(isShown ? 1 : 0)
            // Its own, since the row it marks is drawn in a cell of the
            // column's, out of reach of the pane's animation: on at once,
            // fading off.
            .animation(isShown ? nil : .easeOut(duration: 0.6), value: isShown)
    }
}

/// All the pane knows about a session that hasn't written a transcript yet: what
/// it was asked to do, and that it is on its way. Laid out as the first turn of
/// the conversation it becomes, so nothing moves when the real one arrives.
struct OpeningTurn: View {
    let prompt: String

    /// Its own, since this stands in for a conversation that has no transcript
    /// yet — what is on screen is still worth being able to take.
    @State private var selection = TranscriptSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChromeMetrics.itemGap) {
                Prompt(text: prompt)
                    .selectionIndex(0)
                WorkingLine(label: "Starting…")
            }
            .frame(maxWidth: ChromeMetrics.readingMeasure, alignment: .leading)
            .padding(ChromeMetrics.readingInset)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(SelectionMargin())
        }
        .lineSpacing(ChromeMetrics.readingLead)
        .environment(\.transcriptSelection, selection)
        .onDisappear { selection.clear() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TranscriptPlaceholder: View {
    let phase: TranscriptFeed.Phase

    /// A switch to a session already on disk finds and reads its file in a
    /// fraction of a second, and a glyph drawn for that stretch is a flash
    /// between two conversations. So a pane still looking or opening draws
    /// nothing until it has been at it for a beat.
    @State private var shown = false

    private static let patience = Duration.milliseconds(400)

    var body: some View {
        VStack(spacing: ChromeMetrics.inlineGap) {
            if shown || settled {
                Image(systemName: glyph)
                    .font(ChromeType.displayGlyph)
                    .foregroundStyle(.quaternary)
                Text(label)
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: Self.patience)
            shown = true
        }
    }

    /// Said at once: no transcript is not a stretch that ends on its own.
    private var settled: Bool {
        return phase == .unavailable
    }

    private var glyph: String {
        settled ? "questionmark.bubble" : "bubble.left.and.bubble.right"
    }

    private var label: String {
        switch phase {
        case .looking: return "Looking for the transcript…"
        case .opening: return "Reading the transcript…"
        case .reading: return "Nothing said yet"
        case .unavailable: return "No transcript on disk for this session"
        }
    }
}

/// Work with nothing else in the transcript to stand for it: a session on its
/// way to its first turn, or one thinking between calls. Named by the caller,
/// since those are two different waits.
package struct WorkingLine: View {
    let label: String

    package init(label: String) {
        self.label = label
    }

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
            RunningGlyph()
            Text(label)
                .font(ChromeType.Reading.meta)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A spinner in a tool glyph's place. Laid out as the glyph it stands in for,
/// so it takes that glyph's baseline rather than sitting high on its own.
private struct RunningGlyph: View {
    var symbol = "circle"

    var body: some View {
        Image(systemName: symbol)
            .font(ChromeType.Reading.icon)
            .hidden()
            .overlay { WorkingSpinner(color: Presentation.color(for: .running)) }
            .frame(width: ChromeMetrics.toolGlyphSlot, alignment: .leading)
    }
}

/// A call's own clock, counted up while it runs. The transcript is written to
/// when something happens, so a subagent that has been going four minutes writes
/// nothing in that time — the clock has to keep itself.
struct RunningClock: View {
    let since: Date

    var font: Font = ChromeType.Reading.meta

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Format.elapsed(context.date.timeIntervalSince(since)))
                .font(font)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// What you typed, set off from what came back: a tinted card held to the right
/// of the column, hugging its own width the way the replies never do.
package struct Prompt: View {
    let text: String

    /// Sent, but still in the session's queue. Drawn faintly so that what has
    /// landed and what hasn't don't read as the same thing.
    var isWaiting = false

    package init(text: String, isWaiting: Bool = false) {
        self.text = text
        self.isWaiting = isWaiting
    }

    package var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            ProseText(source: .plain(text), face: ProseFace(weight: .medium), hugsWidth: true)
                .selectionIndex(0)
                .padding(.vertical, ChromeMetrics.cardVertical)
                .padding(.horizontal, ChromeMetrics.cardHorizontal)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                        .fill(ChromeColor.accentTint.opacity(ChromeMetrics.promptTint))
                        .allowsHitTesting(false)
                )
                .opacity(isWaiting ? ChromeMetrics.waitingPrompt : 1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, ChromeMetrics.promptIndent)
    }
}

/// An image pasted into a prompt, named under it rather than drawn.
private struct ImageLine: View {
    let image: TranscriptImage

    var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "photo")
                .font(ChromeType.Reading.icon)
            Text(image.label)
                .font(ChromeType.Reading.meta)
        }
        .foregroundStyle(.tertiary)
        .selectableWhole(image.label)
        .selectionIndex(0)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One message of a conversation the session is having with someone else —
/// another session, or an agent of its own. Neither side of it is yours, so it
/// takes neither side of the column: inset under a rule the way a quote is, a
/// neutral card instead of the accent one, and a line above naming who it is
/// from or to. The name is set in mono where it is an address (`kestrel-9d`),
/// since that is what you'd type to reach them, and in the meta face where it
/// is a subagent's brief.
private struct PeerExchange: View {
    let message: PeerMessage

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            RoundedRectangle(cornerRadius: ChromeMetrics.promptRule / 2, style: .continuous)
                .fill(.quaternary)
                .frame(width: ChromeMetrics.promptRule)
            VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
                HStack(spacing: ChromeMetrics.iconGap) {
                    Image(systemName: isInbound ? "arrow.turn.down.left" : "arrow.turn.up.right")
                        .font(ChromeType.Reading.icon)
                    Text(label)
                        .font(ChromeType.Reading.meta)
                    Text(who)
                        .font(isAddress ? ChromeType.Reading.mono : ChromeType.Reading.meta)
                        .help(message.agent != nil ? message.address ?? "" : "")
                }
                .foregroundStyle(.tertiary)

                report
                    .padding(.vertical, ChromeMetrics.cardVertical)
                    .padding(.horizontal, ChromeMetrics.cardHorizontal)
                    .background(
                        RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                            .fill(Color.primary.opacity(ChromeMetrics.optionTint))
                            .allowsHitTesting(false)
                    )

                if let failure = message.failure {
                    Text(failure)
                        .font(ChromeType.Reading.meta)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, ChromeMetrics.glyphGap)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A report is written to be read, and an agent's runs to headings and
    /// lists; a message between sessions is a line or two and stays plain.
    @ViewBuilder private var report: some View {
        if message.isHandback {
            MarkdownText(blocks: Markdown.blocks(in: message.body))
        } else {
            ProseText(source: .plain(message.body), hugsWidth: true)
                .selectionIndex(0)
        }
    }

    private var isInbound: Bool { message.direction == .inbound }

    private var label: String {
        if message.isHandback { return "report to" }
        return isInbound ? "from" : "to"
    }

    /// A hand-back is the agent answering whoever set it going, and the tool
    /// names nobody: there is only one caller to answer.
    private var who: String {
        message.agent ?? message.name ?? (message.isHandback ? "caller" : "another session")
    }

    /// Mono is for something you'd type to reach them. One of the session's
    /// own agents is named for the work it was sent to do, which is a
    /// description, not an address — the address goes in the tooltip.
    private var isAddress: Bool { message.agent == nil && message.name != nil && !message.isHandback }
}

/// Claude Code's own line where the model's turn would be. Set apart from the
/// reply column because the words are the CLI's: read as prose, "You've hit your
/// session limit" is a sentence the model appears to have said about itself.
private struct Notice: View {
    let notice: TranscriptNotice

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.iconGap) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(ChromeType.Reading.icon)
                .foregroundStyle(tint)
                .frame(width: ChromeMetrics.toolGlyphSlot, alignment: .leading)
                .padding(.top, ChromeMetrics.glyphTopInset)
            Text(notice.text)
                .font(ChromeType.Reading.meta)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ChromeMetrics.cardVertical)
        .padding(.horizontal, ChromeMetrics.cardHorizontal)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .fill(tint.opacity(ChromeMetrics.promptTint))
                .allowsHitTesting(false)
        )
        .selectableWhole(notice.text)
        .selectionIndex(0)
    }

    private var tint: Color { notice.isError ? .red : .secondary }
}

/// Prose the server summarised on its way out of a turn. It is the assistant
/// speaking — terminal Claude Code draws it with the assistant's own bullet —
/// so it is drawn open, as speech, not folded behind a Thought.
///
/// Set at the same weight as the prose around it. Terminal Claude Code dims
/// both the text and the word `summarized` under it
/// (`AssistantNarrationSummaryMessage`), and the app followed that at first,
/// but a paragraph the pane is meant to be read is worth reading — the label
/// carries the caveat instead. It stays grey, and it goes above rather than
/// below, since a summary's claims can be wrong about their own turn (one
/// claimed to have given two fixes in a turn that said nothing at all) and
/// that is worth knowing before the text rather than after it.
///
/// Laid out as one run rather than through `MarkdownText`: every one sampled
/// is a single paragraph — no headings, no lists, no
/// line breaks at all, 402 characters at the longest — so there is nothing for
/// the block-by-block layout to separate. Inline code is kept, since a quarter
/// of them use it. See `NarrationSignature`.
private struct Narration: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
            Text("summarized")
                .font(ChromeType.Reading.meta.italic())
                .foregroundStyle(.tertiary)
            ProseText(source: .markdown(blocks))
                .selectionIndex(0)
        }
    }
}

private struct Thinking: View {
    let id: String
    let text: String

    private var isExpanded: Bool { RowExpansions.shared.isExpanded("think:\(id)") }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
            Button {
                RowExpansions.shared.toggle("think:\(id)")
            } label: {
                HStack(spacing: ChromeMetrics.iconGap) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(ChromeType.Reading.icon)
                    Text("Thought")
                        .font(ChromeType.Reading.meta.italic())
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ProseText(
                    source: .plain(text),
                    face: ProseFace(size: 13, italic: true, tint: .secondary)
                )
                .selectionIndex(0)
                .padding(.leading, ChromeMetrics.glyphGap)
            }
        }
    }
}

/// A stretch of tool calls with nothing said in between. Reading past it should
/// cost one line, so it opens closed — but a failure inside still shows.
/// Where this session's agents write their transcripts, handed down so a
/// delegating row can open one. Nil for a pane whose transcript hasn't been
/// found yet, which is the same as a session that has delegated nothing.
/// Where a session's agents write, and what can read them.
struct SubagentScope {
    let directory: String
    let source: any TranscriptSource
}

private struct SubagentScopeKey: EnvironmentKey {
    static let defaultValue: SubagentScope? = nil
}

/// How many delegations deep this view already is. Agents nest to three by
/// default, so the row stops offering to open one further down than the CLI
/// will spawn.
private struct SubagentDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

/// What the host knows each still-running agent as, keyed by the call that
/// spawned it. Handed to every row rather than resolved per row: a nested
/// delegating row is drawn by the same view, and its call can be in this map
/// too.
private struct RunningAgentsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

/// Puts an agent's conversation up over the transcript. Nil where there is
/// nothing to put it over, and a delegating row opens onto its input and result.
package struct OpenAgentAction: Sendable {
    let open: @MainActor @Sendable (ToolCall, String) -> Void

    @MainActor func callAsFunction(_ call: ToolCall, agentID: String) { open(call, agentID) }
}

private struct OpenAgentKey: EnvironmentKey {
    static let defaultValue: OpenAgentAction? = nil
}

extension EnvironmentValues {
    var subagentScope: SubagentScope? {
        get { self[SubagentScopeKey.self] }
        set { self[SubagentScopeKey.self] = newValue }
    }

    var subagentDepth: Int {
        get { self[SubagentDepthKey.self] }
        set { self[SubagentDepthKey.self] = newValue }
    }

    var runningAgents: [String: String] {
        get { self[RunningAgentsKey.self] }
        set { self[RunningAgentsKey.self] = newValue }
    }

    var openAgent: OpenAgentAction? {
        get { self[OpenAgentKey.self] }
        set { self[OpenAgentKey.self] = newValue }
    }
}

/// The one place a transcript item becomes a view, so that a subagent's turns
/// read exactly like the conversation that spawned them rather than like a log
/// of it.
package struct TranscriptItemView: View {
    let item: TranscriptItem

    /// Whether the session is still there to answer a call, which is the only
    /// thing that tells one still running from one killed holding the line. The
    /// file looks the same either way: since CLI v2.1.236 a SIGTERM'd session
    /// writes no interruption record, so the last call simply never comes back.
    var isLive = false

    /// The conversation's own, and only its own: a subagent's transcript is
    /// drawn by this too, and nothing in there is being asked about.
    var planDecision: PlanDecision?

    package init(item: TranscriptItem, isLive: Bool = false, planDecision: PlanDecision? = nil) {
        self.item = item
        self.isLive = isLive
        self.planDecision = planDecision
    }

    package var body: some View {
        switch item {
        case .prompt(let prose):
            Prompt(text: prose.text)
        case .image(let image):
            ImageLine(image: image)
        case .peer(let message):
            PeerExchange(message: message)
        case .reply(let reply):
            MarkdownText(blocks: reply.blocks)
        case .thinking(let prose):
            Thinking(id: prose.id, text: prose.text)
        case .narration(let reply):
            Narration(blocks: reply.blocks)
        case .question(let call):
            QuestionCard(call: call)
        case .plan(let plan):
            // By name, not by whether the plan is waiting: a session that died
            // before hearing back leaves a card that waits for good, and the
            // buttons belong to the plan being asked about now.
            PlanCard(plan: plan, decision: planDecision?.planID == plan.id ? planDecision : nil)
        case .toolRun(let run):
            ToolRun(run: run)
        case .notice(let notice):
            Notice(notice: notice)
        case .activeTool(let call):
            ToolCallRow(call: call, isRunning: isLive)
        case .compaction(let compaction):
            CompactionDivider(compaction: compaction)
        }
    }
}

/// Where the CLI compacted the conversation: a rule across the column with the
/// before and after sizes on it, and the summary it handed the model folded
/// under a disclosure. The summary is thousands of words and was typed by
/// nobody, so it opens closed.
private struct CompactionDivider: View {
    let compaction: Compaction

    private var isExpanded: Bool { RowExpansions.shared.isExpanded("compact:\(compaction.id)") }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
            HStack(spacing: ChromeMetrics.iconGap) {
                rule
                Text(label)
                    .font(ChromeType.Reading.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                rule
            }

            if let summary = compaction.summary {
                Button {
                    RowExpansions.shared.toggle("compact:\(compaction.id)")
                } label: {
                    HStack(spacing: ChromeMetrics.iconGap) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(ChromeType.Reading.icon)
                        Text("Summary")
                            .font(ChromeType.Reading.meta.italic())
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    MarkdownText(blocks: Markdown.blocks(in: summary))
                        .selectionIndex(0)
                        .padding(.leading, ChromeMetrics.glyphGap)
                }
            }
        }
        .padding(.vertical, ChromeMetrics.cardVertical)
    }

    private var rule: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        var words = compaction.trigger == "auto" ? "Compacted automatically" : "Compacted"
        if let pre = compaction.preTokens, let post = compaction.postTokens {
            words += " · \(Format.compact(pre)) to \(Format.compact(post)) ctx"
        } else if let post = compaction.postTokens {
            words += " · \(Format.compact(post)) ctx"
        }
        return words
    }
}

private struct ToolRun: View {
    let run: TranscriptToolRun

    private var isExpanded: Bool { RowExpansions.shared.isExpanded("run:\(run.id)") }

    var body: some View {
        if let only = run.calls.first, run.isSingle {
            ToolCallRow(call: only)
        } else {
            VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
                Button {
                    RowExpansions.shared.toggle("run:\(run.id)")
                } label: { header }
                    .buttonStyle(.plain)
                    .selectableWhole("\(run.sentence) · \(run.calls.count) calls")
                    .selectionIndex(0)

                if isExpanded {
                    VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
                        ForEach(Array(run.calls.enumerated()), id: \.element.id) { index, call in
                            ToolCallRow(call: call)
                                .selectionIndex(index + 1)
                        }
                    }
                    .padding(.leading, ChromeMetrics.toolGlyphSlot + ChromeMetrics.iconGap)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(ChromeType.Reading.icon)
                .foregroundStyle(.tertiary)
                .frame(width: ChromeMetrics.toolGlyphSlot, alignment: .leading)

            Text(run.sentence)
                .font(ChromeType.Reading.meta.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(NativeRow.tally(count: run.calls.count, pending: run.isPending))
                .font(ChromeType.Reading.meta)
                .foregroundStyle(.tertiary)
                .fixedSize()

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Kept out of the collapsed runs: what Claude asked and what you picked is
/// conversation, not machinery.
private struct QuestionCard: View {
    let call: ToolCall

    private var asked: [AskedQuestion] { call.askedQuestions }
    private var response: String? { call.result?.response }

    var body: some View {
        if asked.isEmpty {
            ToolCallRow(call: call)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            Image(systemName: "questionmark.bubble")
                .font(ChromeType.Reading.icon)
                .foregroundStyle(.tertiary)
                .padding(.top, ChromeMetrics.glyphTopInset)

            VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
                ForEach(Array(asked.enumerated()), id: \.offset) { index, question in
                    AskedQuestionBlock(
                        key: "asked:\(call.id)#\(index)",
                        question: question,
                        isPending: call.isPending,
                        wasRespondedTo: response != nil
                    )
                }
                if let response {
                    Text("→ \(response)")
                        .font(ChromeType.Reading.body)
                        .foregroundStyle(ChromeColor.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, ChromeMetrics.cardVertical)
        .padding(.horizontal, ChromeMetrics.cardHorizontal)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .fill(Color.primary.opacity(ChromeMetrics.detailTint))
                .allowsHitTesting(false)
        )
        .fixedSize(horizontal: false, vertical: true)
        .selectableWhole(Self.plain(asked, response: response))
    }

    /// What the card is worth having on the clipboard: what was asked and what
    /// you said, without the options you didn't pick.
    private static func plain(_ asked: [AskedQuestion], response: String?) -> String {
        let questions = asked.map { question in
            [question.question, question.answer.map { "→ \($0)" }, question.note]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        return (questions + [response.map { "→ \($0)" }].compactMap { $0 })
            .joined(separator: "\n\n")
    }
}

/// A plan the session is waiting on, and the buttons that answer it — held
/// together because the plan is what they decide, and a plan runs longer than a
/// screen. Answered anywhere else you would be agreeing to something scrolled
/// out of sight.
package struct PlanDecision {
    /// The plan card these belong under, by the id of the call that proposed it.
    let planID: String
    let options: [HostAskOption]
    let choose: (HostAskOption) -> Void
}

/// The plan itself, where the conversation it belongs to is. Open, because
/// reading it is the point of asking for one; foldable, because scrolling back
/// past an old one shouldn't cost a page.
private struct PlanCard: View {
    let plan: PlanProposal
    var decision: PlanDecision?

    private var isExpanded: Bool { RowExpansions.shared.isExpanded("plan:\(plan.id)", opensExpanded: true) }

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            Image(systemName: "list.bullet.clipboard")
                .font(ChromeType.Reading.icon)
                .foregroundStyle(.tertiary)
                .padding(.top, ChromeMetrics.glyphTopInset)

            VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
                Button {
                    RowExpansions.shared.toggle("plan:\(plan.id)")
                } label: { header }
                    .buttonStyle(.plain)

                if isExpanded {
                    MarkdownText(blocks: plan.blocks)
                        .selectionIndex(0)
                }
                outcome
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ChromeMetrics.cardVertical)
        .padding(.horizontal, ChromeMetrics.cardHorizontal)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .fill(Color.primary.opacity(ChromeMetrics.detailTint))
                .allowsHitTesting(false)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(ChromeType.Reading.icon)
            Text("Plan")
                .font(ChromeType.Reading.body.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var outcome: some View {
        switch plan.outcome {
        case .waiting:
            if let decision {
                buttons(decision)
            } else {
                Text("waiting…")
                    .font(ChromeType.Reading.meta)
                    .foregroundStyle(.tertiary)
            }

        case .approved(let edited):
            Text(edited ? "→ Approved, with your edits" : "→ Approved")
                .font(ChromeType.Reading.body)
                .foregroundStyle(ChromeColor.accent)

        case .rejected(let reason):
            VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
                Text("→ Not approved")
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(.orange)
                if let reason {
                    Text(reason)
                        .font(ChromeType.Reading.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Named for what they decide rather than by the host's own words for them,
    /// which are a tool call's: allowing a plan is approving it, and refusing one
    /// sends the session back to planning rather than stopping it.
    private func buttons(_ decision: PlanDecision) -> some View {
        HStack(spacing: ChromeMetrics.controlGap) {
            ForEach(decision.options) { option in
                Button(option.kind.planName ?? option.name) { decision.choose(option) }
                    .buttonStyle(.bordered)
                    .tint(option.kind.isAllow ? ChromeColor.accent : nil)
            }
        }
    }
}

/// One question and what you said to it, over the options it was asked with.
///
/// The options are kept closed. They are the one place the dialog itself could
/// not take you — it explains an option under its own cursor and shows one
/// mockup at a time, so there is nothing on that screen for the options you were
/// not on — but they are also the part you have already dealt with by the time
/// this is drawn, and a transcript that opened four of them under every question
/// would be mostly options.
private struct AskedQuestionBlock: View {
    let key: String
    let question: AskedQuestion
    let isPending: Bool
    var wasRespondedTo = false

    private var isExpanded: Bool { RowExpansions.shared.isExpanded(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
            Text(question.question)
                .font(ChromeType.Reading.body.weight(.medium))

            if let answer = question.answer {
                Text("→ \(answer)")
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(ChromeColor.accent)
            }
            if let note = question.note {
                Text(note)
                    .font(ChromeType.Reading.body)
                    .foregroundStyle(.secondary)
            }
            if question.answer == nil, question.note == nil, !wasRespondedTo {
                Text(isPending ? "waiting…" : "not answered")
                    .font(ChromeType.Reading.meta)
                    .foregroundStyle(.tertiary)
            }

            if question.isWorthOpening {
                Button { RowExpansions.shared.toggle(key) } label: { disclosure }
                    .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
                    ForEach(question.options, id: \.label) { option(for: $0) }
                }
                .padding(.leading, ChromeMetrics.glyphGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosure: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(ChromeType.Reading.icon)
            Text("\(question.options.count) options")
                .font(ChromeType.Reading.meta)
        }
        .foregroundStyle(.tertiary)
        .contentShape(Rectangle())
    }

    private func option(for asked: AskedOption) -> some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            Text(asked.label)
                .font(ChromeType.Reading.meta.weight(.medium))
                .foregroundStyle(asked == question.chosen ? ChromeColor.accent : .secondary)

            if let description = asked.description {
                Text(description)
                    .font(ChromeType.Reading.meta)
                    .foregroundStyle(.tertiary)
            }
            if let preview = asked.preview {
                PreviewPanel(text: preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The mockup an option was asked with, drawn the way the CLI would have: a
/// picture made of characters, which lines up only in a face where every
/// character is one column wide.
private struct PreviewPanel: View {
    let text: String

    private var rows: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(ChromeType.Reading.mono)
                .textSelection(.enabled)
                .fixedSize()
                .padding(ChromeMetrics.previewInset)
        }
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(ChromeColor.optionEdge, lineWidth: ChromeMetrics.hairline))
    }

    /// Asked of the text rather than left to the scroll view, which along an axis
    /// it scrolls takes whatever it is offered — a three-line mockup in a box the
    /// height of the tallest one there could be.
    private var height: CGFloat {
        let shown = min(rows, ChromeMetrics.previewMaxLines)
        return CGFloat(shown) * ChromeType.Reading.monoLine + ChromeMetrics.previewInset * 2
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
    }
}

struct ToolCallRow: View {
    let call: ToolCall
    var isRunning = false

    private var isExpanded: Bool { RowExpansions.shared.isExpanded("call:\(call.id)") }

    @Environment(\.subagentScope) private var scope
    @Environment(\.subagentDepth) private var depth
    @Environment(\.runningAgents) private var runningAgents
    @Environment(\.openAgent) private var openAgent

    /// The host's name for this call's agent, kept once seen. The host drops a
    /// finished task the moment it is told — a beat before the transcript's
    /// next pass carries the result's own agentId — and in that gap the row
    /// would stop opening onto the conversation.
    @State private var spotted: String?

    /// Which model and effort this call's agent ran on, read from the agent's
    /// own file. Held here rather than asked for on every draw: it is a disk
    /// read, and it cannot change once the agent has taken a turn.
    @State private var identity: SubagentIdentity?

    /// What this call's agent is carrying, off the tail of its own file.
    @State private var carrying: SessionContext?

    private static let detailLimit = 4_000

    /// Agents nest three deep by default (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`),
    /// so a row this far in has nothing left below it to open.
    private static let depthLimit = 3

    /// The transcript's word wins; while a foreground agent is still out only
    /// the host has one, and the task id it holds is the file's name.
    private var agentID: String? {
        call.agentID ?? runningAgents[call.id] ?? spotted
    }

    /// Where opening this row means reading somebody else's conversation rather
    /// than this call's own input and result.
    private var conversation: SubagentScope? {
        guard call.isDelegation, agentID != nil, depth < Self.depthLimit else { return nil }
        return scope
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
            Button {
                if let agentID, conversation != nil, let openAgent {
                    openAgent(call, agentID: agentID)
                } else {
                    RowExpansions.shared.toggle("call:\(call.id)")
                }
            } label: { header }
                .buttonStyle(.plain)
                .selectableWhole([call.heading(running: isRunning), call.subheading].compactMap { $0 }.joined(separator: " "))
                .selectionIndex(0)

            if isExpanded { detail }
        }
        .onChange(of: runningAgents[call.id], initial: true) { _, id in
            if let id { spotted = id }
        }
        // Re-run when the agent finishes: an agent named but not yet started
        // has no file, and the read that finds one is the last one worth taking.
        .task(id: "\(agentID ?? "")#\(isRunning)") { await readIdentity() }
        .task(id: "\(agentID ?? "")#\(isRunning)#context") { await readContext() }
    }

    /// The one eager disk read on this row. It is why the model can be on the
    /// line at all — the agent's own conversation is otherwise not read until
    /// somebody opens it — and it is bounded to the head of the
    /// file rather than the whole of it.
    ///
    /// It polls while the agent is out, for the same reason `SubagentFeed`
    /// does: an agent is named before it opens its file and takes a turn, so
    /// the first read is guaranteed to come back with nothing, and a row that
    /// asked once would carry no model for exactly the run somebody is
    /// watching.
    ///
    /// A finished agent gets a few passes rather than one. The turn ending and
    /// the file holding every line of it are not the same moment — the same lag
    /// `awaitTranscripts` was written for — and this read fails in the
    /// flattering direction: nothing is drawn, so a row that gave up too early
    /// reads exactly like an agent that legitimately named no model.
    private static let settlingReads = 3

    private func readIdentity() async {
        guard identity == nil, let agentID, let scope = conversation else { return }

        var settling = Self.settlingReads
        repeat {
            identity = await scope.source.identity(agentID: agentID, in: scope.directory)
            if identity != nil { return }
            if !isRunning {
                settling -= 1
                if settling == 0 { return }
            }
            try? await Task.sleep(for: .milliseconds(600))
        } while !Task.isCancelled
    }

    /// Unlike the identity this moves with every turn, so a working agent is
    /// re-read for as long as it is out, and a finished one takes every settling
    /// read: the first can land before the agent's last turn is flushed.
    private func readContext() async {
        guard let agentID, let scope = conversation else { return }

        var settling = Self.settlingReads
        repeat {
            if let read = await scope.source.context(agentID: agentID, in: scope.directory) {
                carrying = read
            }
            if !isRunning {
                settling -= 1
                if settling == 0 { return }
            }
            try? await Task.sleep(for: scope.source.interval)
        } while !Task.isCancelled
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
            glyph

            Text(call.heading(running: isRunning))
                .font(ChromeType.Reading.meta.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if let subheading = call.subheading {
                Text(subheading)
                    .font(ChromeType.Reading.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            tally

            // Only where opening the row leads somewhere it wouldn't otherwise:
            // every tool row opens, but a delegating one opens onto a whole
            // conversation, and nothing else on the line says so.
            if conversation != nil, openAgent != nil {
                Image(systemName: "chevron.right")
                    .font(ChromeType.Reading.icon)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// How long a call has been going, or was gone, and for an agent which
    /// model it ran on and what its context came to.
    ///
    /// The CLI's tool and token counts are left off: its token figure is the
    /// agent's last context plus one reply, the ctx term again.
    ///
    /// The model leads rather than trails because it is the term that answers a
    /// question you can't answer any other way: the app's only reading of
    /// whether the floor it set at launch actually held.
    private var tally: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
            if let identity { note(identity.summary) }
            if let carrying {
                Text(carrying.label)
                    .font(ChromeType.Reading.meta.weight(carrying.isExpensive ? .semibold : .regular))
                    .foregroundStyle(carrying.isExpensive ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .fixedSize()
                    .help(carrying.help)
            }
            counts
        }
    }

    @ViewBuilder
    private var counts: some View {
        if isRunning, let startedAt = call.startedAt {
            RunningClock(since: startedAt)
        } else if isRunning, call.isDelegation, call.result != nil {
            note("running…")
        } else if call.neverCameBack {
            note(strandedNote)
        } else if call.wasDropped {
            note(ToolCall.droppedNote)
        } else if let totals = call.result?.subagent {
            note(Format.elapsed(totals.duration))
        } else if call.isDelegation, let took = call.took {
            note(Format.elapsed(took))
        } else if call.isPending {
            note(isRunning ? "running…" : strandedNote)
        }
    }

    /// What a pending call says once nothing is working behind it. It never
    /// came back and now never will: either the session was killed holding the
    /// line, or the conversation carried on past it and left it behind.
    private let strandedNote = "never came back"


    private func note(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.Reading.meta)
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    @ViewBuilder
    private var glyph: some View {
        if isRunning {
            RunningGlyph(symbol: ToolGlyph.name(for: call.name))
        } else {
            Image(systemName: ToolGlyph.name(for: call.name))
                .font(ChromeType.Reading.icon)
                .foregroundStyle(tint)
                .frame(width: ChromeMetrics.toolGlyphSlot, alignment: .leading)
        }
    }

    private var tint: Color {
        if call.isPending || call.neverCameBack { return .secondary }
        return call.result?.isError == true || call.wasDropped ? .red : ChromeColor.accent
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
            if let input = call.prettyInput {
                MonoSlab(text: Self.clipped(input))
                    .selectionIndex(1)
            }
            if let result = call.result, !result.text.isEmpty, !call.neverCameBack {
                MonoSlab(
                    text: Self.clipped(result.text),
                    tint: result.isError ? .warning : .secondary
                )
                .selectionIndex(2)
            } else if call.isPending || call.neverCameBack {
                Text(isRunning ? "running…" : strandedNote)
                    .font(ChromeType.Reading.meta)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, ChromeMetrics.toolGlyphSlot + ChromeMetrics.iconGap)
    }

    /// A file read or a test run can return megabytes, and writing one sends
    /// them the other way. Past a few thousand characters the pane is laying out
    /// machinery nobody is reading.
    private static func clipped(_ text: String) -> String {
        TranscriptText.clipped(text, to: detailLimit)
    }
}

enum ToolGlyph {
    /// Every glyph `name(for:)` can answer, for measuring them ahead of time.
    static let all = [
        "doc.text", "square.and.pencil", "pencil", "terminal", "magnifyingglass", "person.2", "globe",
        "checklist", "questionmark.bubble", "list.bullet.clipboard", "wand.and.stars", "wrench.and.screwdriver",
    ]

    static func name(for tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead": "doc.text"
        case "Write": "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Bash", "BashOutput", "KillShell": "terminal"
        case "Glob", "Grep": "magnifyingglass"
        case "Task", "Agent": "person.2"
        case "WebFetch", "WebSearch": "globe"
        case "TodoWrite": "checklist"
        case "AskUserQuestion": "questionmark.bubble"
        case "ExitPlanMode": "list.bullet.clipboard"
        case "Skill": "wand.and.stars"
        default: "wrench.and.screwdriver"
        }
    }
}

/// An item's hash, recomputed only when the item is no longer the one hashed.
/// The feed hands back the same strings pass after pass, so the comparison
/// that decides this is usually a pointer check rather than a read.
@MainActor
final class ItemHashes {
    private var known: [String: (item: TranscriptItem, hash: Int)] = [:]

    func hash(_ item: TranscriptItem) -> Int {
        if let known = known[item.id], known.item == item { return known.hash }
        let hash = item.hashValue
        if known.count > 20_000 { known.removeAll(keepingCapacity: true) }
        known[item.id] = (item, hash)
        return hash
    }
}
