import Foundation

/// How a session writes. `.inherited` sends nothing and leaves `outputStyle` in
/// the settings files to decide, which is where the CLI's own `/output-style`
/// puts its answer.
///
/// Bound at launch, and as of CLI v2.1.278 that is the app's choice rather than
/// the SDK's limit. All three routes were re-measured there: `settings` at
/// launch reaches the model, as it always did; `applyFlagSettings` now takes an
/// `outputStyle` and the *next* turn writes in it, where through SDK 0.3.241 it
/// was accepted and silently dropped; and `/output-style` now answers `Output
/// style set to <name>` and writes the name to the cwd's
/// `.claude/settings.local.json`, where it used to answer "isn't available in
/// this environment" — though the flag layer outranks that file, so a session
/// started with a style keeps it.
///
/// So this stays one app-wide choice rather than a dial per session, and a dial
/// no longer needs a resume to keep its word. Deferred, not impossible: nothing
/// here has asked for per-row voices yet.
public enum OutputStyle: Sendable, Hashable {

    case inherited

    case named(String)

    /// What the host is told, or nothing to leave the settings files to it.
    public var hostStyleID: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    public var label: String? {
        switch self {
        case .inherited: nil
        case .named(let name): name
        }
    }

    /// The CLI's own name for having none, which it lists beside the rest. It is
    /// dropped from the picker: sending nothing already means this, and a row
    /// that reads "Default" beside the one meaning "whatever your settings say"
    /// is two rows for one answer.
    static let none = "default"

    /// What the picker offers, from the list the CLI reported. Styles are files
    /// on disk — built in, in the config directory, and in a project's own — so
    /// there is no table here to go stale, and nothing is offered that the CLI
    /// has not said it has.
    ///
    /// A stored style missing from that list is kept rather than dropped: an
    /// empty list is a host that has not run a session yet, not a style that
    /// went away, and dropping it there would silently move every new session
    /// back to the settings files.
    public static func offered(
        from styles: [String],
        keeping stored: OutputStyle = .inherited
    ) -> [OutputStyle] {
        var offered: [OutputStyle] =
            [.inherited] + styles.filter { $0 != none }.map(OutputStyle.named)
        if !offered.contains(stored) { offered.append(stored) }
        return offered
    }

    /// Left as the CLI writes it. These are names someone chose — `Concise`,
    /// `ELI5`, whatever is in a file of their own — so capitalising them is
    /// rewriting them.
    public var menuLabel: String { label ?? "Default" }

    /// Anything blank reads as no choice, so a key never written and one cleared
    /// agree.
    public init(stored: String?) {
        guard let stored else {
            self = .inherited
            return
        }
        let name = stored.trimmingCharacters(in: .whitespaces)
        self = name.isEmpty || name == Self.none ? .inherited : .named(name)
    }

    public var stored: String? { label }
}
