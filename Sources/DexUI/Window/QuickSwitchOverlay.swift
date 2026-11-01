import DexCore
import AppKit
import SwiftUI

@MainActor
@Observable
private final class QuickSwitchModel {
    var query = ""
    var highlighted = 0
}

struct QuickSwitchOverlay: View {
    @Bindable var store: SessionStore
    let scope: QuickSwitchScope

    @State private var model = QuickSwitchModel()

    var body: some View {
        @Bindable var model = model

        let results = store.quickSwitchResults(query: model.query, scope: scope)
        let selected = selection(in: results)

        ZStack(alignment: .top) {
            OverlayScrim { store.closeOverlay() }
            panel(results: results, selected: selected, query: $model.query)
        }
        .transition(.opacity)
    }

    private func panel(
        results: QuickSwitchResults,
        selected: Int,
        query: Binding<String>
    ) -> some View {
        VStack(spacing: 0) {
            field(query: query)
            Divider()

            if results.isEmpty {
                emptyState
            } else {
                list(results: results, selected: selected)
            }

            Divider()
            hints
        }
        .overlayCard(width: ChromeMetrics.paletteWidth)
        .padding(.top, ChromeMetrics.paletteTopInset)
    }

    private func field(query: Binding<String>) -> some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Image(systemName: "magnifyingglass")
                .font(ChromeType.control)
                .foregroundStyle(.secondary)

