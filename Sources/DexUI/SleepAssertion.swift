import Foundation
import IOKit.pwr_mgt

/// One power assertion, created when the app has work to keep the Mac up for
/// and released when it doesn't. `PreventUserIdleSystemSleep` leaves the lid
/// and the display alone: closing the laptop still sleeps it, and the screen
/// still dims.
@MainActor
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    func hold(_ wanted: Bool) {
        guard wanted != isHeld else { return }
        if wanted {
            let created = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Dex: a session is working" as CFString,
                &id
            )
            isHeld = created == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(id)
            id = 0
            isHeld = false
        }
    }
}

/// The assertion held while the setting allows it and a hosted session is working.
@MainActor
final class SleepHold {
    private let assertion = SleepAssertion()

    var allowed: Bool {
        didSet { refresh() }
    }

    var working = false {
        didSet { refresh() }
    }

    init(allowed: Bool) {
        self.allowed = allowed
    }

    private func refresh() {
        assertion.hold(allowed && working)
    }
}
