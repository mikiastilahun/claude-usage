import Foundation

/// `Claude Usage --report` — prints the same figures the menu bar shows, for the terminal.
enum Report {
    static func run() {
        let scanner = UsageScanner()
        let client = PlanUsageClient()
        let historyStore = HistoryStore()
        let gate = DispatchSemaphore(value: 0)
        var entries: [UsageEntry] = []
        var history: [String: DayRecord] = [:]
        var plan: PlanUsage?
        var planState: PlanUsageState = .ok

        Task {
            entries = await scanner.refresh()
            history = await historyStore.update(with: entries)
            let result = await client.fetch()
            plan = result.usage
            planState = result.state
            gate.signal()
        }
        gate.wait()

        printPlan(plan, state: planState)

        guard !history.isEmpty else {
            print("No Claude Code usage found in \(UsageScanner.projectsDirectory.path)")
            return
        }

        let calendar = Calendar.current
        let all = totals(history, since: .distantPast)
        print("Token usage — API-equivalent cost\n")
        print(String(format: "  responses  %d", all.messages))
        print(String(format: "  tokens     %@", groupedTokens(all.totalTokens)))
        print(String(format: "  all time   $%.2f  (%d days recorded)", all.cost, history.count))

        let today = calendar.startOfDay(for: Date())
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? today
        print(String(format: "  today      $%.2f", totals(history, since: today).cost))
        print(String(format: "  last 7d    $%.2f", totals(history, since: week).cost))
        print(String(format: "  this month $%.2f", totals(history, since: month).cost))

        print("\nBy model")
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
        for day in history.values {
            for (model, stats) in day.models {
                var row = byModel[model] ?? (0, 0)
                row.cost += stats.cost
                row.tokens += stats.tokens
                byModel[model] = row
            }
        }
        for (model, row) in byModel.sorted(by: { $0.value.cost > $1.value.cost }) {
            let name = model.padding(toLength: max(24, model.count), withPad: " ", startingAt: 0)
            print(String(format: "  %@ $%9.2f   %@", name, row.cost, groupedTokens(row.tokens)))
        }

        let blocks = UsageAnalytics.blocks(from: entries)
        print("\n5-hour blocks: \(blocks.count)")
        if let busiest = blocks.max(by: { $0.totals.cost < $1.totals.cost }) {
            print(String(format: "  busiest    $%.2f", busiest.totals.cost))
        }
        if let current = blocks.last, current.isActive {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            print(String(format: "  active     $%.2f  started %@  %@ left  (%d responses)",
                         current.totals.cost,
                         f.string(from: current.start),
                         Format.duration(current.timeRemaining),
                         current.totals.messages))
        } else {
            print("  active     none")
        }
    }

    private static func printPlan(_ plan: PlanUsage?, state: PlanUsageState) {
        let tier = PlanTier.current().map { " — \($0)" } ?? ""
        print("Plan usage limits\(tier)\n")
        guard let plan, !plan.limits.isEmpty else {
            switch state {
            case .noCredentials: print("  not signed in to Claude Code\n")
            case .unauthorized:  print("  token expired — run `claude` to refresh\n")
            case .rateLimited:   print("  usage endpoint rate limited\n")
            case .failed(let m): print("  unavailable (\(m))\n")
            case .ok:            print("  unavailable\n")
            }
            return
        }
        for limit in plan.limits {
            let name = limit.label.padding(toLength: max(16, limit.label.count), withPad: " ", startingAt: 0)
            let bar = meter(limit.percent)
            print(String(format: "  %@ %@ %5@   %@",
                         name, bar, Format.percent(limit.percent), Format.resetsIn(limit.resetsAt)))
        }
        print()
    }

    private static func meter(_ percent: Double, width: Int = 20) -> String {
        let filled = Int((min(max(percent, 0), 100) / 100 * Double(width)).rounded())
        return "[" + String(repeating: "#", count: filled)
             + String(repeating: "·", count: width - filled) + "]"
    }

    private static func totals(_ history: [String: DayRecord], since: Date) -> UsageTotals {
        let startDay = Calendar.current.startOfDay(for: since)
        var t = UsageTotals()
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

    private static func groupedTokens(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
