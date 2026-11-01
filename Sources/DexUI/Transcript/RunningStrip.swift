import DexCore
import SwiftUI

/// Who is working and for how long, over the box you type in rather than at the
/// end of the transcript.
///
/// One row each, and the session gets no more of a row than the agents it sent
/// out: they are separate runs of work, each with its own clock and its own way
/// to end it. It says who rather than what on purpose — what the session is
/// doing is already a row of its own up in the conversation, and naming it twice
/// reads as two things happening. What the transcript can't keep is the fact of
/// it: scroll back through a turn and the work goes off screen with everything
/// else.
package struct RunningStrip: View {

    /// The agents still out, oldest first.
    let agents: [ToolCall]

    /// Whether the session is working on its own account. False where everything
    /// in flight is an agent: the rows below are the whole of what is happening,
    /// and a line over them claiming the session is working too would be one
    /// more thing running than there is.
    let isWorking: Bool

    /// Commands the session backgrounded and carried on past, oldest first.
    /// Beside the agents rather than among them: they are the same kind of
    /// thing from here — a run of work with its own clock — but there is
    /// nothing to open under one.
    var background: [ToolCall] = []

    /// When the session was last handed something and left to it. The clock runs
    /// from there, so it measures the stretch it has been working without you.
    var handedOverAt: Date?

    /// Cuts the turn short. Nil for a session the app only found on disk, which
    /// spins the same way and has nobody listening.
    var interrupt: (() -> Void)?

    /// Ends one run of work, by the call that started it — an agent or a
    /// command the session walked away from. Answers nil where there is nothing
    /// to press: work that was already out when the app connected has no task
    /// the host can name, and a session it isn't holding has none at all.
    var stopTask: ((ToolCall) -> (() -> Void)?)?

    /// Brings a row's call into view up in the conversation.
    var reveal: ((ToolCall) -> Void)?

    /// Puts an agent's conversation up over the transcript.
    var open: ((ToolCall) -> Void)?

    /// Enough rows to see what is out at a glance. Past this the rest wait
    /// behind a click rather than push the transcript up.
    private static let named = 6

    /// Past this height an opened strip scrolls inside itself, so a wide
    /// fan-out can't take the composer's place on screen.
    private static let tallest: CGFloat = 240

    package init(
        agents: [ToolCall],
        isWorking: Bool,
        background: [ToolCall] = [],
        handedOverAt: Date? = nil,
        interrupt: (() -> Void)? = nil,
        stopTask: ((ToolCall) -> (() -> Void)?)? = nil,
        reveal: ((ToolCall) -> Void)? = nil,
        open: ((ToolCall) -> Void)? = nil
    ) {
        self.agents = agents
        self.isWorking = isWorking
        self.background = background
        self.handedOverAt = handedOverAt
        self.interrupt = interrupt
        self.stopTask = stopTask
        self.reveal = reveal
        self.open = open
    }

    @State private var showsAll = false

    private var overflows: Bool { agents.count + background.count > Self.named }

    private var shown: [ToolCall] {
        showsAll ? agents : Array(agents.prefix(Self.named))
    }

    private var shownBackground: [ToolCall] {
        showsAll ? background : Array(background.prefix(max(0, Self.named - shown.count)))
    }

    private var hidden: Int {
        (agents.count - shown.count) + (background.count - shownBackground.count)
    }

    package var body: some View {
        if isWorking || !agents.isEmpty || !background.isEmpty {
            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                if isWorking { session }

                if showsAll && overflows {
                    ScrollView {
                        rows.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.tallest)
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    rows
                }

                if overflows {
                    Button {
                        showsAll.toggle()
                    } label: {
                        HStack(spacing: ChromeMetrics.iconGap) {
                            RunningMark(isShown: false)
                            Text(showsAll ? "Show fewer" : "+\(hidden) more")
                                .font(ChromeType.badge)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsAll ? "Fold the strip back down" : "Show everything still out")
                }
            }
            .frame(maxWidth: ChromeMetrics.readingMeasure, alignment: .leading)
            .padding(.horizontal, ChromeMetrics.readingInset)
            .padding(.top, ChromeMetrics.rowVertical)
            .frame(maxWidth: .infinity)
            .onChange(of: overflows) { _, overflows in
                if !overflows { showsAll = false }
            }
            // A stop can empty the strip in one update, which onChange never sees.
            .onDisappear { showsAll = false }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            ForEach(shown) { call in
                RunningRow(
                    label: call.purpose ?? "agent",
                    since: call.startedAt,
                    help: open == nil
                        ? "This agent is still out — click to find its call in the conversation"
                        : "This agent is still out — click to read it",
                    reveal: (open ?? reveal).map { action in { action(call) } },
                    stop: stopTask?(call),
                    stopHelp: "Stop this agent — the session carries on without it"
                )
            }

            ForEach(shownBackground) { call in
                RunningRow(
                    label: Self.label(for: call),
                    since: call.startedAt,
                    help: Self.help(for: call),
                    reveal: reveal.map { reveal in { reveal(call) } },
                    stop: stopTask?(call),
                    stopHelp: call.isWatcher
                        ? "Stop this watcher — the session carries on"
                        : "Stop this command — the session carries on"
                )
            }
        }
    }

    /// A watch says what it is watching, since what it is doing is waiting: the
    /// row beside it names a command that is working, and the same phrasing for
    /// both would read as two commands running.
    private static func label(for call: ToolCall) -> String {
        guard call.isWatcher else { return call.purpose ?? call.name }
        guard let purpose = call.purpose else { return "watching" }
        return "watching \(purpose)"
    }

    private static func help(for call: ToolCall) -> String {
        call.isWatcher
            ? "This watch is still up — what it sees arrives in the conversation"
                + " as it happens"
            : "This command was put in the background — it is still running, and"
                + " nothing is written here until it comes back"
    }

    /// Named as one runner among the rows under it rather than as a state: the
    /// agents are named by the work they were sent to do, and this is the one
    /// that stayed to do the rest of it.
    private var session: some View {
        RunningRow(
            label: "Main agent",
            since: handedOverAt,
            help: "The session itself, not one of the agents it sent out",
            stop: interrupt,
            stopHelp: stopHelp
        )
    }

    /// Named for everything it takes, not just the turn: an agent the session is
    /// waiting on goes down with the turn that is waiting. The agents' own rows
    /// are the way to end one and leave the rest running.
    private var stopHelp: String {
        agents.isEmpty
            ? "Stop this turn (Esc) — the session stays open"
            : "Stop this turn (Esc) — an agent it is waiting on stops with it"
    }
}

