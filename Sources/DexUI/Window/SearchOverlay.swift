import DexCore
import AppKit
import SwiftUI

@MainActor
@Observable
private final class SearchModel {
    var query = ""
    var hits: [TranscriptHit] = []
    var searched = ""
    var highlighted = 0

    private var running: Task<Void, Never>?
    private var cancelled = Locked(false)

    func search() {
        running?.cancel()
        cancelled.mutate { $0 = true }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= TranscriptSearch.minimumQuery else {
            hits = []
            searched = ""
            return
        }
        let flag = Locked(false)
        cancelled = flag
        running = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                TranscriptSearch().search(query) { flag.value }
            }.value
            guard !Task.isCancelled, let self else { return }
            hits = found
            searched = query
            highlighted = 0
        }
    }
}

/// Cmd-Shift-F: every transcript the app ran, newest first.
struct SearchOverlay: View {
    @Bindable var store: SessionStore

    @State private var model = SearchModel()

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .top) {
            OverlayScrim { store.closeOverlay() }
            panel(query: $model.query)
        }
        .transition(.opacity)
    }

    private func panel(query: Binding<String>) -> some View {
        VStack(spacing: 0) {
            field(query: query)
            Divider()

            if model.hits.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            hints
        }
        .overlayCard(width: ChromeMetrics.searchWidth)
        .padding(.top, ChromeMetrics.paletteTopInset)
    }

    private func field(query: Binding<String>) -> some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Image(systemName: "text.magnifyingglass")
                .font(ChromeType.control)
                .foregroundStyle(.secondary)

            PaletteField(text: query, placeholder: Branding.findPlaceholder, onCommand: step)
                .frame(maxWidth: .infinity)
                .onChange(of: query.wrappedValue) { model.search() }
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.headerVertical)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        row(hit, at: index, isSelected: index == selection)
                            .id(hit.id)
                    }
                }
            }
            .frame(maxHeight: ChromeMetrics.searchMaxHeight)
            .onChange(of: model.highlighted) { _, index in
                guard let target = model.hits[safe: index] else { return }
                proxy.scrollTo(target.id)
            }
        }
    }

    private func row(_ hit: TranscriptHit, at index: Int, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            Image(systemName: Self.symbol(for: hit))
                .font(ChromeType.control)
                .foregroundStyle(.secondary)
                .frame(width: ChromeMetrics.resolveSlot)

            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                HStack(spacing: ChromeMetrics.inlineGap) {
                    Text(hit.title ?? "Untitled")
                        .font(ChromeType.title.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: ChromeMetrics.inlineGap)
                    Text(Format.age(since: hit.lastWrite))
                        .font(ChromeType.body.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(emphasised(hit))
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                caption(for: hit)
            }
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.rowVertical)
        .background(isSelected
                    ? ChromeColor.accentTint.opacity(ChromeMetrics.paletteSelectionTint)
                    : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.highlighted = index }
        }
        .onTapGesture { store.open(hit) }
    }

    private static func symbol(for hit: TranscriptHit) -> String {
        return "chevron.left.forwardslash.chevron.right"
    }

    private func caption(for hit: TranscriptHit) -> some View {
        var parts: [String] = []
        parts.append(Format.tildePath(hit.cwd))
        if hit.matches > 1 { parts.append("\(hit.matches) matches") }

        return Text(parts.joined(separator: " · "))
            .font(ChromeType.meta)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var emptyState: some View {
        Text(emptyText)
            .font(ChromeType.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ChromeMetrics.horizontal)
            .padding(.vertical, ChromeMetrics.noticeVertical)
    }

    private var emptyText: String {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count < TranscriptSearch.minimumQuery { return "Searches what you and Claude said, not tool output" }
        return model.searched == query ? "No matches" : "Searching…"
    }

    private var hints: some View {
        Text("↑↓ move · ⏎ open · esc close")
            .font(ChromeType.badge)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ChromeMetrics.horizontal)
            .padding(.vertical, ChromeMetrics.barVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emphasised(_ hit: TranscriptHit) -> AttributedString {
        var text = AttributedString(hit.snippet)
        let characters = text.characters
        guard hit.highlight.upperBound <= characters.count else { return text }
        let start = characters.index(characters.startIndex, offsetBy: hit.highlight.lowerBound)
        let end = characters.index(characters.startIndex, offsetBy: hit.highlight.upperBound)
        text[start..<end].inlinePresentationIntent = .stronglyEmphasized
        text[start..<end].foregroundColor = .primary
        return text
    }

    private var selection: Int {
        min(max(model.highlighted, 0), max(model.hits.count - 1, 0))
    }

    private func step(_ key: QuickSwitchKey) -> Bool {
        switch key {
        case .escape:
            store.closeOverlay()
        case .activate:
            if let hit = model.hits[safe: selection] { store.open(hit) }
        case .up:
            model.highlighted = max(selection - 1, 0)
        case .down:
            model.highlighted = min(selection + 1, max(model.hits.count - 1, 0))
        }
        return true
    }
}
