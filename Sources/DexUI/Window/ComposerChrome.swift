import DexCore
import SwiftUI

/// Which folder the next session starts in, across the top of the composer.
struct ComposerHeader: View {
    @Bindable var store: SessionStore

    var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: store.flavor.composerSymbol)
                .font(ChromeType.inlineIcon)
                .foregroundStyle(.tertiary)
            HStack(spacing: 0) {
                Text("New session in ")
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                ComposerProjectPicker(store: store)
            }

            Spacer(minLength: ChromeMetrics.inlineGap)
            ComposerModelPicker(store: store)
            ComposerEffortPicker(store: store)
        }
        // Keyed on the folder rather than run once, because the folder moves
        // without being picked: `composerTarget` falls back to the newest row,
        // so starting a session elsewhere retargets the composer under you. Bound
        // here rather than at the call sites that open this, which is where it
        // was and which the fallback goes straight past.
        .task(id: store.composerTarget) { store.readComposerDefaults() }
    }
}

/// Which model the next session starts on.
struct ComposerModelPicker: View {
    @Bindable var store: SessionStore

    private var rows: [SessionModel] { SessionModel.picking(keeping: store.composer.model) }

    /// Which row wears the marker, and — until something is picked — the check
    /// as well. Both sit on the same row and say different things: one is what
    /// your settings resolve to, the other is what this composer will send.
    private var defaultModel: SessionModel? { store.composerDefaultModel }

    private var chosen: SessionModel? {
        store.composer.model == .inherited ? defaultModel : store.composer.model
    }

    var body: some View {
        Menu {
            ForEach(rows, id: \.self) { model in
                Toggle(isOn: menuCheck(model == chosen) {
                    store.composer.chooseModel(model)
                }) {
                    Text(text(for: model))
                }
            }
        } label: {
            Text(label)
                .foregroundColor(store.composer.model == .inherited ? .secondary : .primary)
                .font(ChromeType.body.weight(.medium))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .fixedSize()
        .help(help)
    }

    /// The chip names what the next session will run as, never the bare word:
    /// Default is not a thing you can pick any more, so there is always a value
    /// standing behind it. It falls back to that word only where nothing has
    /// resolved and nothing was picked — the CLI choosing something of its own
    /// that nothing here can name.
    private var label: String {
        chosen.flatMap { store.modelName(for: $0) }
            ?? chosen?.menuLabel
            ?? SessionModel.inherited.menuLabel
    }

    /// Every row is named by the CLI or none is, so until the names land the
    /// menu falls back to the class names it knows.
    private func text(for model: SessionModel) -> String {
        let name = store.modelName(for: model) ?? model.menuLabel
        guard model == defaultModel else { return name }
        return DefaultLabel.text(for: name, open: true)
    }

    private var help: String {
        let source = store.composer.model == .inherited ? ", from your settings" : ""
        let line = (chosen ?? store.composer.model).label.map {
            "New sessions start with --model \($0)\(source)"
        } ?? "New sessions start on whichever model the CLI picks"
        return "\(line)\n\(sessionHelp)"
    }

    private var sessionHelp: String {
        return "A coding session in the folder above, with every tool"
    }
}

/// How hard the next session thinks.
struct ComposerEffortPicker: View {
    @Bindable var store: SessionStore

    private var rows: [EffortLevel] {
        EffortLevel.shown(keeping: store.composer.effort, accepting: store.acceptedEfforts)
    }

    private var defaultEffort: EffortLevel? { store.composerDefaultEffort }

    private var chosen: EffortLevel? {
        store.composer.effort == .inherited ? defaultEffort : store.composer.effort
    }

    var body: some View {
        Menu {
            ForEach(rows, id: \.self) { effort in
                Toggle(isOn: menuCheck(effort == chosen) {
                    store.composer.chooseEffort(effort)
                }) {
                    Text(text(for: effort))
                }
                .disabled(!effort.isLaunchable)
            }
        } label: {
            Text(chosen?.menuLabel ?? EffortLevel.inherited.menuLabel)
                .foregroundColor(store.composer.effort == .inherited ? .secondary : .primary)
                .font(ChromeType.body.weight(.medium))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .fixedSize()
        .help(help)
    }

    /// `max` is drawn and cannot be picked, so its row is the only place the
    /// reason fits.
    private func text(for effort: EffortLevel) -> String {
        if !effort.isLaunchable {
            return "\(effort.menuLabel) — only once a session is running"
        }
        guard effort == defaultEffort else { return effort.menuLabel }
        return DefaultLabel.text(for: effort.menuLabel, open: true)
    }

    private var help: String {
        guard let label = (chosen ?? store.composer.effort).label else {
            return "New sessions think at whatever effortLevel your settings say"
        }
        let source = store.composer.effort == .inherited ? ", from your settings" : ""
        return "New sessions think at \(label)\(source)"
    }
}

struct ComposerSendButton: View {
    let store: SessionStore
    let isEnabled: Bool
    let dispatch: () -> Void

    var body: some View {
        Button(action: dispatch) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: ChromeMetrics.sendButton))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? ChromeColor.accent : ChromeColor.muted)
        .disabled(!isEnabled)
        .help(help)
    }

    private var help: String {
        return "Dispatch in \(Format.tildePath(store.composerTarget))"
    }
}
