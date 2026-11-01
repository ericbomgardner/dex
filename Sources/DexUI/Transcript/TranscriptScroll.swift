import SwiftUI

/// The way back to the end of a transcript, offered over the column once the
/// reader is well up it.
package struct JumpToEnd: View {
    package static let size: CGFloat = 28

    let action: () -> Void

    package var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(ChromeType.badgeIcon.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Jump to the end")
        .accessibilityLabel("Jump to the end")
    }
}

/// Where in each transcript the reader was when they left it, for the ones
/// they left anywhere but the end.
@MainActor
package final class TranscriptPlaces {
    /// A row and how far into it, since rows above it can come back a different
    /// height. The offset is only where to start looking.
    struct Place {
        let row: String
        let into: CGFloat
        let offset: CGFloat
    }

    private var places: [String: Place] = [:]

    package init() {}

    subscript(transcript: String) -> Place? {
        get { places[transcript] }
        set { places[transcript] = newValue }
    }
}
