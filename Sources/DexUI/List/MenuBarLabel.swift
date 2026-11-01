import DexCore
import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let snapshot: Snapshot

    let waiting: Int

    /// Why the host is unusable, when it is — node missing, or the sidecar
    /// refusing to come up.
    var hostTrouble = false

    var isRebuilding = false

    var body: some View {

        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let badge {
                Text(badge)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
    }

    private var symbol: String {
        if hostTrouble { return "exclamationmark.triangle.fill" }

        if isRebuilding { return "hammer.fill" }
        if snapshot.hasNeverLoaded { return "ellipsis.circle" }
        return waiting > 0 ? "person.wave.2.fill" : "person.wave.2"
    }

    private var badge: String? {
        guard !hostTrouble, !snapshot.hasNeverLoaded else { return nil }
        return waiting > 0 ? "\(waiting)" : nil
    }
}
