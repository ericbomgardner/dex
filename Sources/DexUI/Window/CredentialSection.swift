import DexCore
import SwiftUI

/// The API key sessions run on: the login shell's `ANTHROPIC_API_KEY`, or one
/// saved here when the shell has none.
struct CredentialSection: View {
    private let store = SavedAPIKey.standard

    @State private var key = ""
    /// Nil until the keychain has answered, which can wait on a prompt.
    @State private var saved: TokenReading?
    @State private var shell: String?
    @State private var status: Status?
    @State private var refusedKey: String?
    @State private var reads = 0
    @State private var saves = SaveQueue()
    @FocusState private var isFocused: Bool

    private enum Status: Equatable {
        case checking
        case refused
        case unchecked(String)
        case failed(String)
    }

    private var unreadable: Bool {
        if case .unreadable = saved { return true }
        return false
    }

    var body: some View {
        Section("Anthropic API key") {
            HStack(spacing: ChromeMetrics.inlineGap) {
                SecureField("API key", text: $key, prompt: Text(prompt))
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .disabled(saved == nil || status == .checking)
                if unreadable {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderless)
                }
            }
            if let status {
                line(for: status)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .task {
            await load()
            shell = await SessionCredential.shellKey()
        }
    }

    private var prompt: String {
        if unreadable { return "Couldn't read from the keychain" }
        guard let shell, let found = SessionCredential.resolve(shell: shell, saved: nil) else { return "Not set" }
        return "From your shell (\(SessionCredential.tail(found.key)))"
    }

    /// Only the newest read lands: the first can be slower than one after a save.
    private func load() async {
        reads += 1
        let mine = reads
        let store = self.store
        let found = await Task.detached { store.reading() }.value
        guard mine == reads else { return }
        saved = found
        key = found.token ?? ""
    }

    @ViewBuilder
    private func line(for status: Status) -> some View {
        switch status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .refused:
            Text("Anthropic didn't accept this key.")
                .font(.callout)
                .foregroundStyle(.red)
        case .unchecked(let why):
            Text("Saved, but couldn't check it: \(why)")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let why):
            Text("Couldn't save: \(why)")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func commit() {
        guard let saved, status != .checking else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (saved.token ?? ""), trimmed != refusedKey else { return }
        if trimmed.isEmpty, unreadable { return }
        let store = self.store
        let saves = self.saves
        let write: @Sendable (String) async throws -> Void = { key in
            try await saves.run { Result { try store.save(key) } }.0.get()
        }
        if trimmed.isEmpty {
            Task {
                do {
                    try await write("")
                    self.saved = .missing
                    status = nil
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            return
        }
        status = .checking
        Task {
            do {
                switch try await APIKeyCheck.save(trimmed, write: write) {
                case .invalid:
                    refusedKey = trimmed
                    status = .refused
                case .unchecked(let why):
                    self.saved = .found(trimmed)
                    status = .unchecked(why)
                case .valid:
                    self.saved = .found(trimmed)
                    status = nil
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
