import Foundation

/// Linear issue search and lookup with the user's personal API key. Answers
/// are kept for a minute; a cancelled caller cancels its request.
public actor LinearClient {
    private let secrets: any SecretStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var searches: ExpiringCache<[LinearIssueMention]>
    private var issues: ExpiringCache<LinearIssueMention?>

    public init(secrets: any SecretStore, transport: @escaping HTTPTransport = HTTP.live,
                lifetime: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.transport = transport
        self.now = now
        self.searches = ExpiringCache(lifetime: lifetime)
        self.issues = ExpiringCache(lifetime: lifetime * 5)
    }

    public func forget() {
        searches.removeAll()
        issues.removeAll()
    }

    public func cached(_ query: String) -> [LinearIssueMention]? {
        searches.value(for: Self.key(query), now: now())
    }

    /// Recent and assigned for an empty query. An identifier (`ENG-123`) is
    /// looked up directly and put first, ahead of titles that match it.
    public func search(_ query: String) async throws -> [LinearIssueMention] {
        let key = Self.key(query)
        if let hit = searches.value(for: key, now: now()) { return hit }
        let token = try token()

        let found: [LinearIssueMention]
        if key.isEmpty {
            found = try LinearIssues.parseRecent(try await send(LinearIssues.recentBody(), token: token))
        } else if let identifier = LinearIssues.identifier(in: key) {
            async let exact = issue(identifier: identifier)
            async let titled = LinearIssues.parseSearch(try await send(LinearIssues.searchBody(for: key), token: token))
            found = LinearIssues.unique([try await exact].compactMap { $0 } + (try await titled))
        } else {
            found = try LinearIssues.parseSearch(try await send(LinearIssues.searchBody(for: key), token: token))
        }
        searches.store(found, for: key, now: now())
        return found
    }

    /// Nil for an issue that doesn't exist or this key can't see.
    public func issue(identifier: String) async throws -> LinearIssueMention? {
        guard let identifier = LinearIssues.identifier(in: identifier) else { return nil }
        if let hit = issues.value(for: identifier, now: now()) { return hit }
        let found = try LinearIssues.parseIssue(try await send(LinearIssues.issueBody(identifier: identifier), token: try token()))
        issues.store(found, for: identifier, now: now())
        return found
    }

    /// Nil when the URL isn't a Linear issue's, or the issue can't be found.
    public func issue(at url: String) async throws -> LinearIssueMention? {
        guard let identifier = LinearIssues.identifier(fromURL: url) else { return nil }
        return try await issue(identifier: identifier)
    }

    /// Whose key this is, which also proves it works.
    public func whoAmI() async throws -> String? {
        try LinearIssues.parseViewer(try await send(LinearIssues.viewerBody(), token: try token()))
    }

    private func token() throws -> String {
        try secrets.token(for: .linear)
    }

    private func send(_ body: Data, token: String) async throws -> Data {
        let (data, response) = try await transport(LinearIssues.request(body, key: token))
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 || status == 429 { _ = try LinearIssues.payload(data, status: status) }
        return data
    }

    static func key(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Notion page search and lookup with an internal integration's token. The
/// integration sees only the pages shared with it.
public actor NotionClient {
    private let secrets: any SecretStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var searches: ExpiringCache<[NotionPageMention]>
    private var pages: ExpiringCache<NotionPageMention?>
    private var parentTitles: ExpiringCache<String?>
    private var resolving: Set<String> = []

    static let parentsPerSearch = 3

    public init(secrets: any SecretStore, transport: @escaping HTTPTransport = HTTP.live,
                lifetime: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.transport = transport
        self.now = now
        self.searches = ExpiringCache(lifetime: lifetime)
        self.pages = ExpiringCache(lifetime: lifetime * 5)
        self.parentTitles = ExpiringCache(lifetime: 60 * 60)
    }

    public func forget() {
        searches.removeAll()
        pages.removeAll()
        parentTitles.removeAll()
    }

    public func cached(_ query: String) -> [NotionPageMention]? {
        searches.value(for: LinearClient.key(query), now: now()).map(named)
    }

    /// Pages matching the query, or the most recently edited for an empty one,
    /// each with its parent's title if that is already known. Call
    /// `resolveParents(of:)` after to learn the rest.
    public func search(_ query: String) async throws -> [NotionPageMention] {
        let key = LinearClient.key(query)
        if let hit = searches.value(for: key, now: now()) { return named(hit) }
        let (data, status) = try await send(NotionPages.searchRequest(for: key, token: try token()))
        let found = try NotionPages.parseSearch(data, status: status)
        searches.store(found, for: key, now: now())
        for page in found { parentTitles.store(page.title, for: page.pageID, now: now()) }
        return named(found)
    }

    public func page(id: String) async throws -> NotionPageMention? {
        let id = NotionPages.undashed(id)
        if let hit = pages.value(for: id, now: now()) { return hit.map(named) }
        let (data, status) = try await send(NotionPages.pageRequest(id: id, token: try token()))
        let found = try NotionPages.parsePage(data, status: status)
        pages.store(found, for: id, now: now())
        return found.map(named)
    }

    /// Nil when the URL isn't a Notion page's, or the integration can't see it.
    public func page(at url: String) async throws -> NotionPageMention? {
        guard let id = NotionPages.pageID(fromURL: url) else { return nil }
        return try await page(id: id)
    }

    /// Looks up a few parents not yet named, a page or database each. Returns
    /// whether any title was learned. A parent the integration can't see is
    /// remembered as unnamed so it isn't asked again for an hour.
    @discardableResult
    public func resolveParents(of pages: [NotionPageMention]) async -> Bool {
        var seen = Set<String>()
        let wanted = pages.compactMap(\.parent.lookupID)
            .filter { parentTitles.value(for: $0, now: now()) == nil && !resolving.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(Self.parentsPerSearch)
        guard !wanted.isEmpty, let token = secrets.secret(for: .notion) else { return false }
        let kinds = Dictionary(pages.compactMap { page in page.parent.lookupID.map { ($0, page.parent) } },
                               uniquingKeysWith: { first, _ in first })
        resolving.formUnion(wanted)
        defer { resolving.subtract(wanted) }

        let transport = self.transport
        let titles = await withTaskGroup(of: (String, String??).self) { group in
            for id in wanted {
                let request = if case .database = kinds[id] {
                    NotionPages.databaseRequest(id: id, token: token)
                } else {
                    NotionPages.pageRequest(id: id, token: token)
                }
                group.addTask {
                    do {
                        let (data, response) = try await transport(request)
                        let status = (response as? HTTPURLResponse)?.statusCode
                        return (id, .some(try NotionPages.parseParentTitle(data, status: status)))
                    } catch LinkedServiceError.api {
                        return (id, .some(nil))
                    } catch {
                        return (id, nil)
                    }
                }
            }
            var titles: [(String, String??)] = []
            for await answer in group { titles.append(answer) }
            return titles
        }
        var learned = false
        for (id, title) in titles {
            guard let title else { continue }
            parentTitles.store(title, for: id, now: now())
            learned = learned || title != nil
        }
        return learned
    }

    public func whoAmI() async throws -> String? {
        let (data, status) = try await send(NotionPages.meRequest(token: try token()))
        return try NotionPages.parseMe(data, status: status)
    }

    private func named(_ page: NotionPageMention) -> NotionPageMention {
        guard let id = page.parent.lookupID, let title = parentTitles.value(for: id, now: now()) else { return page }
        var named = page
        named.parentTitle = title
        return named
    }

    private func named(_ pages: [NotionPageMention]) -> [NotionPageMention] {
        pages.map(named)
    }

    private func token() throws -> String {
        try secrets.token(for: .notion)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int?) {
        let (data, response) = try await transport(request)
        return (data, (response as? HTTPURLResponse)?.statusCode)
    }
}
