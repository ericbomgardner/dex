import DexCore
import Foundation
import SwiftUI

/// What the app is called and how it presents itself: its host, window,
/// menus and colours.
package struct AppFlavor: Sendable {
    package let host: HostIdentity
    /// What SwiftUI remembers the window's frame by.
    package let windowID: String
    package let title: String
    package let columnsAutosaveName: String
    package let linkScheme: String
    /// Lowercase, singular: "session".
    package let noun: String
    /// The Go menu's item for the window.
    package let windowCommand: String
    /// What the new-session composer is headed with.
    package let composerSymbol: String
    /// What the new-session composer says while it is empty.
    package let composerPlaceholder: String
    /// Solid: buttons, text, the working spinner.
    package let accent: Color
    /// Under a fill's opacity: selected rows, prompt cards.
    package let accentTint: Color

    package var capitalizedNoun: String { noun.prefix(1).uppercased() + noun.dropFirst() }

    package static let code = AppFlavor(
        host: .code,
        windowID: "sessions",
        title: Branding.title,
        columnsAutosaveName: "sessions.columns",
        linkScheme: SessionLink.scheme,
        noun: "session",
        windowCommand: "Sessions Window",
        composerSymbol: "plus.bubble",
        composerPlaceholder: "What should Claude work on?",
        accent: Branding.accent,
        accentTint: Branding.accent
    )
}
