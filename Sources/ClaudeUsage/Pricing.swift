import Foundation

struct ModelRate: Sendable {
    /// USD per 1M input tokens.
    let input: Double
    /// USD per 1M output tokens.
    let output: Double
}

/// Public Anthropic API list prices, used to express local usage as an
/// API-equivalent dollar figure. Subscription plans are not billed this way.
enum Pricing {
    /// Cache reads cost 0.1x base input; 5-minute cache writes 1.25x; 1-hour cache writes 2x.
    static let cacheReadMultiplier = 0.1
    static let cacheWrite5mMultiplier = 1.25
    static let cacheWrite1hMultiplier = 2.0

    private static let rates: [String: ModelRate] = [
        "claude-fable-5": ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
        "claude-opus-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-8": ModelRate(input: 5, output: 25),
        "claude-opus-4-7": ModelRate(input: 5, output: 25),
        "claude-opus-4-6": ModelRate(input: 5, output: 25),
        "claude-opus-4-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-1": ModelRate(input: 15, output: 75),
        "claude-opus-4": ModelRate(input: 15, output: 75),
        "claude-sonnet-5": ModelRate(input: 3, output: 15),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-sonnet-4-5": ModelRate(input: 3, output: 15),
        "claude-sonnet-4": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5),
        "claude-3-5-haiku": ModelRate(input: 0.8, output: 4),
    ]

    /// Sonnet 5 launched with introductory pricing of $2/$10 through 2026-08-31.
    private static let sonnet5IntroEnd: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 1
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c) ?? .distantPast
    }()

    /// Longest-prefix match so dated model ids (`claude-haiku-4-5-20251001`) resolve too.
    static func rate(for model: String, at date: Date) -> ModelRate? {
        if model == "claude-sonnet-5" || model.hasPrefix("claude-sonnet-5-") {
            return date < sonnet5IntroEnd
                ? ModelRate(input: 2, output: 10)
                : ModelRate(input: 3, output: 15)
        }
        if let exact = rates[model] { return exact }
        var best: (key: String, rate: ModelRate)?
        for (key, rate) in rates where model.hasPrefix(key) {
            if best == nil || key.count > best!.key.count { best = (key, rate) }
        }
        return best?.rate
    }

    static func cost(for e: UsageEntry) -> Double {
        guard let r = rate(for: e.model, at: e.timestamp) else { return 0 }
        let inPer = r.input / 1_000_000
        let outPer = r.output / 1_000_000
        return Double(e.inputTokens) * inPer
            + Double(e.outputTokens) * outPer
            + Double(e.cacheRead) * inPer * cacheReadMultiplier
            + Double(e.cacheWrite5m) * inPer * cacheWrite5mMultiplier
            + Double(e.cacheWrite1h) * inPer * cacheWrite1hMultiplier
    }

    /// "claude-fable-5" -> "Fable 5"
    static func displayName(_ model: String) -> String {
        var s = model
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Strip a trailing date stamp such as "-20251001".
        let parts = s.split(separator: "-")
        var kept = parts
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            kept = Array(parts.dropLast())
        }
        guard let family = kept.first else { return model }
        let version = kept.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
