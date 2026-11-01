import DexCore
import AppKit
import SwiftUI

struct ActionOutcomeToast: View {
    let outcome: ActionOutcome
    let dismiss: () -> Void

    private var tint: Color { outcome.succeeded ? .green : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.iconGap) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .font(ChromeType.control)

            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.label)
                    .font(ChromeType.body.weight(.semibold))

                if let detail = outcome.detail {
                    Text(detail)
                        .font(ChromeType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: ChromeMetrics.iconGap)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(ChromeType.inlineIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)

        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct WorkingToast: View {
    let label: String
    /// What the work is doing right now, when it can say — a build script's
    /// current phase. Without it the toast is one line, as before.
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.iconGap) {

            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(ChromeType.body.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(ChromeType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: ChromeMetrics.iconGap)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}
