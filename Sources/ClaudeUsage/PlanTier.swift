import Foundation

/// Reads the subscription tier Claude Code recorded locally, for the panel's subtitle.
enum PlanTier {
    static func current() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        if let tier = account["organizationRateLimitTier"] as? String {
            return pretty(tier)
        }
        if let type = account["organizationType"] as? String {
            return pretty(type)
        }
        return nil
    }

    /// "default_claude_max_5x" -> "Max (5x)"
    private static func pretty(_ raw: String) -> String {
        var s = raw
        for prefix in ["default_", "claude_"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        s = s.replacingOccurrences(of: "claude_", with: "")
        let parts = s.split(separator: "_").map(String.init)
        guard let first = parts.first else { return raw }
        let name = first.prefix(1).uppercased() + first.dropFirst()
        if let multiplier = parts.dropFirst().first, multiplier.hasSuffix("x") {
            return "\(name) (\(multiplier))"
        }
        return name
    }
}
