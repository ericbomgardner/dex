import AppKit
import SwiftUI

package enum ChromeType {

    static let title = Font.body

    static let body = Font.callout

    static let meta = Font.subheadline

    /// A pill's label, and the dials beside it in the composer's status row. One
    /// size with `meta` on purpose: that row is read across, so a dial set a step
    /// above the pill next to it read as misaligned rather than as a control.
    static let badge = meta

    static let control = Font.system(size: 12)

    static let inlineIcon = Font.system(size: 10)

    static let badgeIcon = inlineIcon

    static let displayGlyph = Font.system(size: 22, weight: .light)

    /// The transcript is read rather than scanned, so it runs a step above the
    /// chrome around it.
    package enum Reading {

        /// Named as well as set, since the field you type in is AppKit and has
        /// to be handed the size as a face rather than a style.
        package static let bodySize: CGFloat = 14

        package static let body = Font.system(size: bodySize)

        package static let meta = Font.system(size: 13)

        /// Named as well as set, since a mockup drawn in it has to be given room
        /// by the line rather than by the pane, and that is asked of the face.
        static let monoSize: CGFloat = 13

        package static let mono = Font.system(size: monoSize, design: .monospaced)

        /// One line set in that face, for the two places that have to bound mono
        /// text by the line before SwiftUI has laid any of it out.
        package static var monoLine: CGFloat {
            let font = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
            return font.ascender - font.descender + font.leading
        }

        static let code = Font.system(size: 14, design: .monospaced)

        package static let icon = Font.system(size: 12)

        /// Set level with the prose it heads and told apart by weight alone, so
        /// it has to move with `bodySize`: left behind, an h3 sets smaller than
        /// the paragraph under it.
        static let headingSmall = Font.system(size: bodySize, weight: .semibold)

        /// `body` as a face, for that AppKit field. Derived from the text style
        /// the field was set in rather than `systemFont`, which is a different
        /// descriptor with a shorter line box — swapping to it would retune the
        /// field's height by a point at the same size.
        static var editorFont: NSFont {
            NSFont(descriptor: NSFont.preferredFont(forTextStyle: .body).fontDescriptor,
                   size: bodySize) ?? .systemFont(ofSize: bodySize)
        }
    }
}

enum ChromeColor {

    @MainActor static var accent: Color { Entry.flavor.accent }
    @MainActor static var accentTint: Color { Entry.flavor.accentTint }
    /// The takeover's colour, on the bar and on the line of a command that
    /// earns it.
    static let screenDrive = Color.red
    static let screenDriveFill = Color.red.opacity(0.14)

    static let muted = Color.secondary.opacity(0.4)


    /// An option reads at full strength whether or not it is the one the dialog
    /// has landed on. Dimming the rest says which is picked at the price of every
    /// option you have not picked yet, which are the ones still being read.
    static let optionLabel = Color.primary

    static let optionFill = Color.primary.opacity(ChromeMetrics.optionTint)
    static let optionEdge = Color.primary.opacity(ChromeMetrics.optionEdgeTint)
}

