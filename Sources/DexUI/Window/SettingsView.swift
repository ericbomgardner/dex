import DexCore
import SwiftUI

/// What ⌘, opens. Thinner than the gear menu it grew from: the changelog and
/// rebuild actions are commands, not preferences, and live in the Debug menu
/// (shown only to a build still sitting in its checkout).
struct SettingsView: View {
    @Bindable var store: SessionStore

    var body: some View {
        Form {
            CredentialSection()

            Section("Sessions") {
                Picker("Output style", selection: Bindable(store.preferences).outputStyle) {
                    ForEach(
                        OutputStyle.offered(
                            from: store.offeredOutputStyles, keeping: store.preferences.outputStyle
                        ),
                        id: \.self
                    ) { style in
                        Text(menuText(for: style)).tag(style)
                    }
                }

                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }


            McpSection(store: store)

            ConnectionsSection(work: store.linkedWork)

            Section("Power") {
                Toggle("Keep the Mac awake while a session is working", isOn: Bindable(store.preferences).keepsAwake)

                Text("Held while any session is running a turn or has background work out, and released when every session is idle. The lid and the display are left alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }


            Section("Notifications") {
                Toggle("Notify Me", isOn: Bindable(store.preferences).postsNotifications)

                if let note = store.presenter.authorization.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // The window opens without the composer, so the answer this leans on is
        // asked for here too rather than only where a session is started — and
        // keyed on the folder, which moves on its own.
        .task(id: store.composerTarget) { store.readComposerDefaults() }
    }

    /// Default names the style it lands on, the way the model picker's row names
    /// its model. A row reading only "Default" leaves the one question the
    /// picker exists to answer unanswered.
    private func menuText(for style: OutputStyle) -> String {
        guard style == .inherited, let resolved = store.composerDefaults?.outputStyle else {
            return style.menuLabel
        }
        return "\(style.menuLabel)  ·  \(resolved)"
    }

    /// Three things worth saying, and which one depends on what has been asked
    /// yet. The list comes from a running session and nowhere else, so a machine
    /// this app has started nothing on has one row and no explanation for it.
    private var note: String {
        guard !store.offeredOutputStyles.isEmpty else {
            return """
                Styles are read from the CLI, which answers only while a session \
                is running. Start one and the rest will be here.
                """
        }
        let base = """
            Applies to sessions this app starts, and only from the start — there \
            is no per-session dial yet. Your terminal keeps whatever outputStyle \
            your settings.json says.
            """
        // Named per folder because it is a merge: a project with settings of its
        // own has a Default of its own, and this one is the composer's target.
        guard store.composerDefaults?.outputStyle != nil else { return base }
        return base + " Default is what \(store.composerTargetName) resolves to."
    }
}


/// Each MCP server as this Mac's running sessions see it.
private struct McpSection: View {
    let store: SessionStore

    var body: some View {
        Section("MCP servers") {
            ForEach(store.mcpServers) { server in
                VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                    HStack(spacing: ChromeMetrics.inlineGap) {
                        Circle()
                            .fill(color(server.status))
                            .frame(width: 7, height: 7)
                        Text(server.name)
                        Spacer(minLength: ChromeMetrics.inlineGap)
                        Text(label(server))
                            .foregroundStyle(.secondary)
                    }
                    if let error = server.error {
                        Text(error)
                            .font(ChromeType.meta)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)

        }
    }

    private func label(_ server: McpServerSummary) -> String {
        guard server.reporting > 1 else { return server.status }
        guard server.agreeing < server.reporting else { return "\(server.status) · \(server.reporting) sessions" }
        return "\(server.status) in \(server.agreeing) of \(server.reporting) sessions"
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "failed", "needs-auth": .red
        default: .secondary
        }
    }

    private var note: String {
        let sessions = store.mcpReportingSessions
        guard sessions > 0 else {
            return "Read from running sessions, as each one's CLI reports them. Start one and its servers will be here."
        }
        return "As \(sessions == 1 ? "the running session reports" : "\(sessions) running sessions report") them, re-read after each turn."
    }
}
