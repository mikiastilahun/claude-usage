import Foundation

/// Pure aggregation over parsed entries, shared by the menu bar app and the CLI report.
enum UsageAnalytics {
    /// Claude Code's usage windows are 5 hours long, anchored to the top of the hour.
    static let blockHours: Double = 5

    /// Groups entries into 5-hour windows. A window opens at the top of the hour of its
    /// first message and closes 5 hours later, or earlier if activity goes quiet for 5 hours.
    static func blocks(from entries: [UsageEntry], calendar: Calendar = .current) -> [UsageBlock] {
        guard !entries.isEmpty else { return [] }
        let span = blockHours * 3600
        var result: [UsageBlock] = []
        var start = floorToHour(entries[0].timestamp, calendar)
        var last = entries[0].timestamp
        var bucket: [UsageEntry] = []

        for e in entries {
            let overran = e.timestamp >= start.addingTimeInterval(span)
            let idled = e.timestamp.timeIntervalSince(last) >= span
            if !bucket.isEmpty, overran || idled {
                result.append(block(start: start, last: last, entries: bucket))
                start = floorToHour(e.timestamp, calendar)
                bucket = []
            }
            bucket.append(e)
            last = e.timestamp
        }
        if !bucket.isEmpty {
            result.append(block(start: start, last: last, entries: bucket))
        }
        return result
    }

    private static func block(start: Date, last: Date, entries: [UsageEntry]) -> UsageBlock {
        UsageBlock(
            id: start,
            start: start,
            end: start.addingTimeInterval(blockHours * 3600),
            lastActivity: last,
            totals: UsageTotals.of(entries)
        )
    }

    private static func floorToHour(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    static func group(_ entries: [UsageEntry], since start: Date, by key: (UsageEntry) -> String) -> [UsageTotals] {
        var map: [String: UsageTotals] = [:]
        for e in entries where e.timestamp >= start {
            let k = key(e)
            map[k, default: UsageTotals(label: k)].add(e)
        }
        return map.values.sorted { $0.cost > $1.cost }
    }
}
