import DexCore
import AppKit
import SwiftUI

/// The header's way into the watcher list. Icon-only, since the header is
/// already full in the popover; it counts only what needs looking at, and is
/// absent on a Mac with no watchers at all.
struct WatchersChip: View {
    @Bindable var store: SessionStore
    let layout: ListLayout

    @State private var showsLocally = false

    private var attention: Int { store.watchers.needingAttention.count }

    /// The window's own is the store's, so a notification can open it; the
    /// popover keeps its own so the two don't open together.
    private var isShown: Binding<Bool> {
        layout == .window ? $store.showsWatchers : $showsLocally
    }

    var body: some View {
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            HStack(spacing: ChromeMetrics.iconGap) {
                Image(systemName: attention > 0 ? "clock.badge.exclamationmark" : "clock.arrow.circlepath")
                    .font(ChromeType.control)
                if attention > 0 {
                    Text("\(attention)")
                        .font(ChromeType.meta.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(attention > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .help(help)
        .popover(isPresented: isShown, arrowEdge: .bottom) {
            WatchersPanel(store: store)
        }
    }

    private var help: String {
        switch attention {
        case 0: "Background watchers"
        case 1: "1 background watcher needs a look"
        default: "\(attention) background watchers need a look"
        }
    }
}

struct WatchersPanel: View {
    let store: SessionStore

    private var ordered: [BackgroundWatcher] {
        let attention = Set(store.watchers.needingAttention.map(\.id))
        return store.watchers.watchers.filter { attention.contains($0.id) }
            + store.watchers.watchers.filter { !attention.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, watcher in
                    if index > 0 { Divider() }
                    WatcherCard(store: store, watcher: watcher)
                }
                if store.watchers.watchers.isEmpty {
                    Text("No status files in \(store.watchers.directory.path)")
                        .font(ChromeType.meta)
                        .foregroundStyle(.secondary)
                        .padding(ChromeMetrics.horizontal)
                }
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 520)
    }
}

private struct WatcherCard: View {
    let store: SessionStore
    let watcher: BackgroundWatcher

    @State private var showsLog = false
    @State private var log: [String]?
    @State private var runError: String?
    @State private var isKicking = false

    private var health: BackgroundWatcherHealth { store.watchers.health(of: watcher) }
    private var status: BackgroundWatcherStatus? { watcher.status }
    private var now: Date { store.watchers.now }

    private var sessionCount: Int {
        store.snapshot.rows.filter { $0.origin?.watcher == watcher.name }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap + 2) {
            header
            if let description = status?.description {
                Text(description)
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .unreadable(let reason) = health.condition {
                problem(reason)
            }
            lastRun
            timing
            if health.isNewerFormat {
                Text("Written in a newer format (v\(status?.version ?? 0)); some fields may be missing.")
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
            }
            if showsLog, let log { logView(log) }
            actions
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.rowVertical + 2)
    }

    private var tint: Color {
        if health.needsAttention { return .orange }
        switch health.condition {
        case .ok: return .green
        default: return .secondary
        }
    }

    private var header: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(watcher.name)
                .font(ChromeType.title.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: ChromeMetrics.iconGap)
            Text(BackgroundWatcherAlert.headline(watcher, health))
                .font(ChromeType.meta)
                .foregroundStyle(health.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    @ViewBuilder
    private var lastRun: some View {
        if let run = status?.lastRun {
            let line = ["Last ran \(Format.age(since: run.finishedAt, now: now)) ago", run.summary]
                .compactMap { $0 }
                .joined(separator: " · ")
            Text(line)
                .font(ChromeType.meta)
                .fixedSize(horizontal: false, vertical: true)
            if let error = run.error { problem(error) }
        }
    }

    private func problem(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.meta.monospaced())
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var timing: some View {
        let parts: [String] = [
            status?.lastSuccessAt.map { "last success \(Format.age(since: $0, now: now)) ago" }
                ?? (status?.lastRun == nil ? nil : "no success on record"),
            health.nextRunAt.map { nextRun($0) },
            launchdLine,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextRun(_ date: Date) -> String {
        if date.timeIntervalSince(now) < 60 { return "next run due now" }
        if date.timeIntervalSince(now) < 12 * 60 * 60 {
            return "next run in \(Format.age(since: now, now: date))"
        }
        return "next run \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var launchdLine: String? {
        guard health.isStale, let label = status?.launchdLabel,
            let state = store.watchers.launchd[label]
        else { return nil }
        guard state.loaded else { return "launchd job \(label) isn't loaded" }
        return state.detail.map { "launchd: \($0)" }
    }

    private func logView(_ lines: [String]) -> some View {
        Text(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private var actions: some View {
        HStack(spacing: ChromeMetrics.controlGap) {
            if sessionCount > 0 {
                Button(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions") {
                    store.watcherFilter = watcher.name
                    store.showsWatchers = false
                }
                .help("Show only the sessions \(watcher.name) started")
            }
            if let path = status?.expandedLogPath {
                Button(showsLog ? "Hide log" : "Log") {
                    if !showsLog { log = BackgroundWatcher.logTail(path: path) ?? ["(can't read \(path))"] }
                    showsLog.toggle()
                }
                Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            if status?.launchdLabel != nil {
                Button(isKicking ? "Starting…" : "Run Now") {
                    isKicking = true
                    runError = nil
                    store.watchers.runNow(watcher) { error in
                        isKicking = false
                        runError = error
                    }
                }
                .disabled(isKicking)
            }
            Spacer(minLength: 0)
            if let runError {
                Text(runError)
                    .font(ChromeType.meta)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}

/// What the list is narrowed to when a watcher's sessions are picked, with the
/// way back out.
struct WatcherFilterBar: View {
    @Bindable var store: SessionStore

    var body: some View {
        if let watcher = store.watcherFilter {
            HStack(spacing: ChromeMetrics.iconGap) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(ChromeType.inlineIcon)
                Text("Started by \(watcher)")
                    .font(ChromeType.meta)
                    .lineLimit(1)
                Spacer(minLength: ChromeMetrics.iconGap)
                Button {
                    store.watcherFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(ChromeType.control)
                }
                .buttonStyle(.plain)
                .help("Show every session")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, ChromeMetrics.listHorizontal)
            .padding(.bottom, ChromeMetrics.iconGap)
        }
    }
}
