import Foundation

/// What the model chip says, and on whose word. The transcript's newest turn
/// is the model that actually answered and always wins. Before a first reply
/// exists the app is not guessing either: a hosted session has no way to move
/// its model — `/model` is a terminal panel the SDK cannot type, and the SDK
/// offers no setter — so the id the CLI resolved at init, and before that the
/// name the session was launched under, are the same truth arriving early.
public struct ModelChip: Equatable, Sendable {

    public let label: String
    public let help: String

    /// The first reading that exists, in the order they can be trusted.
    /// `names` is the picker's CLI-given table, so a launch reads "Fable 5"
    /// the way its first reply will, rather than flickering through "Fable".
    /// `defaultModel` is what the session's folder resolves Default to —
    /// per directory, off `resolveSettings`, the same reading the effort and
    /// style Default rows rest on — so a Default launch is named at once too.
    /// The chip stays absent only where nothing on disk or over the wire has
    /// said: absence is the app declining to guess.
    public static func reading(
        answered: String?,
        resolved: String?,
        launched: SessionModel?,
        defaultModel: HostDefaults.Model = .unanswered,
        names: [SessionModel: String] = [:]
    ) -> ModelChip? {
        if let answered {
            return ModelChip(
                label: ModelName.display(for: answered),
                help: "This session is answering as \(answered)"
            )
        }
        if let resolved {
            return ModelChip(
                label: ModelName.display(for: resolved),
                help: "This session is starting as \(resolved)"
            )
        }
        guard let launched else { return nil }
        if let alias = launched.label {
            return ModelChip(
                label: names[launched] ?? launched.menuLabel,
                help: "This session was launched as \(alias)"
            )
        }
        switch defaultModel {
        // A Default launch is named from the folder's own settings when they
        // pin a model — resolveSettings' answer for that directory, not a
        // cache read somewhere else. `settled` routes the pin through the
        // picker's table so "sonnet" reads "Sonnet 5" the way init will. A
        // blank pin names nothing and stays absent, rather than wearing the
        // word "Default" as if it were a model.
        case .named(let pinned):
            let model = SessionModel(stored: pinned).settled
            guard model.label != nil else { return nil }
            return ModelChip(
                label: names[model] ?? model.menuLabel,
                help: "This session was launched on Default — this folder's settings say \(pinned)"
            )
        // The resolver answered and no file names one, so the CLI's built-in
        // default applies — which no directory moves, making the picker's
        // Default-row name safe here where it wasn't as a guess for a folder
        // that had a pin.
        case .unnamed:
            guard let name = names[.inherited] else { return nil }
            return ModelChip(
                label: name,
                help: "This session was launched on Default — currently \(name)"
            )
        // No resolver ever answered — an older host, or an SDK without one.
        // The cached name proves nothing about this folder, so the chip waits
        // for init rather than asserting it.
        case .unanswered:
            return nil
        }
    }
}
