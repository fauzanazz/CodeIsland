import Foundation

/// Token / cost / work-time aggregation over the local Oh My Pi / OMP session
/// transcripts (~/.omp/agent/sessions/<project>/*.jsonl) — local-first, no
/// provider API calls. Each assistant `message` line carries `message.usage`
/// (per-turn) with a nested `cost` object and a top-level `id` (dedupe key) and
/// `timestamp`.
///
/// Focused on **today** (since local midnight): billed tokens, summed cost,
/// request count (assistant turns), and an estimated active work duration.
public enum OmpUsageScanner {
    /// Idle gap (seconds) above which two consecutive turns are treated as a
    /// break rather than continuous work — WakaTime-style active-time heuristic.
    static let idleThresholdSeconds: Double = 300

    public struct Snapshot: Equatable, Sendable {
        /// Today's totals (tokens, cost, and `messageCount` = requests).
        public let today: ClaudeUsageTotals
        /// Output tokens per hour for the trailing 12 hours (oldest first).
        public let hourlyOutputTokens: [Int]
        /// Estimated active working seconds today (union of activity across all
        /// sessions, idle gaps > `idleThresholdSeconds` excluded).
        public let workSecondsToday: Int
        public let scannedAt: Date

        public init(today: ClaudeUsageTotals, hourlyOutputTokens: [Int], workSecondsToday: Int, scannedAt: Date) {
            self.today = today
            self.hourlyOutputTokens = hourlyOutputTokens
            self.workSecondsToday = workSecondsToday
            self.scannedAt = scannedAt
        }

        public static let empty = Snapshot(
            today: ClaudeUsageTotals(),
            hourlyOutputTokens: [Int](repeating: 0, count: ClaudeUsageScanner.sparklineHours),
            workSecondsToday: 0,
            scannedAt: .distantPast
        )
    }

    /// Per-file incremental parse state — transcripts are append-only, so each
    /// rescan reads only the bytes past `consumedBytes`.
    public struct FileCache: Sendable {
        struct CachedMessage: Sendable, Equatable {
            let timestamp: Date
            let usage: ClaudeUsageTotals
        }
        struct FileEntry: Sendable {
            var consumedBytes: UInt64 = 0
            var entries: [CachedMessage] = []
            var seenIds: Set<String> = []
        }
        var files: [String: FileEntry] = [:]
        public init() {}
    }

    /// One-shot convenience (tests, callers without persistent state).
    public static func scan(
        ompHome: String = NSHomeDirectory() + "/.omp/agent",
        now: Date = Date()
    ) -> Snapshot {
        var cache = FileCache()
        return scan(ompHome: ompHome, now: now, cache: &cache)
    }

    public static func scan(
        ompHome: String = NSHomeDirectory() + "/.omp/agent",
        now: Date = Date(),
        cache: inout FileCache
    ) -> Snapshot {
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(ClaudeUsageScanner.sparklineHours) * 3600)
        let cutoff = min(midnight, sparklineStart)

        var today = ClaudeUsageTotals()
        var hourly = [Int](repeating: 0, count: ClaudeUsageScanner.sparklineHours)
        var todayTimestamps: [Date] = []
        var activeFiles = Set<String>()

        let fm = FileManager.default
        let sessionsDir = ompHome + "/sessions"
        for project in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
            let projectPath = sessionsDir + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            for file in (try? fm.contentsOfDirectory(atPath: projectPath)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = projectPath + "/" + file
                // mtime gate: untouched-since-cutoff transcripts can't contain
                // in-window lines, so the scan stays cheap on big histories.
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= cutoff else { continue }
                activeFiles.insert(path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                var entry = cache.files[path] ?? FileCache.FileEntry()
                if size < entry.consumedBytes {
                    entry = FileCache.FileEntry()
                }
                if size > entry.consumedBytes {
                    consumeNewLines(path: path, into: &entry)
                }
                entry.entries.removeAll { $0.timestamp < cutoff }
                cache.files[path] = entry

                for message in entry.entries where message.timestamp <= now {
                    if message.timestamp >= midnight {
                        today.add(message.usage)
                        todayTimestamps.append(message.timestamp)
                    }
                    let hoursAgo = Int(now.timeIntervalSince(message.timestamp) / 3600)
                    if hoursAgo >= 0 && hoursAgo < ClaudeUsageScanner.sparklineHours {
                        hourly[ClaudeUsageScanner.sparklineHours - 1 - hoursAgo] += message.usage.outputTokens
                    }
                }
            }
        }
        cache.files = cache.files.filter { activeFiles.contains($0.key) }
        return Snapshot(
            today: today,
            hourlyOutputTokens: hourly,
            workSecondsToday: activeSeconds(todayTimestamps),
            scannedAt: now
        )
    }

    /// Active working time from a set of activity timestamps: sort them onto one
    /// timeline (union across sessions, so parallel work isn't double-counted)
    /// and sum consecutive gaps that stay under the idle threshold.
    static func activeSeconds(_ timestamps: [Date]) -> Int {
        guard timestamps.count > 1 else { return 0 }
        let sorted = timestamps.sorted()
        var total = 0.0
        for i in 1..<sorted.count {
            let gap = sorted[i].timeIntervalSince(sorted[i - 1])
            if gap > 0 && gap <= idleThresholdSeconds { total += gap }
        }
        return Int(total)
    }

    /// Read bytes past `entry.consumedBytes` and parse COMPLETE lines only — a
    /// partial trailing line (writer mid-append) is left for the next scan.
    private static func consumeNewLines(path: String, into entry: inout FileCache.FileEntry) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: entry.consumedBytes)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let consumable = data[data.startIndex...lastNewline]
        entry.consumedBytes += UInt64(consumable.count)
        guard let text = String(data: consumable, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            guard let parsed = parseAssistantUsage(String(line)),
                  !entry.seenIds.contains(parsed.messageId) else { continue }
            entry.seenIds.insert(parsed.messageId)
            entry.entries.append(.init(timestamp: parsed.timestamp, usage: parsed.usage))
        }
    }

    /// Parse one transcript line into (timestamp, id, usage) — nil for
    /// non-assistant lines and lines without usage.
    static func parseAssistantUsage(_ line: String) -> (timestamp: Date, messageId: String, usage: ClaudeUsageTotals)? {
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "message",
              let timestampRaw = obj["timestamp"] as? String,
              let timestamp = ClaudeUsageScanner.parseISO8601(timestampRaw),
              let message = obj["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let messageId = (obj["id"] as? String)
            ?? (message["responseId"] as? String)
            ?? timestampRaw
        var totals = ClaudeUsageTotals()
        totals.inputTokens = intFromJSON(usage["input"]) ?? 0
        totals.outputTokens = intFromJSON(usage["output"]) ?? 0
        totals.cacheCreationTokens = intFromJSON(usage["cacheWrite"]) ?? 0
        totals.cacheReadTokens = intFromJSON(usage["cacheRead"]) ?? 0
        // OMP records per-turn cost as a nested object { input, output, …, total }.
        if let costObj = usage["cost"] as? [String: Any] {
            totals.cost = doubleFromJSON(costObj["total"]) ?? 0
        } else {
            totals.cost = doubleFromJSON(usage["cost"]) ?? 0
        }
        totals.messageCount = 1
        return (timestamp, messageId, totals)
    }
}
