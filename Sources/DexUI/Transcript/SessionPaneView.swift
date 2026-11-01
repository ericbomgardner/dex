import DexCore
import AppKit
import SwiftUI

struct SessionPaneView: View {
    @Bindable var store: SessionStore
    let pane: SessionPane
    let attachment: PaneAttachment

    static let minWidth: CGFloat = 420

    @State private var columnHeight: CGFloat = 0
    @State private var feed = TranscriptFeed()
    @State private var revealing: TranscriptReveal?

    var body: some View {
        VStack(spacing: 0) {
            TranscriptPane(
                attachment: attachment,
                feed: feed,
                isWorking: isWorking,
                isCompacting: pane.row?.isCompacting ?? false,
                isLive: isLive,
                source: source,
                planDecision: planDecision,
                runningAgents: pane.runningAgents,
                saying: pane.saying(
                    for: attachment.hostKey,
                    heard: feed.heard,
                    of: feed.heardOf
                ),
                sends: pane.sends,
                revealing: revealing,
                places: pane.places,
                openAgent: OpenAgentAction { pane.openAgent($0, agentID: $1, nested: false) }
            )
            // What the file has caught up on, which is what the pane no longer
            // has to stand in for. Counted rather than matched on the text,
            // since the CLI does not record every message as it was typed. From
            // the first reading, not only from changes to it: the mark this
            // sets is what a later reading is measured against, and a message
            // sent before it was ever set would wait for a second one.
            // Keyed on the transcript as well as the count, since a mark taken
            // from one file says nothing about another opened under the same
            // key.
            //
            // Only a reading of the transcript this pane is on. The feed is one
            // object across a switch, so the frame after one still carries the
            // previous session's count — and handed over under the new
            // session's id it marked that session at a count its own file
            // might never reach, leaving every message sent to it on screen
            // twice, under its own turn, for good. Every reading the feed
            // reports says which file it counted; a mismatch is that frame.
            .onChange(of: Reading(heard: feed.heard, of: feed.heardOf), initial: true) {
                guard feed.heardOf == attachment.sessionID else { return }
                pane.heard(feed.heard, of: feed.heardOf, for: attachment.hostKey)
            }
            // A transcript just opened, or just named for a session that had
            // none, is marked at nothing until it has been read: a message sent
            // to a session before its transcript was named is measured from
            // there, rather than from a first reading that already has it.
            // A mark the transcript already holds is kept, since nothing is
            // above nothing.
            .onChange(of: attachment.sessionID, initial: true) {
                pane.heard(0, of: attachment.sessionID, for: attachment.hostKey)
            }

            Divider()

            // Over an empty transcript only for its Stop: since CLI v2.1.261 an
            // interrupt before the first turn starts stops it.
            if !feed.items.isEmpty || pane.turnIsInterruptible {
                RunningStrip(
                    agents: TranscriptFlow.agents(in: marked),
                    // Both off the file, and only the rows below off the host:
                    // whether the session is working on its own account is a
                    // reading about this turn, and work it walked away from
                    // outlives the turn that started it.
                    isWorking: isWorking && !TranscriptFlow.isWaitingOnAgents(in: feed.items),
                    background: TranscriptFlow.backgroundWork(in: marked),
                    handedOverAt: feed.handedOverAt,
                    interrupt: pane.turnIsInterruptible
                        ? { pane.interrupt() }
                        : nil,
                    stopTask: stopper,
                    reveal: { revealing = TranscriptReveal(call: $0) },
                    open: { call in
                        if let agentID = call.agentID ?? pane.runningAgents[call.id], subagentScope != nil {
                            pane.openAgent(call, agentID: agentID, nested: false)
                        } else {
                            revealing = TranscriptReveal(call: call)
                        }
                    }
                )
                .id(attachment.sessionID)
            }

            TranscriptComposer(
                pane: pane,
                store: store,
                columnHeight: columnHeight,
                model: feed.answering(orListsWord: pane.row?.context?.model),
                context: feed.carrying(orListsWord: pane.row?.context),
                decidedInPane: planAsk?.askId,
                sessionIsWorking: isWorking
            )
        }
        .frame(minWidth: Self.minWidth, minHeight: 240)
        .paneGround(.windowBackgroundColor)
        .overlay { agentCard }
        .animation(.easeOut(duration: 0.12), value: pane.openAgents.isEmpty)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ColumnHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ColumnHeightKey.self) { columnHeight = $0 }
    }

    @ViewBuilder
    private var agentCard: some View {
        if !pane.openAgents.isEmpty, let scope = subagentScope {
            ZStack {
                OverlayScrim { pane.closeAgents() }
                AgentCard(
                    agents: pane.openAgents,
                    sessionItems: marked,
                    scope: scope,
                    runningAgents: pane.runningAgents,
                    isLive: isLive,
                    stop: stopper,
                    openNested: { pane.openAgent($0, agentID: $1, nested: true) },
                    back: { pane.backOutAgents(to: $0) },
                    close: { pane.closeAgents() }
                )
            }
            .transition(.opacity)
        }
    }

    private var subagentScope: SubagentScope? {
        feed.subagents.map { SubagentScope(directory: $0, source: source) }
    }

    /// Ends one run of work by the call that started it, where the host can name it.
    private func stopper(for call: ToolCall) -> (() -> Void)? {
        guard let taskID = pane.agentTask(toolUseID: call.id)?.taskId
            ?? call.agentID.flatMap({ id in
                pane.runningAgents.values.contains(id) ? id : nil
            })
        else { return nil }
        return { pane.stopAgent(taskID: taskID) }
    }

    /// What the file has caught up on, and which file said so.
    private struct Reading: Equatable {
        let heard: Int
        let of: String?
    }

    /// The same reading the pane draws from, so the strip and the conversation
    /// agree about what is still out.
    private var marked: [TranscriptItem] {
        TranscriptFlow.marking(
            feed.items,
            running: Set(pane.runningAgents.keys),
            agents: pane.runningAgents
        )
    }

    /// Where this session's transcript comes from.
    private var source: any TranscriptSource {
        return store.localSource
    }

    private var isWorking: Bool {
        guard let row = pane.row else { return false }
        // Not while the session only waits on background work: the pane's word
        // for working is "Thinking…", and nothing is thinking — the launch
        // receipt and the sign-off are already on screen. The sidebar's
        // spinner carries the waiting.
        return row.isActivelyWorking() && !row.isAwaitingBackgroundWork
    }

    /// Whether anything could still write to this transcript — see
    /// `AgentSession.canAnswer`. Not `isActivelyWorking()`, which is the wrong
    /// question here and wrong in the dangerous direction: it goes quiet 15s
    /// after the *parent* file stops being written, which is precisely what a
    /// background agent does to it while carrying on in its own. Asked that
    /// way, a live agent reads as one that never came back.
    private var isLive: Bool {
        pane.row?.session.canAnswer ?? false
    }

    /// The plan this session is holding out, once the transcript has caught up
    /// with the ask. Held back until then: the buttons go under the plan, and
    /// until the file has the plan there is nothing to put them under — so the
    /// card below the composer keeps it, as it keeps every other permission.
    private var planAsk: HostAsk? {
        guard waitingPlanID != nil else { return nil }
        return store.host
            .asks
            .pending(forKey: attachment.hostKey)
            .first { HostAskContent.read($0).permissionRequest?.isPlan == true }
    }

    /// The last one still waiting, since an older plan can wait for good.
    private var waitingPlanID: String? {
        let last = feed.items.last { item in
            guard case .plan(let plan) = item else { return false }
            return plan.outcome == .waiting
        }
        guard case .plan(let plan) = last else { return nil }
        return plan.id
    }

    private var planDecision: PlanDecision? {
        guard let ask = planAsk, let planID = waitingPlanID else { return nil }
        return PlanDecision(planID: planID, options: ask.options) {
            store.host
                .answer(askId: ask.askId, option: $0)
        }
    }
}
