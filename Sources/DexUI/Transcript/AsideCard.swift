import DexCore
import SwiftUI

/// A side question's answers, over the composer and out of the transcript,
/// which is where they would read as said to the session.
struct AsideCard: View {
    let aside: Aside
    let columnHeight: CGFloat
    let onDraft: () -> Void
    let onClose: () -> Void

    /// Its own, since the card is drawn outside the transcript's.
    @State private var selection = TranscriptSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.inlineGap) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ChromeMetrics.noticeVertical) {
                        ForEach(Array(aside.exchanges.enumerated()), id: \.offset) { index, exchange in
                            question(exchange.question)
                            MarkdownText(blocks: Markdown.blocks(in: exchange.response))
                                .selectionIndex(index)
                        }
                        if let pending = aside.pending {
                            question(pending.question)
                            ProgressView().controlSize(.small)
                        }
                        if let failure = aside.failure {
                            question(failure.question)
                            Label(failure.reason, systemImage: "exclamationmark.triangle")
                                .font(ChromeType.Reading.meta)
                                .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 0).id(Self.end)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SelectionMargin())
                }
                .frame(maxHeight: columnHeight * 0.4)
                .fixedSize(horizontal: false, vertical: true)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: aside) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
        .environment(\.transcriptSelection, selection)
        .onDisappear { selection.clear() }
        .padding(ChromeMetrics.horizontal)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .fill(ChromeColor.optionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                .strokeBorder(ChromeColor.optionEdge)
        )
    }

    private static let end = "end"

    private var header: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Text("Side question · not in the conversation")
                .font(ChromeType.badge)
                .foregroundStyle(.secondary)

            Spacer()

            if !aside.exchanges.isEmpty {
                Button("Add to Message", action: onDraft)
                    .help("Put this aside in the message box, to send to the session")
            }

            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .font(ChromeType.control)
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.Reading.meta)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
