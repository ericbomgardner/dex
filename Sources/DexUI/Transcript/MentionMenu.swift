import DexCore
import Observation
import SwiftUI

/// The sessions, and whatever else the app offers, while a title is being
/// typed after an `@`.
///
/// The list is asked for on every keystroke rather than loaded once, since the
/// rows it is drawn from settle and arrive while the field is open.
@MainActor
@Observable
final class MentionMenu {

    private(set) var matches: [Mention] = []
    private(set) var selection = 0

    private var dismissed: String?

    var isOpen: Bool { !matches.isEmpty }

    var selected: Mention? {
        guard matches.indices.contains(selection) else { return nil }
        return matches[selection]
    }

    func draftChanged(to draft: String, offering candidates: @autoclosure () -> MentionCandidates) {
        // Escape closes the menu for the text it was open on; typing on makes
        // it a different name, and the menu is worth offering again.
        if dismissed != nil, dismissed != draft { dismissed = nil }
        guard dismissed == nil, SessionMentions.query(in: draft) != nil else { return matches = [] }

        let found = MentionRanking.matches(for: draft, in: candidates())
        guard found != matches else { return }

        // Rows that arrive late — a search coming back, a rescan — leave the
        // row being pointed at where the pointer is.
        let held = draft == shownFor ? selected?.id : nil
        matches = found
        shownFor = draft
        selection = held.flatMap { id in found.firstIndex { $0.id == id } } ?? 0
    }

    private var shownFor: String?

    func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + step + matches.count) % matches.count
    }

    func dismiss(for draft: String) {
        dismissed = draft
        matches = []
    }

    func close() {
        matches = []
        selection = 0
        dismissed = nil
    }
}

struct MentionMenuList: View {
    let menu: MentionMenu
    let accept: (Mention) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.matches.enumerated()), id: \.element.id) { index, mention in
                row(mention, isSelected: index == menu.selection)
            }
        }
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(radius: ChromeMetrics.menuShadow, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.fieldCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: ChromeMetrics.hairline)
        )
    }

    private func row(_ mention: Mention, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: ChromeMetrics.inlineGap) {
            MentionSourceIcon(source: mention.source)
            Text(mention.title)
                .font(ChromeType.body.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text(mention.detail)
                .font(ChromeType.meta)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, ChromeMetrics.fieldHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical + 1)
        .background(isSelected ? ChromeColor.accent : .clear)
        .contentShape(Rectangle())
        .onTapGesture { accept(mention) }
    }
}
