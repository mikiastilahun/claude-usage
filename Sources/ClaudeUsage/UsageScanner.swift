import Foundation

/// Reads Claude Code's local JSONL transcripts and turns them into `UsageEntry` values.
///
/// Scanning is incremental: each file's byte offset is remembered, so a refresh only
/// parses lines appended since the last pass. Entries are deduplicated across files
/// because resuming a session replays earlier messages into a new transcript.
actor UsageScanner {
    static let projectsDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private var offsets: [String: UInt64] = [:]
    private var seen: Set<String> = []
    private var entries: [UsageEntry] = []

    private let tokenNeedle = Data("\"input_tokens\"".utf8)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses anything new and returns the full entry set, sorted by time.
    func refresh() -> [UsageEntry] {
        let files = transcriptFiles()

        // A shrunken file means it was rewritten or rotated; rebuild from scratch.
        for url in files {
            let size = fileSize(url)
            if let known = offsets[url.path], size < known {
                offsets.removeAll()
                seen.removeAll()
                entries.removeAll()
                break
            }
        }

        for url in files {
            scan(url)
        }

        entries.sort { $0.timestamp < $1.timestamp }
        return entries
    }

    private func transcriptFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: Self.projectsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func scan(_ url: URL) {
        let offset = offsets[url.path] ?? 0
        guard fileSize(url) > offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Stop at the last complete line so a half-written tail is re-read next pass.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[url.path] = offset + UInt64(complete.count)

        let fallbackProject = projectName(fromDirectory: url.deletingLastPathComponent().lastPathComponent)

        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count > 2, line.range(of: tokenNeedle) != nil else { continue }
            if let entry = parse(Data(line), fallbackProject: fallbackProject) {
                entries.append(entry)
            }
        }
    }

    private func parse(_ line: Data, fallbackProject: String) -> UsageEntry? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              model != "<synthetic>"
        else { return nil }

        // Resumed sessions duplicate prior messages into the new transcript.
        let key = [message["id"] as? String, root["requestId"] as? String]
            .compactMap { $0 }
            .joined(separator: ":")
        let dedupeKey = key.isEmpty ? (root["uuid"] as? String ?? UUID().uuidString) : key
        guard seen.insert(dedupeKey).inserted else { return nil }

        guard let stamp = root["timestamp"] as? String,
              let date = Self.isoFractional.date(from: stamp) ?? Self.isoPlain.date(from: stamp)
        else { return nil }

        let int = { (key: String) -> Int in (usage[key] as? NSNumber)?.intValue ?? 0 }

        // Prefer the per-TTL split; fall back to the aggregate when it is absent.
        let creation = usage["cache_creation"] as? [String: Any]
        let split1h = (creation?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue
        let split5m = (creation?["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue
        let totalWrite = int("cache_creation_input_tokens")
        let write1h: Int
        let write5m: Int
        if let a = split1h, let b = split5m, a + b > 0 {
            write1h = a
            write5m = b
        } else {
            write1h = 0
            write5m = totalWrite
        }

        let project: String
        if let cwd = root["cwd"] as? String, !cwd.isEmpty {
            project = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            project = fallbackProject
        }

        return UsageEntry(
            timestamp: date,
            model: model,
            project: project,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheRead: int("cache_read_input_tokens"),
            cacheWrite5m: write5m,
            cacheWrite1h: write1h
        )
    }

    /// "-Users-me-prod-thing" -> "thing"
    private func projectName(fromDirectory dir: String) -> String {
        dir.split(separator: "-").last.map(String.init) ?? dir
    }
}
