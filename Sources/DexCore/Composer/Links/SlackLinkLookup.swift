import Foundation

/// A Slack message, thread or channel, through a user token (`xoxp-…`) kept
/// in Settings. Scopes it needs: `channels:history`, `groups:history`,
/// `im:history`, `mpim:history`, the matching `:read` scopes, and `users:read`.
public struct SlackLinkLookup: ExternalLinkLookup {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let token: @Sendable () -> String?
    private let fetch: Fetch

    public init(
        token: @escaping @Sendable () -> String? = { SlackToken.read() },
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0).0 }
    ) {
        self.token = token
        self.fetch = fetch
    }

    public func resolve(_ link: PastedLink) async throws -> LinkResolution? {
        guard case .slack(let slack) = link, let token = token() else { return nil }

        let channelName = try SlackAPI.channelName(
            in: try await call("conversations.info", ["channel": slack.channel], token: token))
        let place = channelName.map { "#\($0)" } ?? "a direct message"

        let data: Data
        let wanted: String
        switch slack.kind {
        case .channel:
            return LinkResolution(title: channelName.map { "#\($0)" } ?? "Direct message", detail: "Slack channel")
        case .thread:
            wanted = slack.threadTs!
            data = try await call("conversations.replies", ["channel": slack.channel, "ts": wanted, "limit": "1"], token: token)
        case .message:
            wanted = slack.ts!
            data = try await call("conversations.history", ["channel": slack.channel, "latest": wanted, "inclusive": "true", "limit": "1"], token: token)
        case .reply:
            wanted = slack.ts!
            data = try await call("conversations.replies", ["channel": slack.channel, "ts": slack.threadTs!, "oldest": wanted, "inclusive": "true", "limit": "2"], token: token)
        }

        let what = slack.kind == .thread ? "Thread" : "Message"
        guard let message = try SlackAPI.message(ts: wanted, in: data) else {
            return LinkResolution(title: "\(what) in \(place)", detail: "Slack")
        }
        var names: [String: String] = [:]
        for user in Set(SlackAPI.mentionedUsers(message.text) + [message.user].compactMap { $0 }) {
            names[user] = try? SlackAPI.userName(in: try await call("users.info", ["user": user], token: token))
        }
        let text = SlackAPI.plainText(message.text, users: names)
        let author = message.user.flatMap { names[$0] }
        return LinkResolution(
            title: text.isEmpty ? "\(what) in \(place)" : LinkSentence.shortened(text),
            detail: [author, place].compactMap { $0 }.joined(separator: " in "))
    }

    private func call(_ method: String, _ parameters: [String: String], token: String) async throws -> Data {
        try await fetch(SlackAPI.request(method, parameters, token: token))
    }
}

/// The Web API calls a Slack chip needs, and the mrkdwn cleanup.
public enum SlackAPI {

    public static func request(_ method: String, _ parameters: [String: String], token: String) -> URLRequest {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// Every Web API reply carries `ok`; on false, `error` says why.
    public static func payload(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PastedLinkError.unreadable
        }
        guard root["ok"] as? Bool == true else {
            throw PastedLinkError.service(root["error"] as? String ?? "Slack returned an error")
        }
        return root
    }

    /// The message with exactly this timestamp. `conversations.history` and
    /// `conversations.replies` answer with neighbours when it is gone.
    public static func message(ts: String, in data: Data) throws -> (text: String, user: String?)? {
        let messages = try payload(data)["messages"] as? [[String: Any]] ?? []
        guard let message = messages.first(where: { $0["ts"] as? String == ts }) else { return nil }
        return (message["text"] as? String ?? "", message["user"] as? String)
    }

    /// `conversations.info`. A DM has no name.
    public static func channelName(in data: Data) throws -> String? {
        let channel = try payload(data)["channel"] as? [String: Any]
        return channel?["name"] as? String
    }

    /// `users.info`: the display name people chose, else their real name.
    public static func userName(in data: Data) throws -> String? {
        let user = try payload(data)["user"] as? [String: Any]
        let profile = user?["profile"] as? [String: Any]
        for candidate in [profile?["display_name"], profile?["real_name"], user?["real_name"], user?["name"]] {
            if let name = candidate as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// `auth.test`: which workspace and who, for Settings to confirm a token.
    public static func identity(in data: Data) throws -> (team: String, user: String) {
        let root = try payload(data)
        return (root["team"] as? String ?? "?", root["user"] as? String ?? "?")
    }

    /// Slack's `<…>` escapes as the words they stand for, on one line.
    /// `users` names the `<@U…>` mentions that could be looked up.
    public static func plainText(_ mrkdwn: String, users: [String: String] = [:]) -> String {
        var text = mrkdwn.replacing(#/<([^>|]+)(?:\|([^>]*))?>/#) { match in
            let target = String(match.1)
            if let label = match.2, !label.isEmpty {
                return target.hasPrefix("#") ? "#\(label)" : String(label)
            }
            if target.hasPrefix("@") {
                return "@" + (users[String(target.dropFirst())] ?? "someone")
            }
            if target.hasPrefix("!") { return "@" + target.dropFirst() }
            return target
        }
        text = text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The `<@U…>` ids in a message, for looking their names up.
    public static func mentionedUsers(_ mrkdwn: String) -> [String] {
        mrkdwn.matches(of: #/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/#).map { String($0.1) }
    }
}

/// The Slack token, where `ConnectionTokens` keeps it.
public enum SlackToken {
    public static func read() -> String? {
        reading().token
    }

    public static func reading() -> TokenReading {
        ConnectionTokens.store.reading("slack")
    }

    /// An empty token removes the one saved.
    public static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try ConnectionTokens.store.save(trimmed, as: "slack", label: "Dex Slack token")
    }
}
