import DexCore
import Foundation

/// What the app's `main.swift` calls.
@MainActor
package enum Entry {
    static let flavor = AppFlavor.code

    package static func run() {
        CodeApp.main()
    }
}
