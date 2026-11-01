import DexCore
import SwiftUI

/// The red bar across the window while a session has the pointer or keyboard.
///
/// It is loud on purpose. The session is doing something to the machine you
/// are sitting at, and this is the one thing in the app that says so for the
/// whole of the stretch it is true — the notification is a moment, and the
/// transcript is behind whatever the session brought forward.
struct ScreenTakeoverBar: View {
    let name: String
    let takeover: ScreenTakeover
    let stop: () -> Void

    var body: some View {
        HStack(spacing: ChromeMetrics.inlineGap) {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)

            Text("\(name) is driving your screen")
                .font(ChromeType.body.weight(.semibold))

            if let doing = takeover.doing {
                Text(doing)
                    .font(ChromeType.meta)
                    .opacity(0.85)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: ChromeMetrics.inlineGap)

            TimelineView(.periodic(from: takeover.since, by: 1)) { context in
                Text(Format.elapsed(context.date.timeIntervalSince(takeover.since)))
                    .font(ChromeType.meta.monospacedDigit())
                    .opacity(0.85)
            }

            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .tint(.white)
                .help("End the turn — the session lets go of the screen")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ChromeMetrics.horizontal)
        .padding(.vertical, ChromeMetrics.barVertical)
        .background(ChromeColor.screenDrive.gradient)
    }
}
