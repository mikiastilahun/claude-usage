import Foundation
import SwiftUI

/// What the menu bar title shows at a glance.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case sessionPercent
    case highestPercent
    case weeklyPercent
    case blockCost
    case todayCost
    case todayTokens
    case monthCost
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionPercent: return "Session limit used"
        case .highestPercent: return "Highest limit used"
        case .weeklyPercent: return "Weekly limit used"
        case .blockCost: return "Current 5-hour block cost"
        case .todayCost: return "Today's cost"
        case .todayTokens: return "Today's tokens"
        case .monthCost: return "This month's cost"
        case .iconOnly: return "Icon only"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var entries: [UsageEntry] = []
    /// Recomputed only when entries change; the window boundaries don't move on their own.
    @Published private(set) var blocks: [UsageBlock] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?

    /// Key is versioned: the default changed from cost to plan-limit percent when the
    /// usage endpoint was added, and a stale saved value would hide the new headline.
    private static let metricKey = "menuBarMetric.v2"

    @Published var metric: MenuBarMetric {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: Self.metricKey) }
    }

    /// Plan limits from Claude's usage endpoint — the authoritative percentages.
    @Published private(set) var plan: PlanUsage?
    @Published private(set) var planState: PlanUsageState = .ok

    /// Daily rollups that outlive Claude Code's transcript pruning.
    @Published private(set) var history: [String: DayRecord] = [:]

    private let scanner = UsageScanner()
    private let historyStore = HistoryStore()
    private let planClient = PlanUsageClient()
    private var timer: Timer?
    private var planTimer: Timer?
    private var lastPlanFetch = Date.distantPast

    /// The usage endpoint is rate limited, so poll it far less often than the local files.
    private let planInterval: TimeInterval = 300

    /// e.g. "Max (5x)" — read once at launch.
    let planTier: String? = PlanTier.current()

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.metricKey) ?? ""
        metric = MenuBarMetric(rawValue: saved) ?? .sessionPercent
        UserDefaults.standard.removeObject(forKey: "menuBarMetric")
        plan = Self.loadCachedPlan()

        Task { await refresh() }
        Task { await refreshPlan() }

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        planTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastPlanFetch) >= self.planInterval else { return }
                await self.refreshPlan()
            }
        }
    }

    /// Fetches plan limits. Keeps the last good snapshot on failure so the panel can show
    /// an "as of" note instead of blanking out, matching how `/usage` behaves.
    func refreshPlan(force: Bool = false) async {
        if force { lastPlanFetch = .distantPast }
        lastPlanFetch = Date()
        let (usage, state) = await planClient.fetch()
        planState = state
        if let usage {
            plan = usage
            Self.cachePlan(usage)
        }
    }

    private static let planCacheKey = "cachedPlanUsage"

    private static func cachePlan(_ usage: PlanUsage) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(usage) {
            UserDefaults.standard.set(data, forKey: planCacheKey)
        }
    }

    private static func loadCachedPlan() -> PlanUsage? {
        guard let data = UserDefaults.standard.data(forKey: planCacheKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            return PlanUsage.parseTimestamp(raw) ?? Date.distantPast
        }
        return try? decoder.decode(PlanUsage.self, from: data)
    }

    func refresh() async {
        guard FileManager.default.fileExists(atPath: UsageScanner.projectsDirectory.path) else {
            loadError = "No ~/.claude/projects directory found."
            isLoading = false
            return
        }
        let fresh = await scanner.refresh()
        if fresh.count != entries.count || blocks.isEmpty {
            blocks = UsageAnalytics.blocks(from: fresh, calendar: calendar)
        }
        history = await historyStore.update(with: fresh)
        entries = fresh
        loadError = nil
        lastUpdated = Date()
        isLoading = false
    }

    // MARK: - Time ranges

    private var calendar: Calendar { Calendar.current }

    /// Totals come from the durable rollup rather than the live entries, so figures stay
    /// correct for days whose transcripts Claude Code has already deleted.
    func totals(since start: Date, label: String) -> UsageTotals {
        let startDay = calendar.startOfDay(for: start)
        var t = UsageTotals(label: label)
        for (key, day) in history {
            guard let date = HistoryStore.date(fromKey: key), date >= startDay else { continue }
            t.cost += day.cost
            t.inputTokens += day.input
            t.outputTokens += day.output
            t.cacheRead += day.cacheRead
            t.cacheWrite += day.cacheWrite
            t.messages += day.messages
        }
        return t
    }

    var today: UsageTotals {
        totals(since: calendar.startOfDay(for: Date()), label: "Today")
    }

    var last7Days: UsageTotals {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        return totals(since: start, label: "Last 7 days")
    }

    var thisMonth: UsageTotals {
        let comps = calendar.dateComponents([.year, .month], from: Date())
        let start = calendar.date(from: comps) ?? Date()
        return totals(since: start, label: "This month")
    }

    var allTime: UsageTotals {
        totals(since: .distantPast, label: "All time")
    }

    /// True when the rollup covers days whose transcripts have since been deleted.
    var historyExceedsTranscripts: Bool {
        guard let earliestEntry = entries.first?.timestamp,
              let earliestKey = history.keys.min(),
              let earliestDay = HistoryStore.date(fromKey: earliestKey)
        else { return false }
        return earliestDay < calendar.startOfDay(for: earliestEntry)
    }

    var historyDayCount: Int { history.count }

    // MARK: - 5-hour blocks

    var activeBlock: UsageBlock? {
        blocks.last.flatMap { $0.isActive ? $0 : nil }
    }

    // MARK: - Breakdowns

    func breakdownByModel(since start: Date) -> [UsageTotals] {
        let startDay = calendar.startOfDay(for: start)
        var map: [String: UsageTotals] = [:]
        for (key, day) in history {
            guard let date = HistoryStore.date(fromKey: key), date >= startDay else { continue }
            for (model, stats) in day.models {
                let name = Pricing.displayName(model)
                var row = map[name] ?? UsageTotals(label: name)
                row.cost += stats.cost
                row.outputTokens += stats.tokens
                row.messages += stats.messages
                map[name] = row
            }
        }
        return map.values.sorted { $0.cost > $1.cost }
    }

    func breakdownByProject(since start: Date) -> [UsageTotals] {
        UsageAnalytics.group(entries, since: start) { $0.project }
    }

    /// Daily cost for the last `days` days, oldest first, for the sparkline.
    func dailyCosts(days: Int) -> [(date: Date, cost: Double)] {
        let today = calendar.startOfDay(for: Date())
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - (days - 1), to: today) else { return nil }
            return (day, history[HistoryStore.dayKey(day)]?.cost ?? 0)
        }
    }

    // MARK: - Menu bar title

    var menuBarText: String {
        switch metric {
        case .sessionPercent:
            return Format.percent(plan?.session?.percent)
        case .highestPercent:
            return Format.percent(plan?.headline?.percent)
        case .weeklyPercent:
            return Format.percent(plan?.weekly.max { $0.percent < $1.percent }?.percent)
        case .blockCost:
            return Format.cost(activeBlock?.totals.cost ?? 0)
        case .todayCost:
            return Format.cost(today.cost)
        case .todayTokens:
            return Format.tokens(today.totalTokens)
        case .monthCost:
            return Format.cost(thisMonth.cost)
        case .iconOnly:
            return ""
        }
    }
}
