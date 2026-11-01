import SwiftUI

/// The dimmed backing both overlays share. Clicking it puts the overlay away.
struct OverlayScrim: View {
    let dismiss: () -> Void

    var body: some View {
        Color.black.opacity(ChromeMetrics.scrimTint)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
    }
}

extension View {

    /// The card the palette and the composer both draw on, so the two read as
    /// one surface arriving from the same place. A material takes its colour from
    /// what is behind it — which here is the scrim — and comes out dimmed, so the
    /// card is opaque and stays lit over it.
    ///
    /// Where it sits in the window is the caller's to say.
    func overlayCard(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.paletteCorner, style: .continuous)

        return background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12),
                                        lineWidth: ChromeMetrics.hairline))
            .shadow(radius: ChromeMetrics.paletteShadow, y: ChromeMetrics.paletteShadow / 3)
            .frame(maxWidth: width)
            .padding(.horizontal, ChromeMetrics.horizontal)
    }
}

/// The dashed tint that says a drag has somewhere to land.
struct DropHighlight: View {
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        shape.fill(ChromeColor.accentTint.opacity(ChromeMetrics.dropTint))
            .overlay(
                shape.strokeBorder(ChromeColor.accent, style: StrokeStyle(
                    lineWidth: ChromeMetrics.dropBorder,
                    dash: [ChromeMetrics.dropDash]
                ))
            )
    }
}
