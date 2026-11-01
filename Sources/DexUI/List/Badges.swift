import DexCore
import AppKit
import SwiftUI

/// What the session is answering as — or, until a first reply exists, what it
/// was launched as. Same capsule either way; the tooltip says whose word it is.
struct ModelBadge: View {
    let chip: ModelChip

    var body: some View {
        Text(chip.label)
            .font(ChromeType.badge.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, ChromeMetrics.badgeHorizontal)
            .padding(.vertical, ChromeMetrics.badgeVertical)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help(chip.help)
    }
}

/// What the session is carrying, and so what its next turn costs before it has
/// done anything. The pane draws it always — a number you can watch grow is the
/// point of putting it under the composer — so it turns the alarming colour
/// under you rather than only appearing in it.
struct ContextBadge: View {
    let context: SessionContext

    private var tint: Color { context.isExpensive ? .orange : .secondary }

    var body: some View {
        HStack(spacing: ChromeMetrics.badgeGap) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(ChromeType.badgeIcon)
            Text(context.label)
                .font(ChromeType.badge.weight(context.isExpensive ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, ChromeMetrics.badgeHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(
            Capsule().fill(context.isExpensive ? tint.opacity(0.14) : Color.primary.opacity(0.06))
        )
        .help(context.help)
    }
}

struct MergeStatusBadge: View {
    let status: WorktreeMergeStatus

    private var symbol: String {
        if status.tone == .awaitingRestart { return "arrow.clockwise.circle.fill" }
        switch status.merge {
        case .merged: return status.needsAttention ? "tray.full" : "checkmark.circle.fill"
        case .outstanding: return "arrow.up.circle.fill"

        case .branchGone: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status.tone {
        case .landed: .green
        case .attention: .orange
        case .awaitingRestart: .blue
        case .indeterminate: .secondary
        }
    }

    var body: some View {
        HStack(spacing: ChromeMetrics.badgeGap) {
            Image(systemName: symbol)
                .font(ChromeType.badgeIcon)
            Text(status.label)
                .font(ChromeType.badge.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, ChromeMetrics.badgeHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(Capsule().fill(tint.opacity(fillOpacity)))
        .help(status.help)
    }

    private var fillOpacity: Double {
        status.tone == .indeterminate ? 0.08 : 0.14
    }
}
