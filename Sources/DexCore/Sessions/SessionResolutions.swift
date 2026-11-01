import Foundation

public struct SessionResolutions: Codable, Hashable, Sendable {

    public static let pruneWindow: TimeInterval = 24 * 60 * 60

    var marks: [String: Date]

    public init(marks: [String: Date] = [:]) {
        self.marks = marks
    }

    public var isEmpty: Bool { marks.isEmpty }

    public var stored: [String: Date] { marks }

    public mutating func resolve(_ row: SessionRowModel, at now: Date = Date()) {
        marks[row.rowID] = max(now, row.lastUpdatedAt)
    }

    public mutating func clear(_ row: SessionRowModel) {
        marks.removeValue(forKey: row.rowID)
    }

    public func isSettled(_ row: SessionRowModel) -> Bool {
        guard let mark = marks[row.rowID] else { return false }
        return mark >= row.lastUpdatedAt
    }

    public func canResolve(_ row: SessionRowModel, now: Date = Date()) -> Bool {
        guard !isSettled(row) else { return false }
        return row.session.hasFinishedWorking || row.isAsking || row.isIdleWhileWorking(now: now)
    }

    public func isWaitingOnYou(_ row: SessionRowModel) -> Bool {
        row.isAsking && !isSettled(row)
    }

    public func resolvable(in rows: [SessionRowModel]) -> [SessionRowModel] {
        rows.filter {
            $0.session.hasFinishedWorking
                && !isSettled($0)
                && $0.mergeStatus?.isNotable != true
        }
    }

    public mutating func resolveAll(in rows: [SessionRowModel], at now: Date = Date()) {
        for row in resolvable(in: rows) { resolve(row, at: now) }
    }

    public func split(_ rows: [SessionRowModel]) -> SessionSections {
        var active: [SessionRowModel] = []
        var settled: [SessionRowModel] = []
        for row in rows {
            if isSettled(row) { settled.append(row) } else { active.append(row) }
        }
        return SessionSections(active: active, settled: settled)
    }

    public mutating func prune(
        keeping rowIDs: Set<String>,
        window: TimeInterval = SessionResolutions.pruneWindow,
        now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-window)
        marks = marks.filter { rowIDs.contains($0.key) || $0.value >= cutoff }
    }
}


public struct SessionSections: Sendable, Hashable {

    public var active: [SessionRowModel]

    public var settled: [SessionRowModel]

    public init(active: [SessionRowModel] = [], settled: [SessionRowModel] = []) {
        self.active = active
        self.settled = settled
    }

    public static func counts(_ row: SessionRowModel, resolutions: SessionResolutions) -> Bool {
        !resolutions.isSettled(row)
    }
}
