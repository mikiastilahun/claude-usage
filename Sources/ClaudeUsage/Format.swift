import Foundation

enum Format {
    static func cost(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.0f", value)
        } else if value >= 100 {
            return String(format: "$%.1f", value)
        }
        return String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...:
            return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", v / 1_000)
        default:
            return "\(value)"
        }
    }

    /// Percentages arrive as whole numbers; show a decimal only below 1% so small
    /// but nonzero usage doesn't read as "0%".
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0 && value < 1 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    /// "Resets in 4 hr 19 min", matching the wording in Claude's usage panel.
    static func resetsIn(_ date: Date?) -> String {
        guard let date else { return "" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "Resetting now" }
        let total = Int(remaining)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "Resets in \(days)d \(hours) hr" }
        if hours > 0 { return "Resets in \(hours) hr \(minutes) min" }
        return "Resets in \(minutes) min"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func clockRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "E"
        return f.string(from: date)
    }
}
