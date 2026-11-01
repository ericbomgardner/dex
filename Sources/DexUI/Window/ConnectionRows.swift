import DexCore
import SwiftUI

/// The Slack token pasted Slack links are looked up with.
struct SlackTokenRow: View {
    @State private var draft = ""
    /// Nil until the keychain has answered, which can wait on a prompt.
    @State private var stored: TokenReading?
    @State private var status: String?
    @State private var reads = 0
    @State private var saves = SaveQueue()

    private var hasToken: Bool { stored?.token != nil }

    private var unreadable: Bool {
        if case .unreadable = stored { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            HStack(spacing: ChromeMetrics.inlineGap) {
                Text("Slack")
                Spacer(minLength: ChromeMetrics.inlineGap)
                if unreadable {
                    Text("Couldn't read from the keychain")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderless)
                }
                if hasToken || unreadable {
                    Button("Remove") { save("") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: ChromeMetrics.inlineGap) {
                SecureField(hasToken || unreadable ? "Replace token" : "Token", text: $draft,
                            prompt: Text(hasToken ? "Saved in the keychain" : "xoxp-…"))
                    .onSubmit { save(draft) }
                Button("Save") { save(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status {
                Text(status)
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("A user token with the channels, groups, im and mpim history and read scopes, and users:read. Pasted Slack links show the message or channel they point at; without one they stay links.")
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ChromeMetrics.lineGap)
        .task { await load() }
    }

    /// Only the newest read lands: the first can be slower than one after a save.
    private func load() async {
        reads += 1
        let mine = reads
        let found = await Task.detached { SlackToken.reading() }.value
        guard mine == reads else { return }
        stored = found
    }

    private func save(_ token: String) {
        Task {
            let (saved, isLatest) = await saves.run { Result { try SlackToken.save(token) } }
            guard isLatest else { return }
            let generation = saves.generation
            if case .failure(let error) = saved {
                status = "Couldn't save the token: \(error.localizedDescription)"
                return
            }
            draft = ""
            await load()
            await ComposerLinkPaste.resolver.install(SlackLinkLookup(), for: .slack)
            guard let token = stored?.token, generation == saves.generation else {
                if generation == saves.generation { status = nil }
                return
            }
            status = "Checking…"
            let checked: String
            do {
                let (data, _) = try await URLSession.shared.data(for: SlackAPI.request("auth.test", [:], token: token))
                let who = try SlackAPI.identity(in: data)
                checked = "Signed in to \(who.team) as \(who.user)."
            } catch {
                checked = "Slack said: \(error)"
            }
            guard generation == saves.generation else { return }
            status = checked
        }
    }
}

/// Which `gh` answers for pasted GitHub links.
struct GitHubCLINote: View {
    @State private var gh: String??

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
            Text("GitHub")
            Text(note)
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ChromeMetrics.lineGap)
        .task { gh = .some(await Task.detached { GitHubCLI.executable() }.value) }
    }

    private var note: String {
        switch gh {
        case .none: "Looking for gh…"
        case .some(.none): "No gh found, so pasted GitHub links stay links. Install it and run gh auth login."
        case .some(.some(let path)): "Pasted GitHub links are looked up with \(path), as whoever gh auth login signed in."
        }
    }
}
