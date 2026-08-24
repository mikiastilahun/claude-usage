import Foundation

/// One assistant response's token usage, parsed from a Claude Code transcript line.
struct UsageEntry: Sendable {
    let timestamp: Date
    let model: String
    let project: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheRead + cacheWrite5m + cacheWrite1h
    }

    var cost: Double { Pricing.cost(for: self) }
}

/// Totals for a slice of entries (a day, a 5-hour block, one model, one project).
struct UsageTotals: Sendable, Identifiable {
    var id: String { label }
    var label: String = ""
    var cost: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var messages: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }

    mutating func add(_ e: UsageEntry) {
        cost += e.cost
        inputTokens += e.inputTokens
        outputTokens += e.outputTokens
        cacheRead += e.cacheRead
        cacheWrite += e.cacheWrite
        messages += 1
    }

    static func of(_ entries: [UsageEntry], label: String = "") -> UsageTotals {
        var t = UsageTotals(label: label)
        for e in entries { t.add(e) }
        return t
    }
}

/// A rolling 5-hour usage window, mirroring how Claude Code subscription limits reset.
struct UsageBlock: Sendable, Identifiable {
    let id: Date
    let start: Date
    let end: Date
    let lastActivity: Date
    let totals: UsageTotals

    var isActive: Bool { Date() < end }

    /// 0...1 of the window elapsed.
    var elapsedFraction: Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 1 }
        return min(max(Date().timeIntervalSince(start) / span, 0), 1)
    }

    var timeRemaining: TimeInterval { max(end.timeIntervalSinceNow, 0) }

    /// Cost per hour, measured over the active portion of the block.
    var burnRate: Double {
        let hours = max(lastActivity.timeIntervalSince(start) / 3600, 1.0 / 60)
        return totals.cost / hours
    }

    /// Cost this block would reach if the current burn rate held to the end.
    var projectedCost: Double {
        guard isActive else { return totals.cost }
        return totals.cost + burnRate * (timeRemaining / 3600)
    }
}
