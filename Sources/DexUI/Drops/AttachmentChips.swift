import DexCore
import SwiftUI

/// What is riding along with the message, above whichever box you are typing in.
/// Named rather than pathed, since a chip is there to be recognised and removed.
struct AttachmentChips: View {
    let attachments: [ComposerAttachment]
    let detach: (ComposerAttachment) -> Void

    var body: some View {
        WrappingRow(spacing: ChromeMetrics.badgeGap) {
            ForEach(attachments) { attachment in
                chip(attachment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: ChromeMetrics.badgeGap) {
            Image(systemName: "paperclip")
                .font(ChromeType.badgeIcon)
                .foregroundStyle(.tertiary)

            Text(attachment.name)
                .font(ChromeType.badge)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ChromeMetrics.chipNameSlot, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                detach(attachment)
            } label: {
                Image(systemName: "xmark")
                    .font(ChromeType.badgeIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove \(attachment.name)")
        }
        .padding(.horizontal, ChromeMetrics.badgeHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(Capsule().fill(Color.primary.opacity(ChromeMetrics.chipTint)))
        .help(attachment.path)
    }
}
