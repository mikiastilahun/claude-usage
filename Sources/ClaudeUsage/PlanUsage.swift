import Foundation

/// The plan usage limits shown in Claude's Settings > Usage panel.
///
/// Decoded from the `limits` array so new limit kinds appear automatically rather than
/// needing a code change for each one.
struct PlanUsage: Sendable, Codable {
    var limits: [Limit] = []
    var extraUsage: ExtraUsage?
    /// When this snapshot was fetched, for the "as of" note.
    var fetchedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case limits, extraUsage, fetchedAt
    }

    init() {}

    /// Hand-written so a missing `fetchedAt` (the API never sends one) isn't a decode
    /// failure, and so one unrecognized limit entry can't discard the whole payload.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limits = (try? c.decode([Limit].self, forKey: .limits)) ?? []
        extraUsage = try? c.decode(ExtraUsage.self, forKey: .extraUsage)
        fetchedAt = (try? c.decode(Date.self, forKey: .fetchedAt)) ?? Date()
    }

    struct Limit: Sendable, Codable, Identifiable {
        let kind: String
        var group: String?
        var percent: Double
        var severity: String?
        var resetsAt: Date?
        var scope: Scope?
        var isActive: Bool?

        var id: String { kind + (scope?.model?.displayName ?? "") }

        /// "Current session", "All models", "Fable"
        var label: String {
            switch kind {
            case "session": return "Current session"
            case "weekly_all": return "All models"
            case "weekly_scoped":
                return scope?.model?.displayName ?? scope?.surface ?? "Scoped limit"
            default:
                return kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        var isWeekly: Bool { group == "weekly" }
    }

    struct Scope: Sendable, Codable {
        var model: ModelRef?
        var surface: String?
    }

    struct ModelRef: Sendable, Codable {
        var id: String?
        var displayName: String?
    }

    struct ExtraUsage: Sendable, Codable {
        var isEnabled: Bool?
        var usedCredits: Double?
        var monthlyLimit: Double?
        var utilization: Double?
        var currency: String?
        var disabledReason: String?
    }

    var session: Limit? { limits.first { $0.kind == "session" } }
    var weekly: [Limit] { limits.filter { $0.isWeekly } }

    /// The single number worth putting in the menu bar: whichever limit is closest to its cap.
    var headline: Limit? { limits.max { $0.percent < $1.percent } }

    static func decode(_ data: Data) throws -> PlanUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unrecognized timestamp \(raw)"
                )
            }
            return date
        }
        var usage = try decoder.decode(PlanUsage.self, from: data)
        usage.fetchedAt = Date()
        return usage
    }

    /// Handles the API's 6-digit fractional seconds, which ISO8601DateFormatter rejects.
    static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        if let d = fractional.date(from: raw) ?? plain.date(from: raw) { return d }

        // Truncate sub-second precision to three digits and retry.
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            let rest = tail.dropFirst(digits.count)
            let trimmed = raw[..<dot] + "." + digits.prefix(3) + rest
            return fractional.date(from: String(trimmed)) ?? plain.date(from: String(trimmed))
        }
        return nil
    }
}
