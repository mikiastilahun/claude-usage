import Foundation

/// One day's rolled-up usage, kept after Claude Code prunes the transcripts it came from.
struct DayRecord: Sendable, Codable {
    var cost: Double = 0
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var messages: Int = 0
    var models: [String: ModelDay] = [:]

    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    /// Keeps the highest value ever observed for each field. Transcripts only ever
    /// disappear, so a later scan of a past day can only under-report it.
    func merged(with other: DayRecord) -> DayRecord {
        var out = DayRecord(
            cost: Swift.max(cost, other.cost),
            input: Swift.max(input, other.input),
            output: Swift.max(output, other.output),
            cacheRead: Swift.max(cacheRead, other.cacheRead),
            cacheWrite: Swift.max(cacheWrite, other.cacheWrite),
            messages: Swift.max(messages, other.messages),
            models: models
        )
        for (name, incoming) in other.models {
            out.models[name] = out.models[name].map { $0.merged(with: incoming) } ?? incoming
        }
        return out
    }
}

struct ModelDay: Sendable, Codable {
    var cost: Double = 0
    var tokens: Int = 0
    var messages: Int = 0

    func merged(with other: ModelDay) -> ModelDay {
        ModelDay(
            cost: Swift.max(cost, other.cost),
            tokens: Swift.max(tokens, other.tokens),
            messages: Swift.max(messages, other.messages)
        )
    }
}

/// Durable daily history.
///
/// Claude Code prunes `~/.claude/projects` on its own schedule — on this machine a cleanup
/// removed roughly a month of transcripts in one pass. Without this, "all time" silently
/// shrinks as old sessions are deleted. Every scan is folded into a rollup on disk that
/// only ever grows.
actor HistoryStore {
    private var days: [String: DayRecord] = [:]
    private var loaded = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ClaudeUsage/history.json")
    }

    /// Folds the current scan into the stored history and returns the merged result.
    func update(with entries: [UsageEntry]) -> [String: DayRecord] {
        load()

        var fresh: [String: DayRecord] = [:]
        for e in entries {
            let key = Self.formatter.string(from: e.timestamp)
            var day = fresh[key] ?? DayRecord()
            day.cost += e.cost
            day.input += e.inputTokens
            day.output += e.outputTokens
            day.cacheRead += e.cacheRead
            day.cacheWrite += e.cacheWrite
            day.messages += 1

            var model = day.models[e.model] ?? ModelDay()
            model.cost += e.cost
            model.tokens += e.totalTokens
            model.messages += 1
            day.models[e.model] = model
            fresh[key] = day
        }

        var changed = false
        for (key, day) in fresh {
            let merged = days[key].map { $0.merged(with: day) } ?? day
            if days[key] == nil || merged.cost != days[key]?.cost || merged.messages != days[key]?.messages {
                changed = true
            }
            days[key] = merged
        }
        if changed { save() }
        return days
    }

    func snapshot() -> [String: DayRecord] {
        load()
        return days
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: DayRecord].self, from: data)
        else { return }
        days = decoded
    }

    private func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(days) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func dayKey(_ date: Date) -> String { formatter.string(from: date) }
    nonisolated static func date(fromKey key: String) -> Date? { formatter.date(from: key) }
}
