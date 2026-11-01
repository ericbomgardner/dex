import Foundation

/// How hard a session thinks. `.inherited` sends nothing and leaves the settings
/// files to resolve it, which is what `effortLevel` in `settings.json` is for.
///
/// Moved while a session runs by `applyFlagSettings`, with the next turn
/// running at the new level. Measured, and measured again each time the SDK
/// moves: the same call took an output style and did nothing about it until
/// CLI v2.1.278.
public enum EffortLevel: Sendable, Hashable {

    case inherited

    case named(String)

    /// What the host is told: the bare level, or nothing at all.
    public var hostEffortID: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    public var label: String? {
        switch self {
        case .inherited: nil
        case .named(let name): name
        }
    }

    /// What a new session may start at. It stops one short of the dial's list,
    /// and the gap is measured rather than chosen: `max` handed to `settings` at
    /// launch does not hold, so a row offering it would be a row that quietly
    /// sends you somewhere else. The SDK's own types draw the same line —
    /// `Settings.effortLevel` ends at `xhigh` — which is the reason to expect
    /// it, not the evidence for it.
    ///
    /// `xhigh` is on this list on its own measurement, not by being the top of
    /// the range: the probe starts a session at `xhigh` and reads `xhigh` back
    /// off `CLAUDE_EFFORT`. It has to be asked separately, because where `max`
    /// lands is no longer where the list ends.
    static let launchNames = ["low", "medium", "high", "xhigh"]

    /// What goes out in place of `max` at launch. The CLI doesn't clamp `max`
    /// there, it drops it and starts at Default, so this is the app's choice of
    /// the nearest level that holds, not a measured landing place. The
    /// "`xhigh` through v2.1.269, `high` on v2.1.278" history was the probe
    /// reading each machine's own `settings.json`.
    static let capped = "xhigh"

    /// The one level a running session can be moved to and a new one cannot be
    /// started at.
    static let sessionOnly = "max"

    /// What a running session may be moved to. `max` is here and nowhere else:
    /// it is session-scoped by design, never written to a settings file, and
    /// `applyFlagSettings` is the one door it fits through.
    static let dialNames = launchNames + [sessionOnly]

    /// Whether the composer can send this level, which is not the same as
    /// whether it draws it. Measured: `max` handed to `settings` at launch is
    /// dropped for Default, so a row that sent it would put the session
    /// somewhere it was never asked to go.
    public var isLaunchable: Bool { hostEffortID != Self.sessionOnly }

    /// What to start a session at to land where a running one already thinks —
    /// which is what resuming one is. `max` is the only level that moves:
    /// handed to `settings` it is dropped for Default, so replaying it would
    /// leave the resumed session recorded at a level it is not running at. It
    /// goes back out as `capped`.
    public var launchable: EffortLevel { isLaunchable ? self : .named(Self.capped) }

    /// What the composer's picker offers. A stored level the CLI no longer takes
    /// is kept rather than dropped, the way the model and mode pickers keep one
    /// — dropping it moves the next session somewhere you didn't ask for.
    ///
    /// `accepting` is what the host said it takes, which is not the same list:
    /// the host outlives the app, so one started before this existed refuses
    /// every level by name. Empty means nothing has said otherwise and
    /// everything is offered.
    public static func offered(
        keeping stored: EffortLevel = .inherited,
        accepting: [String] = []
    ) -> [EffortLevel] {
        offered(from: launchNames, keeping: stored, accepting: accepting)
    }

    /// What the composer draws: the levels, and no Default among them.
    ///
    /// Default was a row of its own, which put the same level on the menu
    /// twice — one entry sending nothing and following the settings files,
    /// another sending the level those files resolve to, the two reading alike
    /// and landing in the same place. The difference between them is real and
    /// it is not worth a row. So the levels are the rows, whichever one the
    /// files land on wears a marker, and picking any of them pins it.
    ///
    /// One row longer than what it will send: `max` is on the list and cannot
    /// be picked. Left off entirely — which is where it was — the omission was
    /// the only thing on screen about it, and it read as the app not having the
    /// level rather than the level not being startable, since the pane's dial
    /// carries `max` and this list did not. Drawn live it would be worse, since
    /// what it sends is dropped for Default — not where it read. So it is
    /// drawn dead, and the row is where the reason goes.
    ///
    /// `max` is filtered on the dial's list rather than the launch one, so a
    /// host that has never heard of it doesn't get a row explaining a level
    /// nothing here could reach anyway.
    public static func shown(
        keeping stored: EffortLevel = .inherited,
        accepting: [String] = []
    ) -> [EffortLevel] {
        let rows = offered(keeping: stored, accepting: accepting)
            .filter { $0 != .inherited }
        let maxRow = EffortLevel.named(sessionOnly)
        guard dialled(accepting: accepting).contains(maxRow), !rows.contains(maxRow) else {
            return rows
        }
        return rows + [maxRow]
    }

    /// Which row the settings files land on, or nil where they name a level
    /// this picker doesn't carry. Marking nothing is the right answer there:
    /// a settings file can say anything, and putting the marker on the nearest
    /// row would be the app claiming a level it isn't going to run at.
    public static func matchingDefault(
        in rows: [EffortLevel],
        resolved: String?
    ) -> EffortLevel? {
        guard let resolved else { return nil }
        return rows.first { $0.label == resolved }
    }

    /// What to send, with Default resolved to the level it stood for. Nothing
    /// sends `default` any more: a session started while the picker read
    /// `Xhigh` runs at `xhigh`, whether that came from a settings file or from
    /// a click — measured, since `max` asked for at launch does not hold.
    /// Nil only where nothing resolved either — the CLI falling back to
    /// something of its own that nothing here can name.
    public func launching(default resolved: EffortLevel?) -> String? {
        hostEffortID ?? resolved?.hostEffortID
    }

    /// What the pane's dial offers: the launch list plus `max`, and no Default.
    ///
    /// Leaving it to the settings files is a thing to start a session as, not a
    /// thing to move one back to — `.inherited` is the absence of a level, and
    /// what the host would be sent for it is nothing. Offered, it was a row that
    /// took the click and did nothing at all, since there was no name to send.
    /// A session sitting at Default is still labelled Default; it simply has no
    /// row of its own to go back to.
    public static func dialled(
        keeping current: EffortLevel = .inherited,
        accepting: [String] = []
    ) -> [EffortLevel] {
        var offered = dialNames
            .filter { accepting.isEmpty || accepting.contains($0) }
            .map(EffortLevel.named)
        if case .named = current, !offered.contains(current) { offered.append(current) }
        return offered
    }

    private static func offered(
        from names: [String],
        keeping stored: EffortLevel,
        accepting: [String]
    ) -> [EffortLevel] {
        var offered: [EffortLevel] =
            [.inherited]
            + names.filter { accepting.isEmpty || accepting.contains($0) }.map(EffortLevel.named)
        if !offered.contains(stored) { offered.append(stored) }
        return offered
    }

    /// `xhigh` reads as one word everywhere the CLI writes it, so it reads as
    /// one word here.
    public var menuLabel: String {
        guard let label else { return "Default" }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Anything blank reads as no choice, so a key never written and one cleared
    /// agree.
    public init(stored: String?) {
        guard let stored else {
            self = .inherited
            return
        }
        let name = stored.trimmingCharacters(in: .whitespaces)
        self = name.isEmpty ? .inherited : .named(name)
    }

    public var stored: String? { label }
}
