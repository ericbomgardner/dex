import DexCore
import Foundation
import Observation

/// Linear issues and Notion pages for the composer's `@` menu, with the tokens
/// that reach them, kept where `ConnectionTokens` keeps them.
@MainActor
@Observable
final class LinkedWork {
    private(set) var linearStatus: LinkedServiceStatus
    private(set) var notionStatus: LinkedServiceStatus

    /// Bumped when something already handed out gets better — a Notion page's
    /// parent learns its name — so a menu showing it can ask again.
    private(set) var revision = 0

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var saves: [LinkedService: SaveQueue] = [:]
    @ObservationIgnored let linear: LinearClient
    @ObservationIgnored let notion: NotionClient

    static let debounce: Duration = .milliseconds(250)

    init(secrets: any SecretStore, transport: @escaping HTTPTransport = HTTP.live) {
        self.secrets = secrets
        self.linear = LinearClient(secrets: secrets, transport: transport)
        self.notion = NotionClient(secrets: secrets, transport: transport)
        self.linearStatus = .reading
        self.notionStatus = .reading
    }

    static func stored() -> LinkedWork {
        LinkedWork(secrets: StoredSecrets())
    }

    func status(of service: LinkedService) -> LinkedServiceStatus {
        switch service {
        case .linear: linearStatus
        case .notion: notionStatus
        }
    }

    func hasToken(_ service: LinkedService) -> Bool {
        switch status(of: service) {
        case .unchecked, .connected, .failed: true
        case .reading, .unreadable, .noToken: false
        }
    }

    // Tokens

    /// Reads both tokens off the main thread the first time anything needs
    /// them, since a keychain read can wait on a prompt.
    func load() async {
        if loading == nil {
            let secrets = self.secrets
            loading = Task {
                let readings = await Task.detached {
                    LinkedService.allCases.map { ($0, secrets.reading(for: $0)) }
                }.value
                for (service, reading) in readings where status(of: service) == .reading {
                    set(Self.status(after: reading), for: service)
                }
            }
        }
        await loading?.value
    }

    /// Reads a token again after the keychain wouldn't give it up.
    func retry(_ service: LinkedService) async {
        set(.reading, for: service)
        let secrets = self.secrets
        let reading = await Task.detached { secrets.reading(for: service) }.value
        guard status(of: service) == .reading else { return }
        set(Self.status(after: reading), for: service)
        await check(service)
    }

    private static func status(after reading: TokenReading) -> LinkedServiceStatus {
        switch reading {
        case .found: .unchecked
        case .missing: .noToken
        case .unreadable(let status): .unreadable(status)
        }
    }

    func setToken(_ token: String, for service: LinkedService) {
        Task { await saveToken(token, for: service) }
    }

