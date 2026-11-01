import DexCore
import SwiftUI

/// Opens the selected project — where the agents' work lands once it merges —
/// in whichever of the folder apps are installed.
struct OpenFolderButton: View {
    let path: String

    var body: some View {
        Menu {
            Section(Format.tildePath(path)) {
                ForEach(FolderApp.installed, id: \.self) { app in
                    Button(app.title) { app.open(path) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(ChromeType.control)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .frame(width: ChromeMetrics.openFolderSlot)
        .help("Open \(Format.tildePath(path))")
    }
}
