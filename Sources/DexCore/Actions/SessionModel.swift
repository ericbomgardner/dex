import Foundation

/// Which model a new session starts on. `.inherited` sends no flag and lets the
/// CLI pick.
public enum SessionModel: Sendable, Hashable {

    case inherited

    case alias(String)

    public var flagArguments: [String] {
        switch self {
        case .inherited: []
        case .alias(let name): ["--model", name]
        }
    }

    /// What the host is told, which is the bare name rather than a flag pair.
    /// Nil means "whatever the SDK would pick", the same as sending no flag.
    public var hostModelID: String? {
        if case .alias(let name) = self { return name }
        return nil
    }

    public var label: String? {
        switch self {
        case .inherited: nil
        case .alias(let name): name
        }
    }

    /// The classes the picker offers, in the order the CLI lists them. The rest
    /// of what `--model` takes is not a class to choose between: `haiku` is too
    /// small to reach for, `best` and `opusplan` pick a model rather than being
    /// one, and the widths are handled below.
    static let classes = ["sonnet", "opus", "fable"]

    /// What the picker offers. A stored name the CLI no longer lists is kept
    /// rather than dropped — dropping it moves the next session elsewhere.
    public static func offered(keeping stored: SessionModel = .inherited) -> [SessionModel] {
        var offered: [SessionModel] = [.inherited] + widest.map(SessionModel.alias)
        let settled = stored.settled
        if !offered.contains(settled) { offered.append(settled) }
        return offered
    }

    /// What the menu draws: the classes, with Default no longer among them.
    /// `offered` keeps it, because it is still a row the CLI is asked to name —
    /// that name is the only thing that says which class Default lands on.
    public static func picking(keeping stored: SessionModel = .inherited) -> [SessionModel] {
        offered(keeping: stored).filter { $0 != .inherited }
    }

    /// Which class Default lands on, found by the name the CLI gives each row:
    /// asking for no model and asking for `opus[1m]` come back named the same,
    /// and that is the only thing here that says they are one choice. Nil where
    /// the CLI picks something this menu doesn't carry — `haiku`, or a model
    /// newer than the build — since a marker on the nearest row would be the
    /// app claiming a model it isn't going to start.
    public static func matchingDefault(
        in rows: [SessionModel],
        names: [SessionModel: String]
    ) -> SessionModel? {
        guard let byDefault = names[.inherited] else { return nil }
        return rows.first { $0 != .inherited && names[$0] == byDefault }
    }

    /// There is deliberately no `launching(default:)` here, where `EffortLevel`
    /// has one. An effort resolves to the level itself and sending it is
    /// lossless; a model resolves only to the CLI's display name, and
    /// `ModelReadout` strips the context window from that — so `opus` and
    /// `opus[1m]` arrive as one string and matching back would launch a
    /// settings-pinned narrow `opus` at 1M. Default sends no flag, which lands
    /// exactly what the marker names, the CLI reading the same cascade.
    ///
    /// A name stored before the picker settled on widths is the class it names:
    /// a menu holding both `sonnet` and `sonnet[1m]` shows two rows reading
    /// "Sonnet", one of them quietly sending the other flag.
    public var settled: SessionModel {
        guard let label,
              let wide = Self.widest.first(where: { Self.family(of: $0) == Self.family(of: label) })
        else { return self }
        return .alias(wide)
    }

    static func family(of name: String) -> String {
        String(name.prefix { $0 != "[" })
    }

    /// All of them or none. A row left unnamed beside rows that carry a version
    /// reads as a difference between the models rather than an answer that
    /// hasn't arrived, which is the asymmetry naming them was for.
    public static func named(
        _ names: [SessionModel: String],
        covering rows: [SessionModel]
    ) -> [SessionModel: String] {
        rows.allSatisfy { names[$0] != nil } ? names : [:]
    }

    /// The widest context each class comes in. A bare `opus` is the narrow one,
    /// so offering it would quietly hand back context the CLI's own picker keeps
    /// — it takes `claude-fable-5[1m]` for its Fable entry.
    static var widest: [String] {
        classes.compactMap { family in
            let wide = "\(family)[1m]"
            if ModelAliases.all.contains(wide) { return wide }
            return ModelAliases.all.contains(family) ? family : nil
        }
    }

    /// What the picker shows. The choice is between classes, so the width the
    /// name carries is not part of it — `flagArguments` still sends the whole
    /// name, and the tooltip says it.
    public var menuLabel: String {
        guard let label else { return "Default" }
        let family = Self.family(of: label)
        return family.contains("-") ? ModelName.display(for: label) : family.capitalized
    }

    /// Anything blank reads as no choice, so a key never written and one
    /// cleared agree.
    public init(stored: String?) {
        guard let stored else {
            self = .inherited
            return
        }
        let name = stored.trimmingCharacters(in: .whitespaces)
        self = name.isEmpty ? .inherited : .alias(name)
    }

    public var stored: String? { label }
}

/// A model id as the transcript writes it, read back as a name: `claude-opus-5`
/// is Opus 5. By rule rather than by table, so a model released after this build
/// still reads; an id the rule doesn't fit comes back whole.
public enum ModelName {

    public static func display(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        // init reports a width variant as `claude-opus-5[1m]`; the marker
        // names the context window, not the model.
        let bare = String(trimmed.prefix { $0 != "[" })
        let prefix = "claude-"
        guard bare.hasPrefix(prefix) else { return trimmed }

        var parts = bare.dropFirst(prefix.count).split(separator: "-").map(String.init)
        if let last = parts.last, isReleaseDate(last) { parts.removeLast() }

        let family = parts.prefix { !isVersion($0) }
        // Naming that leads with the version reads backwards under this rule.
        guard !family.isEmpty else { return trimmed }

        let version = parts.dropFirst(family.count).joined(separator: ".")
        let name = family.map(\.capitalized).joined(separator: " ")
        return version.isEmpty ? name : "\(name) \(version)"
    }

    private static func isVersion(_ part: String) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isNumber)
    }

    /// An id carries its release date last, and asking for an alias is enough to
    /// get one: `--model haiku` answers as `claude-haiku-4-5-20251001`. Eight
    /// digits is the shape of that date and never the shape of a version.
    private static func isReleaseDate(_ part: String) -> Bool {
        part.count == "yyyyMMdd".count && part.allSatisfy(\.isNumber)
    }
}