    /// Saves the token, off the main thread, and checks it. Empty removes it.
    func saveToken(_ token: String, for service: LinkedService) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let secrets = self.secrets
        let value = trimmed.isEmpty ? nil : trimmed
        let queue = saves[service] ?? SaveQueue()
        saves[service] = queue
        let (saved, isLatest) = await queue.run { Result { try secrets.setSecret(value, for: service) } }
        guard isLatest else { return }
        if case .failure(let error) = saved {
            set(.failed("Couldn't save the token: \(error.localizedDescription)", at: Date()), for: service)
            return
        }
        set(trimmed.isEmpty ? .noToken : .unchecked, for: service)
        revision += 1
        switch service {
        case .linear: await linear.forget()
        case .notion: await notion.forget()
        }
        if !trimmed.isEmpty { await check(service) }
    }

    /// Asks the service whose token this is, the cheapest proof that it works.
    func check(_ service: LinkedService) async {
        guard hasToken(service) else { return }
        let generation = saves[service]?.generation ?? 0
        let outcome: Result<String?, any Error>
        switch service {
        case .linear: outcome = await Result(awaiting: { try await linear.whoAmI() })
        case .notion: outcome = await Result(awaiting: { try await notion.whoAmI() })
        }
        guard (saves[service]?.generation ?? 0) == generation else { return }
        switch outcome {
        case .success(let who): set(.connected(as: who, at: Date()), for: service)
        case .failure(let error): note(error, from: service)
        }
    }

    // The composer

    /// Candidates for the text after an `@`. Waits a moment first unless the
    /// answer is cached, so it can run from a `.task(id: query)` on every
    /// keystroke: the next keystroke cancels it before it asks anything. A
    /// service without a token, or one that fails, adds nothing; the failure
    /// shows in Settings.
    func candidates(for query: String) async -> LinkedCandidates {
        await load()
        let wantsLinear = hasToken(.linear)
        let wantsNotion = hasToken(.notion)
        guard wantsLinear || wantsNotion else { return LinkedCandidates() }

        let cachedLinear = wantsLinear ? await linear.cached(query) : []
        let cachedNotion = wantsNotion ? await notion.cached(query) : []
        if let cachedLinear, let cachedNotion {
            return LinkedCandidates(query: query, linear: cachedLinear, notion: cachedNotion)
        }

        do {
            try await Task.sleep(for: Self.debounce)
        } catch {
            return LinkedCandidates()
        }

        let linear = self.linear
        let notion = self.notion
        async let issues = Self.outcome(wantsLinear) { try await linear.search(query) }
        async let pages = Self.outcome(wantsNotion) { try await notion.search(query) }
        let found = LinkedCandidates(query: query, linear: record(await issues, from: .linear) ?? [],
                                     notion: record(await pages, from: .notion) ?? [])

        if !found.notion.isEmpty, !Task.isCancelled {
            let pages = found.notion
            Task { [weak self] in
                if await notion.resolveParents(of: pages) { self?.revision += 1 }
            }
        }
        return found
    }

    /// A pasted link as a mention: nil when it isn't a Linear issue or Notion
    /// page URL, there is no token for it, or the item can't be seen.
    func lookUp(url: String) async -> Mention? {
        await load()
        if LinearIssues.identifier(fromURL: url) != nil, hasToken(.linear) {
            let linear = self.linear
            let found = await Result(awaiting: { try await linear.issue(at: url) })
            return (record(found, from: .linear) ?? nil).map(Mention.linear)
        }
        if NotionPages.pageID(fromURL: url) != nil, hasToken(.notion) {
            let notion = self.notion
            let found = await Result(awaiting: { try await notion.page(at: url) })
            return (record(found, from: .notion) ?? nil).map(Mention.notion)
        }
        return nil
    }

    private nonisolated static func outcome<T: Sendable>(
        _ wanted: Bool, _ run: @Sendable () async throws -> [T]
    ) async -> Result<[T], any Error> {
        guard wanted else { return .success([]) }
        return await Result(awaiting: { try await run() })
    }

    private func record<T>(_ outcome: Result<T, any Error>, from service: LinkedService) -> T? {
        switch outcome {
        case .success(let value):
            if status(of: service).isTrouble || status(of: service) == .unchecked {
                set(.connected(as: nil, at: Date()), for: service)
            }
            return value
        case .failure(let error):
            note(error, from: service)
            return nil
        }
    }

    private func note(_ error: any Error, from service: LinkedService) {
        guard !LinkedServiceError.isCancellation(error) else { return }
        if case LinkedServiceError.noToken = error {
            set(.noToken, for: service)
            return
        }
        if case LinkedServiceError.tokenUnreadable(let status) = error {
            set(.unreadable(status), for: service)
            return
        }
        set(.failed(LinkedServiceError.message(error, for: service), at: Date()), for: service)
    }

    private func set(_ status: LinkedServiceStatus, for service: LinkedService) {
        switch service {
        case .linear: linearStatus = status
        case .notion: notionStatus = status
        }
    }
}

/// Saves to one item, run one at a time off the main thread: a save is a
/// delete then an add, and two at once can interleave.
@MainActor
final class SaveQueue {
    private var last: Task<Void, Never>?
    /// Bumped as each save is queued, so a result can tell a newer one came.
    private(set) var generation = 0

    /// The result, and whether no save was queued after this one, so only the
    /// last action decides what is shown.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> (T, isLatest: Bool) {
        generation += 1
        let mine = generation
        let previous = last
        let task = Task.detached { () -> T in
            await previous?.value
            return work()
        }
        last = Task { _ = await task.value }
        let result = await task.value
        return (result, mine == generation)
    }
}

extension Result where Failure == any Error {
    init(awaiting body: @Sendable () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

/// What the composers search Linear and Notion by: the name being typed after
/// an `@`, and asked again when a result already shown gets better.
struct LinkedSearch: Hashable {
    let query: String?
    let revision: Int

    /// Nil when cancelled by the next keystroke, so what is showing stays.
    @MainActor
    static func run(for query: String?, in store: SessionStore) async -> MentionSearch? {
        guard let query else { return MentionSearch() }
        let found = await store.linkedCandidates(for: query)
        return Task.isCancelled ? nil : MentionSearch(query: found.query, lanes: found.lanes)
    }
}

/// A pasted Linear or Notion link looked up with the same tokens the `@` menu
/// searches with.
struct LinkedWorkLookup: ExternalLinkLookup {
    let work: LinkedWork

    func resolve(_ link: PastedLink) async throws -> LinkResolution? {
        switch await work.lookUp(url: link.url) {
        case .linear(let issue): issue.resolution
        case .notion(let page): page.resolution
        default: nil
        }
    }
}
