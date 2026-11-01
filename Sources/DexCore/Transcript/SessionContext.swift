import Foundation

/// How much a session is carrying, and what carrying it costs.
///
/// Read off the newest assistant turn rather than accumulated: `message.usage`
/// says what that turn actually read, so the reading is the session's context as
/// it stands. Compaction needs no special case — it lands as a turn that reads
/// far less than the one before it, and the newest turn is the one being asked.
///
/// The whole point of the number is that it repeats. A turn re-reads nearly all
/// of it, so context is not a size the session paid for once; it is the price of
/// every turn from here on, which is why an old session becomes the expensive
/// place to do the next piece of work.
public struct SessionContext: Codable, Hashable, Sendable {

    /// Everything the model read to answer: fresh input, what came back from
    /// cache, and what was written to it. The same three fields
    /// `Scripts/maintainer/token-audit.py` adds up, for the same reason — a turn pays for
    /// all three regardless of which side of the cache they landed on.
    public let tokens: Int

    /// What that turn answered as, which is what the re-read is priced at. Nil
    /// on a turn that named no model, and then the cost half goes unsaid rather
    /// than being guessed at some average rate.
    public let model: String?

    /// Read off a compaction boundary rather than a turn. `postTokens` counts
    /// the conversation the CLI kept and not the system prompt and tool schemas
    /// the next request sends with it, so the figure is low by that floor
    /// until the next assistant turn reads the conversation back.
    public let isEstimate: Bool

    public init(tokens: Int, model: String? = nil, isEstimate: Bool = false) {
        self.tokens = tokens
        self.model = model
        self.isEstimate = isEstimate
    }

    /// Where continuing stops being the cheap option. Measured rather than
    /// chosen: `Scripts/maintainer/token-audit.py --long` calls a session worth splitting
    /// at 150 turns, and across a thousand-odd transcripts a session that
    /// has reached that cut is carrying 150k by the tenth percentile. It lands
    /// about 3x what a 10-50 turn session reads per turn (46k, same script), and
    /// 8% of sessions ever cross it — rare enough that a row wearing the badge
    /// is saying something.
    public static let expensive = 150_000

    public var isExpensive: Bool { tokens >= Self.expensive }

    /// What re-reading this costs once, in dollars. Priced at the cache-read
    /// rate, which is the good case and so the floor: a turn that finds the
    /// prefix cold rewrites it at more than ten times this.
    public var carryPerTurn: Double? {
        guard let model,
              let rate = TokenPricing.inputRate(for: model, prompt: tokens),
              let share = TokenPricing.cacheReadShare(for: model)
        else { return nil }
        return Double(tokens) * rate * share
    }

    public var label: String { "\(isEstimate ? "~" : "")\(Format.compact(tokens)) ctx" }

    public var help: String {
        var line = isEstimate
            ? "Carrying about \(Format.compact(tokens)) of context after compacting; the next turn will say exactly"
            : "Carrying \(Format.compact(tokens)) of context"
        if let carry = carryPerTurn {
            line += " — about \(Format.money(carry)) a turn just to read it back, and the next turn pays it again"
        } else {
            line += " — and every turn reads all of it again"
        }
        guard isExpensive else { return line + "." }
        return line + ". A fresh session for the next piece of work starts from nothing."
    }
}

/// List prices per input token, and the share of one a cached read costs.
///
/// The same table `Scripts/maintainer/token-audit.py` carries, and it goes stale on its own
/// schedule — checked against the published rates in October 2026. Only their ratio to each other has to be
/// right: an unknown model is priced at nothing rather than at a guess, which
/// shows as a size with no cost beside it.
enum TokenPricing {

    private struct Rate {
        let input: Double
        let cacheRead: Double
        var longPrompt: (over: Int, input: Double)? = nil
    }

    private static let rates: [String: Rate] = [
        "claude-fable-5-1": Rate(input: 10e-6, cacheRead: 0.025),
        "claude-fable-5": Rate(input: 10e-6, cacheRead: 0.1),
        "claude-mythos-5-1": Rate(input: 10e-6, cacheRead: 0.025),
        "claude-mythos-5": Rate(input: 10e-6, cacheRead: 0.1),
        "claude-opus-5-5": Rate(input: 4e-6, cacheRead: 0.05),
        "claude-opus-5": Rate(input: 5e-6, cacheRead: 0.1),
        "claude-opus-4-8": Rate(input: 5e-6, cacheRead: 0.1),
        "claude-opus-4-7": Rate(input: 5e-6, cacheRead: 0.1),
        "claude-opus-4-6": Rate(input: 5e-6, cacheRead: 0.1),
        "claude-opus-4-5": Rate(input: 5e-6, cacheRead: 0.1),
        "claude-sonnet-5-5": Rate(input: 2e-6, cacheRead: 0.05),
        "claude-sonnet-5": Rate(input: 2e-6, cacheRead: 0.1),
        "claude-sonnet-4-6": Rate(input: 3e-6, cacheRead: 0.1),
        "claude-sonnet-4-5": Rate(input: 3e-6, cacheRead: 0.1),
        "claude-haiku-5-5": Rate(input: 0.1e-6, cacheRead: 0.1, longPrompt: (100_000, 0.5e-6)),
        "claude-haiku-4-5": Rate(input: 1e-6, cacheRead: 0.1),
    ]

    /// `prompt` is the whole request, cached reads included: Haiku 5.5 bills
    /// every token of a prompt over 100k at five times the rate.
    static func inputRate(for model: String, prompt: Int) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        if let long = rate.longPrompt, prompt > long.over { return long.input }
        return rate.input
    }

    static func cacheReadShare(for model: String) -> Double? { rate(for: model)?.cacheRead }

    /// Only a date or a width comes off; a bare prefix priced Opus 5.5 as Opus 5.
    private static func rate(for model: String) -> Rate? {
        var id = String(model.prefix { $0 != "[" })
        if let dash = id.lastIndex(of: "-") {
            let tail = id[id.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { id = String(id[..<dash]) }
        }
        return rates[id]
    }
}
