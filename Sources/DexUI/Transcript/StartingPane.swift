import DexCore
import SwiftUI

/// The pane a session gets before it has one of its own.
struct StartingPane: View {
    let pending: PendingDispatch

    var body: some View {
        OpeningTurn(prompt: pending.prompt)
            .paneGround(.textBackgroundColor)
    }
}
