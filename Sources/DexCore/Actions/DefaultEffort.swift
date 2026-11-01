import Foundation

/// The level a session of one model starts at with nothing picked.
///
/// Since `/effort` went per-model the settings files no longer answer this once
/// for every model. Each file is read in precedence order, and the first that
/// answers wins: a `modelSettings` entry for the model, then the file's
/// top-level `effortLevel` — except that a top-level level in the user's own
/// file reaches only `legacyModels`, the ones released before the change (CLI
/// v2.1.280: Opus 5.5 starts at its own default there). Read out of the CLI and
/// re-checked by `Sidecar/test/effort-default-probe.ts`.
extension HostDefaults {

    /// `model` is an id (`claude-opus-5-5`) or the CLI's display name
    /// (`Opus 5.5`); nil is a model not yet known, which no per-model entry and
    /// no user-level level can be said to reach.
    public func effort(forModel model: String?) -> String? {
        guard let efforts else { return effort }
        let name = model.map(Self.normalised)
        let legacy = name.map(Self.legacyNames.contains) ?? false
        for file in efforts {
            if let name,
               let level = file.models.first(where: { Self.normalised($0.key) == name })?.value,
               Self.answers(level) {
                return level
            }
            if let level = file.effort, Self.answers(level), file.source != "user" || legacy {
                return level
            }
        }
        return nil
    }

    /// The CLI's own list, copied: a user-level `effortLevel` still reaches
    /// these, and nothing released after them.
    static let legacyModels = [
        "claude-3-5-haiku", "claude-3-5-sonnet", "claude-3-7-sonnet",
        "claude-haiku-4-5", "claude-sonnet-4-0", "claude-sonnet-4-5",
        "claude-sonnet-4-6", "claude-sonnet-5", "claude-opus-4-0",
        "claude-opus-4-1", "claude-opus-4-5", "claude-opus-4-6",
        "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
        "claude-fable-5", "claude-fable-5-1", "claude-mythos-5",
        "claude-mythos-5-1",
    ]

    private static let legacyNames = Set(legacyModels.map(normalised))

    private static func normalised(_ model: String) -> String {
        ModelName.display(for: model).lowercased()
    }

    /// The CLI drops a `max` in a file and asks the next one.
    private static func answers(_ level: String) -> Bool {
        level != EffortLevel.sessionOnly
    }
}
