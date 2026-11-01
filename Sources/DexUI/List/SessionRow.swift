import DexCore
import AppKit
import SwiftUI

struct SessionRows: View {
    let items: [SessionListItem]
    let store: SessionStore
    let openPane: (SessionRowModel) -> Void
    let openStarting: (PendingDispatch) -> Void
    let projectLabels: RowProjectLabels
    let isLazy: Bool

    var body: some View {
        RowStack(isLazy: isLazy) {
            ForEach(items) { item in
                switch item {
                case .starting(let pending):
                    PendingRow(pending: pending, store: store, open: openStarting)
                case .session(let row):
                    SessionRow(row: row, store: store, openPane: openPane,
                               projectLabels: projectLabels)
                }
            }
        }
    }
}

/// The popover measures its own height off its content, so only the window can be lazy.
struct RowStack<Content: View>: View {
    let isLazy: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isLazy {
            LazyVStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

struct SessionRow: View {
    let row: SessionRowModel
    let store: SessionStore
    let openPane: (SessionRowModel) -> Void

    let projectLabels: RowProjectLabels

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @State private var pendingName: String?
    @FocusState private var isNameFocused: Bool

    private var session: AgentSession { row.session }

    private var isAttached: Bool {
        store.pane.attachment?.hostKey == row.rowID
    }

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            StateGlyph(row: row)
                .padding(.top, ChromeMetrics.glyphTopInset)

                .help(Presentation.glyphHelp(for: row))

            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                titleLine
                qualifierLine
                summaryLine
            }
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.listRowVertical)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovering = $0 }

        .onTapGesture { if !isRenaming { openPane(row) } }
        .contextMenu {
            Button("Rename…") { beginRename() }
                .disabled(!store.canRename(row))
            Button("Copy Link to Session") { copyLink() }
                .disabled(session.sessionId == nil)
        }
    }

    private func beginRename() {
        draft = session.chosenName ?? ""
        isRenaming = true
        DispatchQueue.main.async { isNameFocused = true }
    }

    private func endRename(saving: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard saving, !name.isEmpty else { return }
        store.rename(row, to: name)
        pendingName = name
    }

    private func copyLink() {
        guard let id = session.sessionId else { return }
        let link = SessionLink(
            sessionID: id,
            name: session.name,
            cwd: session.cwd
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            link.url(scheme: store.flavor.linkScheme).absoluteString, forType: .string
        )
    }

    private var rowBackground: some View {
        RowHighlight(isAttached: isAttached, isHovering: isHovering)
    }

    private var isSettled: Bool { store.resolutions.isSettled(row) }

    private var canBeResolved: Bool { isSettled || store.resolutions.canResolve(row) }

    private var showsResolve: Bool { isHovering && canBeResolved }

    /// The age keeps the slot the button borrows, so the title doesn't move under the pointer.
    private var ageOrResolve: some View {
        Text(Format.age(since: row.lastUpdatedAt))
            .font(ChromeType.body.monospaced())
            .foregroundStyle(.secondary)
            .opacity(showsResolve ? 0 : 1)
            .frame(minWidth: ChromeMetrics.resolveSlot, alignment: .trailing)
            .overlay(alignment: .trailing) { resolveButton }
            .help(trailingHelp)
    }

    /// The button covers the age it replaces, so the one tooltip has to say both.
    private var trailingHelp: String {
        let age = Presentation.ageHelp(for: row)
        guard showsResolve else { return age }
        return "\(isSettled ? "Unresolve" : "Resolve") · \(age)"
    }

    @ViewBuilder
    private var resolveButton: some View {
        if canBeResolved {
            Button {
                if isSettled { store.unresolve(row) } else { store.resolve(row) }
            } label: {
                Image(systemName: isSettled ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(ChromeType.control)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSettled ? Color.secondary : Color.primary)
            .opacity(showsResolve ? 1 : 0)
            .allowsHitTesting(showsResolve)
        }
    }

    @ViewBuilder
    private var name: some View {
        if isRenaming {
            TextField("Session name", text: $draft)
                .textFieldStyle(.plain)
                .font(ChromeType.title.weight(.medium))
                .focused($isNameFocused)
                .onSubmit { endRename(saving: true) }
                .onExitCommand { endRename(saving: false) }
                .onChange(of: isNameFocused) { _, focused in
                    if !focused { endRename(saving: true) }
                }
        } else {
            Text(pendingName ?? session.displayName)
                .font(ChromeType.title.weight(.medium))
                .lineLimit(1)
                .onChange(of: session.chosenName) { pendingName = nil }
                .task(id: pendingName) {
                    guard pendingName != nil else { return }
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { pendingName = nil }
                }
        }
    }

    private var titleLine: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {

            name

            Spacer(minLength: ChromeMetrics.iconGap)

            ageOrResolve
        }
    }

    @ViewBuilder
    private var qualifierLine: some View {
        let idleHelp = Presentation.activityHelp(for: row)
        let project: String? =
            projectLabels.label(for: row)

        let merge = row.mergeStatus.flatMap { $0.isNotable ? $0 : nil }
        if idleHelp != nil || project != nil || merge != nil
            || row.origin != nil
        {
            HStack(spacing: ChromeMetrics.inlineGap) {
                if let parent = row.origin?.parent {
                    let from = store.snapshot.rows.first { $0.rowID == parent }
                    Button {
                        if let id = from?.session.sessionId { store.focus(sessionID: id) }
                    } label: {
                        HStack(spacing: ChromeMetrics.iconGap) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(ChromeType.inlineIcon)
                            Text(from?.session.displayName ?? "another session")
                                .font(ChromeType.meta)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Started by \(from?.session.displayName ?? "another session") · click to go to it")
                } else if let origin = row.origin, let watcher = origin.watcher {
                    Button {
                        store.watcherFilter = watcher
                    } label: {
                        HStack(spacing: ChromeMetrics.iconGap) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(ChromeType.inlineIcon)
                            Text(watcher)
                                .font(ChromeType.meta)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(
                        ["Started by \(watcher)", origin.reason].compactMap { $0 }.joined(separator: ": ")
                            + " · click to show only its sessions"
                    )
                }

                if let idleHelp {
                    Text("idle")
                        .font(ChromeType.meta)
                        .foregroundStyle(.tertiary)
                        .help(idleHelp)
                }

                if let project {
                    HStack(spacing: ChromeMetrics.iconGap) {
                        Image(systemName: "folder")
                            .font(ChromeType.inlineIcon)
                        Text(project)
                            .font(ChromeType.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                    .help(projectLabels.path(for: row))
                }

                if let merge {
                    MergeStatusBadge(status: merge)
                }
            }
        }
    }

    private var summaryLine: some View {
        Text(SessionDigestReader.inlineMarkdown(row.summary))
            .font(ChromeType.body)
            .foregroundStyle(session.isAsking ? .primary : .secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The list's own selection: the row whose session the pane is holding.
struct RowHighlight: View {
    let isAttached: Bool
    let isHovering: Bool

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        RoundedRectangle(cornerRadius: ChromeMetrics.selectionCorner, style: .continuous)
            .fill(fill)
            .padding(.horizontal, ChromeMetrics.selectionInset)
            .padding(.vertical, ChromeMetrics.selectionVertical)
    }

    private var fill: Color {
        if isAttached {
            return ChromeColor.accentTint.opacity(activeState == .inactive
                ? ChromeMetrics.attachedInactiveTint
                : ChromeMetrics.attachedTint)
        }
        if isHovering { return Color.primary.opacity(ChromeMetrics.hoverTint) }
        return .clear
    }
}

struct PendingRow: View {
    let pending: PendingDispatch
    let store: SessionStore
    let open: (PendingDispatch) -> Void

    @State private var isHovering = false

    private var isAttached: Bool { store.pane.starting?.id == pending.id }

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            WorkingSpinner(color: Presentation.color(for: .running))
                .frame(width: StateGlyph.Metrics.slot, height: StateGlyph.Metrics.slot)
                .padding(.top, ChromeMetrics.glyphTopInset)

            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                titleLine
                stateLine
                summaryLine
            }
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.listRowVertical)
        .contentShape(Rectangle())
        .background(RowHighlight(isAttached: isAttached, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .onTapGesture { open(pending) }
    }

    private var titleLine: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {

            Text(pending.title)
                .font(ChromeType.title.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: ChromeMetrics.iconGap)

            Text(Format.age(since: pending.startedAt))
                .font(ChromeType.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var stateLine: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {

            Text("starting…")
                .font(ChromeType.meta.weight(.semibold))
                .foregroundStyle(.tertiary)

            Text(Format.shortPath(pending.project))
                .font(ChromeType.meta)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(pending.project)
        }
    }

    /// What was typed, in the slot the session's own last line will take over,
    /// so the row it becomes is the same row rather than a new one.
    @ViewBuilder
    private var summaryLine: some View {
        if let opening = pending.opening {
            Text(opening)
                .font(ChromeType.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
