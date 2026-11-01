import DexCore
import SwiftUI

/// An agent's conversation, laid over the pane of the session that sent it,
/// composer and all. An agent the agent sent opens in the same card, with the
/// way back along the top.
struct AgentCard: View {

    /// Outermost first, each opened from inside the one before.
    let agents: [OpenAgent]

    /// The session's conversation as the pane draws it, which is where the
    /// outermost call is read from as it runs and comes back.
    let sessionItems: [TranscriptItem]

    let scope: SubagentScope
    let runningAgents: [String: String]

    /// Whether the session is still there to answer — see `TranscriptItemView`.
    let isLive: Bool

    let stop: (ToolCall) -> (() -> Void)?
    let openNested: @MainActor @Sendable (ToolCall, String) -> Void
    let back: (Int) -> Void
    let close: () -> Void

    @State private var feeds = AgentFeeds()
    @State private var hashes = ItemHashes()

    /// Its own, since the card is drawn outside the transcript's.
    @State private var selection = TranscriptSelection()

    /// Off the composer under the scrim, where keys would be typed and sent unseen.
    @FocusState private var holdsKeys: Bool

    private struct Level: Identifiable {
        let index: Int
        let call: ToolCall
        let agentID: String
        let isRunning: Bool

        var id: String { agentID }
    }

    /// Each agent's call as it stands now, read out of the conversation it was
    /// opened from, and falling back on the call as it was when it was opened.
    private var levels: [Level] {
        var items = sessionItems
        return agents.enumerated().map { index, agent in
            let found = Self.find(agent.call.id, in: items)
            items = feeds.feed(for: agent.agentID).items
            return Level(
                index: index,
                call: found?.call ?? agent.call,
                agentID: agent.agentID,
                isRunning: isLive && found?.isRunning == true
            )
        }
    }

    var body: some View {
        let levels = levels
        if let top = levels.last {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: ChromeMetrics.iconGap) {
                    if levels.count > 1 { trail(levels) }
                    heading(top)
                }
                .padding(.horizontal, ChromeMetrics.readingInset)
                .padding(.vertical, ChromeMetrics.rowVertical)
                // Ahead of every row of the conversation, which numbers from 0.
                .selectionIndex(-1)

                Divider()

                conversation(top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .environment(\.subagentScope, scope)
            .environment(\.runningAgents, runningAgents)
            .environment(\.transcriptSelection, selection)
            .overlayCard(width: ChromeMetrics.agentCardWidth)
            .padding(.vertical, ChromeMetrics.agentCardMargin)
            .focusable()
            .focusEffectDisabled()
            .focused($holdsKeys)
            .onAppear { holdsKeys = true }
            .onExitCommand(perform: close)
            .onDisappear { selection.clear() }
            // Every level is followed, not only the one on top: the call each
            // one is headed with is read out of the level below it.
            .background {
                ForEach(levels) { level in
                    Color.clear.task(id: "\(level.agentID)#\(level.isRunning)") {
                        await feeds.feed(for: level.agentID).run(
                            agentID: level.agentID, in: scope.directory,
                            follows: level.isRunning, source: scope.source
                        )
                    }
                }
            }
            .onChange(of: agents.map(\.agentID), initial: true) { _, open in
                feeds.keep(Set(open))
            }
        }
    }

    private func trail(_ levels: [Level]) -> some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            ForEach(levels.dropLast()) { level in
                Button(level.call.brief ?? "agent") { back(level.index) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(ChromeType.Reading.icon)
                    .foregroundStyle(.tertiary)
            }
            Text(levels.last?.call.brief ?? "agent")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(ChromeType.Reading.meta)
    }

    /// The row the agent was opened from, which here opens onto the brief and
    /// the report rather than onto the conversation already under it.
    private func heading(_ level: Level) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.inlineGap) {
            ToolCallRow(call: level.call, isRunning: level.isRunning)
                .environment(\.subagentDepth, level.index)
                .environment(\.openAgent, nil)
                .id(level.agentID)

            if level.isRunning, let stop = stop(level.call) {
                StopButton(action: stop, help: "Stop this agent — the session carries on without it")
            }

            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(ChromeType.control)
                .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private func conversation(_ level: Level) -> some View {
        let feed = feeds.feed(for: level.agentID)
        Group {
            if feed.items.isEmpty {
                note(feed.phase)
                    .padding(ChromeMetrics.readingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TranscriptColumn(rows: rows(feed.items, isLive: level.isRunning), transcript: level.agentID)
            }
        }
        .environment(\.subagentDepth, level.index + 1)
        .environment(\.openAgent, OpenAgentAction(open: openNested))
    }

    private func rows(_ items: [TranscriptItem], isLive: Bool) -> [ColumnRow] {
        items.enumerated().map { index, item in
            let lead = index > 0 ? ChromeMetrics.itemGap : 0
            let native = NativeRow.of(item, isLive: isLive)
            var content = Hasher()
            if let native { content.combine(native) } else { content.combine(hashes.hash(item)) }
            content.combine(lead)
            return ColumnRow(
                id: item.id,
                content: content.finalize(),
                place: index,
                view: AnyView(TranscriptItemView(item: item, isLive: isLive).padding(.top, lead)),
                native: native,
                lead: lead
            )
        }
    }

    @ViewBuilder
    private func note(_ phase: SubagentFeed.Phase) -> some View {
        switch phase {
        case .starting:
            Text("starting…")
                .font(ChromeType.Reading.meta)
                .foregroundStyle(.tertiary)
        case .reading:
            EmptyView()
        case .missing:
            Text("no transcript for this agent")
                .font(ChromeType.Reading.meta)
                .foregroundStyle(.tertiary)
        }
    }

    /// Running is the conversation's own word for it: a call drawn as the one
    /// still out, which a backgrounded agent is too once the host says so.
    private static func find(_ id: String, in items: [TranscriptItem]) -> (call: ToolCall, isRunning: Bool)? {
        for item in items {
            switch item {
            case .activeTool(let call) where call.id == id:
                return (call, true)
            case .toolRun(let run):
                if let call = run.calls.first(where: { $0.id == id }) { return (call, false) }
            default:
                continue
            }
        }
        return nil
    }
}

/// One feed per agent in the card, kept while the agent is in it, so backing
/// out to one doesn't read it again from the top.
@MainActor
final class AgentFeeds {
    private var feeds: [String: SubagentFeed] = [:]

    func feed(for agentID: String) -> SubagentFeed {
        if let feed = feeds[agentID] { return feed }
        let feed = SubagentFeed()
        feeds[agentID] = feed
        return feed
    }

    func keep(_ agentIDs: Set<String>) {
        feeds = feeds.filter { agentIDs.contains($0.key) }
    }
}
