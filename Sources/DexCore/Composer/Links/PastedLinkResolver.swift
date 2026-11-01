import Foundation

/// Looks one pasted link up. Nil means there was nothing to ask with — no
/// token, no `gh` — which leaves the link a plain link, same as a failure,
/// but isn't one. Linear and Notion lookups conform to this over their own
/// token storage and are handed to `PastedLinkResolver.install`.
public protocol ExternalLinkLookup: Sendable {
    func resolve(_ link: PastedLink) async throws -> LinkResolution?
}

public enum PastedLinkError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case service(String)
    case notFound

    public var description: String {
        switch self {
        case .unreadable: "The service sent back something unreadable"
        case .service(let message): message
        case .notFound: "Not found"
        }
    }
}

/// Sends each pasted link to the lookup for its service and remembers what
/// came back, so pasting the same link twice doesn't ask twice.
public actor PastedLinkResolver {
    private var lookups: [PastedLink.Service: any ExternalLinkLookup]
    private var cache: [String: (LinkResolution, Date)] = [:]
    private let freshFor: TimeInterval

    public init(lookups: [PastedLink.Service: any ExternalLinkLookup] = [:], freshFor: TimeInterval = 5 * 60) {
        self.lookups = lookups
        self.freshFor = freshFor
    }

    public func install(_ lookup: (any ExternalLinkLookup)?, for service: PastedLink.Service) {
        lookups[service] = lookup
        cache = cache.filter { PastedLink(url: $0.key)?.service != service }
    }

    /// Nil when the link couldn't be looked up, for whatever reason: the chip
    /// goes back to being the URL.
    public func resolve(_ link: PastedLink, now: Date = .now) async -> LinkResolution? {
        if let (known, at) = cache[link.url], now.timeIntervalSince(at) < freshFor { return known }
        guard let lookup = lookups[link.service] else { return nil }
        guard let found = try? await lookup.resolve(link) else { return nil }
        cache[link.url] = (found, now)
        return found
    }
}
