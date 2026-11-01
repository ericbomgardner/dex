import DexCore
import SwiftUI

/// What this session is, and what becomes of it, under the box you type in —
/// where the CLI keeps the first two. Capsules are read off the session and
/// menus are dials, so what can be changed is told from what can only be looked
/// at without either being labelled.
struct ComposerStatusLine: View {
    let pane: SessionPane
    @Bindable var store: SessionStore

    /// What the session is answering as, off its newest turn. The chip falls
    /// back to what the app launched — the init-resolved id, then the picked
    /// alias — because a hosted session cannot move its model, so waiting for
    /// the first reply to confirm it was a blank chip saying nothing new.
    let model: String?

    private var chip: ModelChip? {
        ModelChip.reading(
            answered: model,
            resolved: pane.resolvedModel,
            launched: pane.launchedModel,
            defaultModel: pane.defaults?.model ?? .unanswered,
            names: store.modelNames.names
        )
    }

    /// What it is carrying, off the same turn. Always shown rather than only
    /// once it is expensive: the pane is where you decide whether to send the
    /// next message here or somewhere fresh, and a number that appears only at
    /// the end tells you nothing on the way up to it.
    let context: SessionContext?

    /// What it thinks at, and the dial that moves it. The only dial here: the
    /// output style could have one too since CLI v2.1.278, when
    /// `applyFlagSettings` started moving a running session's style, but the app
    /// keeps that as one app-wide pick in Settings and never on a row —
    /// deferred, not impossible.
    private var effort: EffortLevel? { pane.effort }

    var body: some View {
        let mcp = pane.mcpTrouble
        if chip != nil || context != nil || effort != nil || !mcp.isEmpty {
            HStack(spacing: ChromeMetrics.inlineGap) {
                if let chip {
                    ModelBadge(chip: chip)
                }
                if let context {
                    ContextBadge(context: context)
                }
                if !mcp.isEmpty {
                    McpTroubleChip(pane: pane, trouble: mcp)
                }
                if let effort {
                    SessionEffortPicker(pane: pane, effort: effort, model: model ?? pane.resolvedModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keyed on the attached session's folder, so the dial's Default is
            // re-read when the pane moves to another session — and again when
            // this one is reopened, since the files behind the answer change
            // under the app.
            .task(id: pane.row?.projectPath) {
                guard let cwd = pane.row?.projectPath else { return }
                pane.readDefaults(for: cwd)
            }
        }
    }
}

/// The effort a running session thinks at, and the dial that moves it.
///
/// It offers one level the composer's picker cannot: `max` is session-scoped by
/// design — no settings file may hold it — and asked for at launch it comes back
/// as `xhigh`, one row below what was picked. Here it takes.
///
/// Nothing restates a session's effort the way the session restates its own
/// mode, so a refusal is the only correction there will be: the pick is put
/// back, and the reason is shown rather than swallowed.
private struct SessionEffortPicker: View {
    let pane: SessionPane
    let effort: EffortLevel
    let model: String?

    private var rows: [EffortLevel] {
        EffortLevel.dialled(keeping: effort, accepting: pane.acceptedEfforts)
    }

    /// Read off the folder the session was started in rather than off the
    /// session: what the app sends a session rides above every file behind that
    /// answer, so asking the session would say what was picked rather than what
    /// picking nothing means.
    private var byDefault: EffortLevel? {
        EffortLevel.matchingDefault(in: rows, resolved: pane.defaults?.effort(forModel: model))
    }

    /// What it is thinking at, which is the level it was moved to or — while
    /// nothing has moved it — the one the files resolve to.
    private var thinking: EffortLevel? { effort == .inherited ? byDefault : effort }

    var body: some View {
        Menu {
            ForEach(rows, id: \.self) { offer in
                Toggle(isOn: menuCheck(offer == thinking) { pane.setEffort(offer) }) {
                    Text(offer == byDefault
                        ? DefaultLabel.text(for: offer.menuLabel, open: true)
                        : offer.menuLabel)
                }
            }
        } label: {
            Text(label)
                .font(ChromeType.badge.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(effort == .inherited ? Color.secondary : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .fixedSize()
        .help(help)
    }

    /// Names the level and nothing else. Default is a marker on a row now, not
    /// a row of its own, so there is a level standing behind it either way —
    /// the bare word is left only for a session whose files name no level, the
    /// CLI having fallen back to something nothing here can read.
    private var label: String {
        thinking?.menuLabel ?? EffortLevel.inherited.menuLabel
    }

    private var help: String {
        guard let label = thinking?.label else {
            return "Thinking at whatever effortLevel your settings say — pick one to pin it"
        }
        guard effort == .inherited else { return "Thinking at \(label), from its next turn on" }
        return "Thinking at \(label), from your settings — pick one to pin it"
    }
}