/// One run of work: that it is going, what it is, how long it has been, and the
/// way to end it. The session's own line and an agent's are the same row,
/// because from here they are the same thing.
private struct RunningRow: View {
    let label: String
    let since: Date?
    let help: String
    var reveal: (() -> Void)?
    var stop: (() -> Void)?
    var stopHelp: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.iconGap) {
            RunningMark()

            title

            if let since {
                RunningClock(since: since, font: ChromeType.badge)
            }

            Spacer(minLength: ChromeMetrics.inlineGap)

            if let stop {
                StopButton(action: stop, help: stopHelp)
            }
        }
    }

    @ViewBuilder private var title: some View {
        let text = Text(label)
            .font(ChromeType.badge.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

        if let reveal {
            Button(action: reveal) { text }
                .buttonStyle(.plain)
                .help(help)
        } else {
            text.help(help)
        }
    }
}

/// The dot that marks a row as live — the glyph the session list shows for a
/// running process, in the same working color, held still on purpose. The rows
/// up in the transcript are where running work spins; this strip sits on screen
/// beside them, and two of the same animation a glance apart read as more
/// happening than there is. The clock alongside is what says it's still going.
/// Drawn blank where a line has no run of its own, so it starts where the rows
/// above it start rather than under their dots.
private struct RunningMark: View {
    var isShown = true

    var body: some View {
        Image(systemName: "circle.fill")
            .font(ChromeType.badgeIcon)
            .foregroundStyle(Presentation.color(for: .running))
            .opacity(isShown ? 1 : 0)
    }
}

/// Ends one run of work and leaves the rest alone: on the session's row that is
/// the turn, on an agent's it is that agent. Either way the conversation stays
/// open and the box below is yours again.
struct StopButton: View {
    let action: () -> Void
    let help: String

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.badgeGap) {
                Image(systemName: "stop.fill")
                    .font(ChromeType.badgeIcon)
                Text("Stop")
                    .font(ChromeType.badge.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, ChromeMetrics.badgeHorizontal)
            .padding(.vertical, ChromeMetrics.badgeVertical)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
