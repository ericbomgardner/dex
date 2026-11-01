import Foundation

/// The Anthropic API key every session runs on. An app built on the Agent SDK
/// may not offer claude.ai login, so each session's CLI is handed a key, which
/// outranks a stored login (`docs/claude-code/api-key-over-login.md`),
/// and no session starts without one.
public enum SessionCredential {
    public static let variable = "ANTHROPIC_API_KEY"

    public enum Source: Sendable, Equatable {
        case shell
        case saved
    }

    public enum Refusal: LocalizedError, Equatable {
        case noKey
        case keychainUnreadable
        case hostDropsKey

        public var errorDescription: String? {
            switch self {
            case .noKey:
                "Add an Anthropic API key in Settings (⌘,) to start a session."
            case .keychainUnreadable:
                "Dex couldn't read the API key from the keychain."
            case .hostDropsKey:
                "the Dex host hasn't said it can pass your API key on: it's still connecting, or it's from an older build. Try again in a moment, or quit Dex with no session working and reopen it."
            }
        }
    }

    /// The login shell's key, then the one saved in Settings.
    public static func resolve(shell: String?, saved: String?) -> (key: String, source: Source)? {
        if let key = usable(shell) { return (key, .shell) }
        if let key = usable(saved) { return (key, .saved) }
        return nil
    }

    @MainActor
    public static func withKey(
        hostTakesKey: Bool, _ body: @escaping @MainActor @Sendable (Result<String?, any Error>) -> Void
    ) {
        KeyLookup.standard.withKey(hostTakesKey: hostTakesKey, body)
    }

    /// The saved key is only asked for when the shell has none, so a shell key
    /// never waits on the keychain.
    static func apiKey(shell: String?, saved: () -> TokenReading, hostTakesKey: Bool) throws -> String {
        let key: String
        if let found = usable(shell) {
            key = found
        } else {
            switch saved() {
            case .found(let found):
                guard let found = usable(found) else { throw Refusal.noKey }
                key = found
            case .missing: throw Refusal.noKey
            case .unreadable: throw Refusal.keychainUnreadable
            }
        }
        guard hostTakesKey else { throw Refusal.hostDropsKey }
        return key
    }

    public static func prepare() {
        KeyLookup.standard.prepare()
    }

    public static func shellKey() async -> String? {
        await KeyLookup.standard.shellKey()
    }

    /// The last four characters, which is all Settings shows of a key.
    public static func tail(_ key: String) -> String {
        "…" + key.suffix(4)
    }

    private static func usable(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
}

/// Where a start finds its key. The login shell is asked once per launch, like
/// its PATH, and the keychain on every start, neither on the main thread: a
/// start waits for them without blocking, however long an rc file or a keychain
/// prompt takes.
final class KeyLookup: Sendable {
    static let standard = KeyLookup(
        readShell: { LoginShell.probe(SessionCredential.variable) },
        readSaved: { SavedAPIKey.standard.reading() }
    )

    private struct State {
        var shell: String?? = nil
        var reading = false
        var waiting: [@Sendable (String?) -> Void] = []
    }

    private let readShell: @Sendable () -> String?
    private let readSaved: @Sendable () -> TokenReading
    private let state = Lock(State())

    init(readShell: @escaping @Sendable () -> String?, readSaved: @escaping @Sendable () -> TokenReading) {
        self.readShell = readShell
        self.readSaved = readSaved
    }

    func prepare() {
        _ = shell(orWhenRead: { _ in })
    }

    func shellKey() async -> String? {
        await withCheckedContinuation { continuation in
            if let known = shell(orWhenRead: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: known)
            }
        }
    }

    /// Always a main-queue turn later, so a refusal lands after the caller has
    /// held its place, the way a host's would.
    @MainActor
    func withKey(hostTakesKey: Bool, _ body: @escaping @MainActor @Sendable (Result<String?, any Error>) -> Void) {
        let finish: @Sendable (String?) -> Void = { shell in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result<String?, any Error> {
                    try SessionCredential.apiKey(shell: shell, saved: self.readSaved, hostTakesKey: hostTakesKey)
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { body(result) } }
            }
        }
        if let known = shell(orWhenRead: finish) { finish(known) }
    }

    /// The shell's answer if it has given one. Otherwise nil, and `then` is
    /// handed the answer off the main thread once it comes.
    private func shell(orWhenRead then: @escaping @Sendable (String?) -> Void) -> String?? {
        let (known, start): (String??, Bool) = state.withLock { state in
            if let known = state.shell { return (known, false) }
            state.waiting.append(then)
            defer { state.reading = true }
            return (nil, !state.reading)
        }
        if start {
            DispatchQueue.global(qos: .userInitiated).async { self.read() }
        }
        return known
    }

    private func read() {
        let value = readShell()
        let waiting = state.withLock { state in
            state.shell = .some(value)
            defer { state.waiting = [] }
            return state.waiting
        }
        for deliver in waiting { deliver(value) }
    }
}

/// The key typed into Settings, kept in the keychain with the connection
/// tokens. Both calls can wait on a keychain prompt, so neither belongs on the
/// main thread.
public struct SavedAPIKey: Sendable {
    public static let name = "anthropic-api-key"
    public static let label = "Dex Anthropic API key"
    public static let standard = SavedAPIKey(store: ConnectionTokens.store)

    let store: any TokenStore

    public init(store: any TokenStore) {
        self.store = store
    }

    public func reading() -> TokenReading {
        store.reading(Self.name)
    }

    /// An empty key removes it.
    public func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.save(key.isEmpty ? nil : key, as: Self.name, label: Self.label)
    }
}
