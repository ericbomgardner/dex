import Foundation

/// Whether the Mac should be held awake for the sessions the app is holding.
/// One setting for every row: held while any hosted session is working, and
/// released the moment none is. Releasing never sleeps the Mac by itself — it
/// only lets the idle timer run, and that is minutes — so a beat between one
/// turn ending and the next starting cannot cost a sleep.
public enum KeepAwake {

    /// Only rows this Mac's host is holding count. An archived row's file can
    /// end mid-call for good, and a hold on that would never let go.
    public static func shouldHold(rows: [SessionRowModel], live: Set<String>) -> Bool {
        rows.contains {
            live.contains($0.session.hostKey) && $0.isWorking
        }
    }
}