package enum ChromeMetrics {

    static let horizontal: CGFloat = 14

    /// The sidebar is a narrow column read at a glance, so it keeps its
    /// contents further off the edge than the panes beside it.
    static let listHorizontal: CGFloat = 16

    static let rowVertical: CGFloat = 8

    /// The sidebar's rows carry three lines each, so they're set looser than
    /// the single-line chrome that shares `rowVertical`.
    static let listRowVertical: CGFloat = 11

    static let barVertical: CGFloat = 7

    static let headerVertical: CGFloat = 10

    static let noticeVertical: CGFloat = 12

    static let emptyVertical: CGFloat = 16

    static let lineGap: CGFloat = 3

    static let iconGap: CGFloat = 5

    /// The padding AppKit puts either side of a borderless menu's label, taken
    /// back where the menu sits inside a sentence.
    static let menuInset: CGFloat = 3

    static let inlineGap: CGFloat = 7

    static let mentionIcon: CGFloat = 14

    static let glyphGap: CGFloat = 9

    static let controlGap: CGFloat = 8

    static let glyphTopInset: CGFloat = 4

    static let badgeGap: CGFloat = 3
    static let badgeHorizontal: CGFloat = 5
    static let badgeVertical: CGFloat = 2

    static let resolveSlot: CGFloat = 18

    static let openFolderSlot: CGFloat = 20

    static let settingsSlot: CGFloat = 24


    static let projectNameSlot: CGFloat = 180

    static let sendButton: CGFloat = 20

    static let fieldCorner: CGFloat = 8
    static let fieldHorizontal: CGFloat = 10
    static let fieldVertical: CGFloat = 8

    static let chipNameSlot: CGFloat = 150
    static let chipTint: Double = 0.08

    static let dropBorder: CGFloat = 2
    static let dropDash: CGFloat = 4
    static let dropTint: Double = 0.08

    static let hairline: CGFloat = 1

    static let hoverTint: Double = 0.05

    static let attachedTint: Double = 0.14

    /// Behind another app the row dims but keeps the accent, unlike a system
    /// list: the colour is how the apps tell apart side by side.
    static let attachedInactiveTint: Double = 0.08

    static let selectionCorner: CGFloat = 6
    static let selectionInset: CGFloat = 8
    static let selectionVertical: CGFloat = 2

    /// The composer overlay is written in rather than scanned, so it runs wider
    /// than the palette and gives the editor room to grow before it scrolls.
    static let composerWidth: CGFloat = 620
    static let composerFieldMinHeight: CGFloat = 150
    static let composerFieldMaxHeight: CGFloat = 420

    /// The editor never takes more than this much of the window, so the chrome
    /// around it stays on screen in a short one.
    static let composerFieldShare: Double = 0.5

    static let menuShadow: CGFloat = 8

    static let paletteWidth: CGFloat = 520
    static let paletteMaxHeight: CGFloat = 380
    static let searchWidth: CGFloat = 640
    static let searchMaxHeight: CGFloat = 480
    static let agentCardWidth: CGFloat = readingMeasure + 2 * readingInset
    static let agentCardMargin: CGFloat = 40
    static let paletteTopInset: CGFloat = 64
    static let paletteCorner: CGFloat = 12
    static let paletteShadow: CGFloat = 24
    static let paletteSelectionTint: Double = 0.18
    static let scrimTint: Double = 0.2

    static let promptCorner: CGFloat = 6
    static let promptTint: Double = 0.07
    static let promptRule: CGFloat = 2
    /// What you typed keeps off the left edge the replies start from, so the two
    /// sides of the conversation read apart even where the tint is faint.
    static let promptIndent: CGFloat = 48
    /// A prompt the session has been handed but hasn't got to. Faint enough to
    /// read as waiting, dark enough to read at all.
    static let waitingPrompt: Double = 0.5

    /// An option of a question, which is a thing to read rather than a button to
    /// hit: the fill sits under a label at full strength instead of standing in
    /// for one, so it runs light.
    static let optionTint: Double = 0.05
    static let optionEdgeTint: Double = 0.12

    /// How much of a mockup the pane will give room to before it scrolls. The CLI
    /// has already cut it to what fitted its own panel, so this is only the tall
    /// window's version of that — the conversation above stays worth having.
    package static let previewMaxLines = 14
    static let previewInset: CGFloat = 8

    static let toolGlyphSlot: CGFloat = 14
    package static let detailInset: CGFloat = 10
    static let detailTint: Double = 0.05

    /// The transcript's rhythm. A line of prose is read across and then down, so
    /// it carries leading of its own rather than the font's default, and every
    /// gap around it is measured against that taller line.
    package static let readingLead: CGFloat = 5
    static let monoLead: CGFloat = 2

    /// Where a line of prose ends regardless of how wide the pane is. The eye
    /// finds the next line by how far it has to travel back, and past a hundred
    /// or so characters it starts landing on the line it just read. Ninety-odd
    /// is where Claude's own column sits, and at the 6.2pt the reading face
    /// averages that is here. Measured off `Reading.bodySize`, so a face set
    /// larger in the same column would be read in a shorter line, not an easier
    /// one — the two move together or neither does.
    package static let readingMeasure: CGFloat = 588

    package static let readingInset: CGFloat = 24
    package static let itemGap: CGFloat = 18
    /// Added above a prompt, so the start of a turn reads as one.
    static let turnLead: CGFloat = 14
    static let blockGap: CGFloat = 12
    static let headingLead: CGFloat = 10
    static let cardVertical: CGFloat = 10
    static let cardHorizontal: CGFloat = 12

    static let listIndent: CGFloat = 16
    static let listGap: CGFloat = 8
    static let bulletSlot: CGFloat = 14
    static let columnGap: CGFloat = 12
    static let rowGap: CGFloat = 6
}
