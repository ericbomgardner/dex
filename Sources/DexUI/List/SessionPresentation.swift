import DexCore
import SwiftUI

@MainActor
enum Presentation {
    static func color(for state: HostSessionState) -> Color {
        switch state {
        case .asking: .orange
        case .starting, .running, .compacting, .unknown: ChromeColor.accent
        case .done: .green
        case .failed: .red
        case .idle: .secondary
        }
    }

    /// A row can be working before the CLI's record of it says so, and the record
    /// is where the colour would otherwise come from — leaving a session you have
    /// just sent to spinning in the green of the turn it finished.
    static func color(for row: SessionRowModel, now: Date = Date()) -> Color {
        if row.isIdleWhileWorking(now: now) { return .secondary }
        if row.isWorking { return ChromeColor.accent }
        return color(for: row.session.state)
    }

    static func activityHelp(for row: SessionRowModel, now: Date = Date()) -> String? {
        guard row.isIdleWhileWorking(now: now), let last = row.lastActivityAt else { return nil }

        return "recorded state is working, but nothing has run for \(Format.preciseAge(since: last, now: now))"
    }

    /// What the row is doing, in the word the list would use for it. The CLI's
    /// own word, except while the transcript is ahead of it — a turn it has been
    /// handed and not yet written down.
    static func word(for row: SessionRowModel) -> String {
        if row.isWorking { return "working" }
        return row.session.stateWord
    }

    static func ageHelp(for row: SessionRowModel, now: Date = Date()) -> String {
        let updated = Format.age(since: row.lastUpdatedAt, now: now)
        let started = Format.age(since: row.startedAt, now: now)
        guard started != updated else { return "last update \(updated) ago" }
        return "last update \(updated) ago · process started \(started) ago"
    }

    static func symbol(for session: AgentSession) -> String {
        session.isLive ? "circle.fill" : "circle"
    }

    static func livenessHelp(for session: AgentSession) -> String {
        if let pid = session.hostPID {
            return "process running (pid \(pid))"
        }
        // The gesture that reopens a session is the gesture that speaks to it,
        // since a resumed one stays dark until it is spoken to.
        return "not running — the conversation is on disk; typing picks it up"
    }

    static func glyphHelp(for row: SessionRowModel, now: Date = Date()) -> String {
        let rest = activityHelp(for: row, now: now) ?? livenessHelp(for: row.session)
        return "\(word(for: row)) · \(rest)"
    }
}

struct StateGlyph: View {
    let row: SessionRowModel
    let now: Date

    init(row: SessionRowModel, now: Date = Date()) {
        self.row = row
        self.now = now
    }

    var body: some View {
        Group {
            if row.isActivelyWorking(now: now) {
                WorkingSpinner(color: Presentation.color(for: row, now: now))
            } else {
                Image(systemName: Presentation.symbol(for: row.session))
                    .font(.system(size: Metrics.diameter))
                    .foregroundStyle(Presentation.color(for: row, now: now))
            }
        }

        .frame(width: Metrics.slot, height: Metrics.slot)
    }

    enum Metrics {

        static let diameter: CGFloat = 10

        static let slot: CGFloat = diameter + 1
        static let stroke: CGFloat = 1.5

        static let arc: CGFloat = 0.3
    }
}

struct WorkingSpinner: View {
    let color: Color

    var body: some View {

        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0, to: StateGlyph.Metrics.arc)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: StateGlyph.Metrics.stroke, lineCap: .round)
                )

                .padding(StateGlyph.Metrics.stroke / 2)
                .frame(width: StateGlyph.Metrics.diameter, height: StateGlyph.Metrics.diameter)
                .rotationEffect(.degrees(SpinnerPhase.turns(at: context.date) * 360))
        }
    }
}