            PaletteField(text: query, placeholder: placeholder, onCommand: step)
                .frame(maxWidth: .infinity)
                .onChange(of: query.wrappedValue) { model.highlighted = 0 }
        }
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.headerVertical)
    }

    private var placeholder: String {
        return scope == .projectsOnly ? "Jump to a project" : "Jump to a project or session"
    }

    private func list(results: QuickSwitchResults, selected: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("Projects", results.projects, offset: 0, selected: selected)
                    group("Sessions", results.sessions,
                          offset: results.projects.count, selected: selected)
                }
            }
            .frame(maxHeight: ChromeMetrics.paletteMaxHeight)
            .onChange(of: model.highlighted) { _, index in
                guard let target = results.ordered[safe: index] else { return }
                proxy.scrollTo(target.id)
            }
        }
    }

    @ViewBuilder
    private func group(
        _ title: String,
        _ found: [QuickSwitchResult],
        offset: Int,
        selected: Int
    ) -> some View {
        if !found.isEmpty {
            Text(title.uppercased())
                .font(ChromeType.badge.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, ChromeMetrics.horizontal)
                .padding(.top, ChromeMetrics.barVertical)
                .padding(.bottom, ChromeMetrics.badgeVertical)

            ForEach(Array(found.enumerated()), id: \.element.id) { index, result in
                row(result, at: offset + index, isSelected: offset + index == selected)
                    .id(result.id)
            }
        }
    }

    private func row(_ result: QuickSwitchResult, at index: Int, isSelected: Bool) -> some View {
        HStack(spacing: ChromeMetrics.glyphGap) {
            glyph(for: result.item)

            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                Text(emphasised(result))
                    .font(ChromeType.title.weight(.medium))
                    .lineLimit(1)

                detail(for: result.item)
            }

            Spacer(minLength: ChromeMetrics.inlineGap)
            trailing(for: result.item)
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
        .onTapGesture { activate(result) }
    }

    @ViewBuilder
    private func glyph(for item: QuickSwitchItem) -> some View {
        switch item {
        case .allProjects:
            paletteIcon("square.grid.2x2")
        case .project:
            paletteIcon("folder")
        case .session(let row):
            StateGlyph(row: row)
                .frame(width: ChromeMetrics.resolveSlot)
        }
    }

    private func paletteIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(ChromeType.control)
            .foregroundStyle(.secondary)
            .frame(width: ChromeMetrics.resolveSlot)
    }

    @ViewBuilder
    private func detail(for item: QuickSwitchItem) -> some View {
        switch item {
        case .allProjects:
            caption("Stop filtering the list")
        case .project(let summary):
            caption(Format.tildePath(summary.path))
        case .session(let row):
            caption(ComposerTarget.name(for: row.projectPath, in: store.projects))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.meta)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func trailing(for item: QuickSwitchItem) -> some View {
        switch item {
        case .allProjects:
            checkmark(isCurrent: store.selectedProject == nil)
        case .project(let summary):
            HStack(spacing: ChromeMetrics.inlineGap) {
                counts(for: summary)
                checkmark(isCurrent: store.selectedProject == summary.path)
            }
        case .session(let row):
            Text(Format.age(since: row.lastUpdatedAt))
                .font(ChromeType.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func counts(for summary: ProjectSummary) -> some View {
        if summary.blocked > 0 {
            Text("\(summary.blocked) waiting")
                .font(ChromeType.meta)
                .foregroundStyle(.orange)
        } else if summary.active > 0 {
            Text("\(summary.active) active")
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func checkmark(isCurrent: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(ChromeType.inlineIcon.weight(.semibold))
            .foregroundStyle(.secondary)
            .opacity(isCurrent ? 1 : 0)
    }

    private var emptyState: some View {
        Text("No matches")
            .font(ChromeType.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ChromeMetrics.horizontal)
            .padding(.vertical, ChromeMetrics.noticeVertical)
    }

    private var hints: some View {
        Text("↑↓ move · ⏎ open · esc close")
            .font(ChromeType.badge)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ChromeMetrics.horizontal)
            .padding(.vertical, ChromeMetrics.barVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emphasised(_ result: QuickSwitchResult) -> AttributedString {
        let matched = Set(result.highlights)
        var text = AttributedString()

        for (offset, character) in result.name.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            text.append(piece)
        }
        return text
    }

    private func selection(in results: QuickSwitchResults) -> Int {
        min(max(model.highlighted, 0), max(results.ordered.count - 1, 0))
    }

    private func activate(_ result: QuickSwitchResult?) {
        guard let result else { return }
        store.activate(result.item)
    }

    /// Read fresh rather than from what the last draw saw: the field hands these
    /// over from AppKit, outside any particular pass of the body.
    private func step(_ key: QuickSwitchKey) -> Bool {
        let results = store.quickSwitchResults(query: model.query, scope: scope)
        let last = max(results.ordered.count - 1, 0)

        switch key {
        case .escape:
            store.closeOverlay()
        case .activate:
            activate(results.ordered[safe: selection(in: results)])
        case .up:
            model.highlighted = max(selection(in: results) - 1, 0)
        case .down:
            model.highlighted = min(selection(in: results) + 1, last)
        }
        return true
    }
}

enum QuickSwitchKey {
    case up
    case down
    case activate
    case escape
}

/// SwiftUI's own field asks for focus and waits its turn, which whatever holds
/// the window wins. This one takes the responder itself, and gets the keys
/// that walk the list for free — AppKit routes arrows, ⌃P/⌃N and escape
/// through `doCommandBy` before any of them reach the editor.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommand: @MainActor (QuickSwitchKey) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .title3)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            context.coordinator.claimFocus(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.follow(context.environment.colorScheme)
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand

        if field.stringValue != text { field.stringValue = text }
        context.coordinator.claimFocus(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: @MainActor (QuickSwitchKey) -> Bool

        private var hasFocus = false

        init(text: Binding<String>, onCommand: @escaping @MainActor (QuickSwitchKey) -> Bool) {
            self.text = text
            self.onCommand = onCommand
        }

        /// Runs until it lands: the field is asked before SwiftUI has put it in a window.
        func claimFocus(_ field: NSTextField) {
            guard !hasFocus, let window = field.window else { return }
            hasFocus = window.makeFirstResponder(field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard let key = Self.key(for: selector) else { return false }
            return onCommand(key)
        }

        private static func key(for selector: Selector) -> QuickSwitchKey? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)): .activate
            case #selector(NSResponder.cancelOperation(_:)): .escape
            default: nil
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
