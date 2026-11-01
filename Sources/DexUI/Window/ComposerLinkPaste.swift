import DexCore
import AppKit

/// What the composer's text view does with a chip that stands for a pasted
/// link. `ComposerTextView` is the one that does. Chips waiting on a lookup
/// are found by their URL, since the one the lookup started for may have been
/// rebuilt from the draft since: a switch away and back, the overlay closed
/// and opened, an undo and redo, a relaunch.
@MainActor
protocol LinkChipHost: AnyObject {
    /// Put a chip for `mention` where `range` was. False if it couldn't be placed.
    func insertLinkChip(_ mention: Mention, replacing range: NSRange) -> Bool

    /// Redraw every chip still waiting on `url` with what the lookup found. A
    /// chip the reader deleted meanwhile is left deleted.
    func updateLinkChips(for url: String, to mention: Mention)

    /// Turn every chip still waiting on `url` back into the URL as text.
    func unchipLinks(for url: String)
}

/// A lone link pasted into the composer becomes a chip at once, saying what
/// the URL gives away, and fills in its title when the lookup answers. A
/// lookup that fails or has nothing to ask with puts the URL back as text.
@MainActor
final class ComposerLinkPaste {
    static var resolver = PastedLinkResolver(lookups: [
        .github: GitHubLinkLookup(),
        .slack: SlackLinkLookup(),
    ])

    weak var host: LinkChipHost?
    private let resolver: PastedLinkResolver
    /// By URL, so a chip rebuilt while its lookup is out isn't asked about twice.
    private var lookups: [String: Task<Void, Never>] = [:]

    /// Links whose lookup failed in this field. A chip for one that undo
    /// brings back stays a waiting chip rather than being looked up and
    /// unchipped again, which would answer every Cmd-Z with a new edit.
    private var failed: Set<String> = []

    init(host: LinkChipHost? = nil, resolver: PastedLinkResolver = ComposerLinkPaste.resolver) {
        self.host = host
        self.resolver = resolver
    }

    deinit {
        for task in lookups.values { task.cancel() }
    }

    /// True when the paste was taken as a link chip; false leaves the caller
    /// to paste as it would have.
    func paste(from pasteboard: NSPasteboard, replacing range: NSRange) -> Bool {
        guard let text = pasteboard.string(forType: .string) else { return false }
        return paste(text, replacing: range)
    }

    func paste(_ text: String, replacing range: NSRange) -> Bool {
        guard let host else { return false }
        if let session = SessionLink(pasted: text).flatMap(SessionMention.init) {
            return host.insertLinkChip(.session(session), replacing: range)
        }
        guard let link = PastedLink(pasted: text) else { return false }
        guard host.insertLinkChip(.link(LinkMention(link)), replacing: range) else { return false }
        failed.remove(link.url)
        lookUp(link)
        return true
    }

    /// Chips still waiting that nothing is looking up: ones the field built
    /// from a draft rather than from a paste.
    func resume(_ waiting: [PastedLink]) {
        for link in waiting where !failed.contains(link.url) { lookUp(link) }
    }

    /// Another draft is showing, and its links deserve a try of their own.
    func forgetFailures() {
        failed = []
    }

    private func lookUp(_ link: PastedLink) {
        guard lookups[link.url] == nil else { return }
        lookups[link.url] = Task { [weak self, resolver] in
            let found = await resolver.resolve(link)
            guard !Task.isCancelled, let self else { return }
            if let found {
                self.host?.updateLinkChips(for: link.url, to: .link(LinkMention(link, resolution: found)))
            } else {
                self.failed.insert(link.url)
                self.host?.unchipLinks(for: link.url)
            }
            self.lookups[link.url] = nil
        }
    }
}
