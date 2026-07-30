import XCTest
@testable import CodeIslandCore

final class OmpUsageScannerTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "omp-usage-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/sessions/-Project-p1", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Matches OMP's real transcript shape: top-level `id` + `timestamp`, and
    /// `message.usage` with `input`/`output`/`cacheWrite`/`cacheRead` + nested `cost`.
    private func assistantLine(id: String, at date: Date, input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0, cost: Double = 0) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"\(iso(date))","message":{"role":"assistant","usage":{"input":\(input),"output":\(output),"cacheWrite":\(cacheWrite),"cacheRead":\(cacheRead),"totalTokens":\(input + output + cacheWrite + cacheRead),"cost":{"total":\(cost)}}}}
        """
    }

    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func write(_ lines: [String], file: String = "s.jsonl") throws {
        try lines.joined(separator: "\n")
            .write(toFile: home + "/sessions/-Project-p1/" + file, atomically: true, encoding: .utf8)
    }

    func testParseAssistantUsageLine() {
        let parsed = OmpUsageScanner.parseAssistantUsage(
            assistantLine(id: "m1", at: noon, input: 10, output: 20, cacheWrite: 5, cacheRead: 100, cost: 0.42))
        XCTAssertEqual(parsed?.messageId, "m1")
        XCTAssertEqual(parsed?.usage.inputTokens, 10)
        XCTAssertEqual(parsed?.usage.outputTokens, 20)
        // OMP's cacheWrite maps to the snapshot's cacheCreationTokens.
        XCTAssertEqual(parsed?.usage.cacheCreationTokens, 5)
        XCTAssertEqual(parsed?.usage.cacheReadTokens, 100)
        XCTAssertEqual(parsed?.usage.cost ?? 0, 0.42, accuracy: 1e-9)

        XCTAssertNil(OmpUsageScanner.parseAssistantUsage(#"{"type":"message","id":"u","timestamp":"2026-07-10T01:00:00.000Z","message":{"role":"user","content":"hi"}}"#))
        XCTAssertNil(OmpUsageScanner.parseAssistantUsage("not json"))
    }

    func testScanAggregatesTodayCostAndRequestsAndDedupes() throws {
        let now = noon
        try write([
            assistantLine(id: "a", at: now.addingTimeInterval(-3600), input: 100, output: 10, cost: 0.10),
            // Duplicate top-level id — counted once.
            assistantLine(id: "a", at: now.addingTimeInterval(-3600), input: 100, output: 10, cost: 0.10),
            // Earlier today (04:00 local).
            assistantLine(id: "b", at: now.addingTimeInterval(-8 * 3600), input: 1000, output: 50, cost: 0.90),
            // Yesterday — excluded from "today".
            assistantLine(id: "c", at: now.addingTimeInterval(-30 * 3600), input: 7777, output: 999, cost: 9.99),
        ])

        let snap = OmpUsageScanner.scan(ompHome: home, now: now)

        XCTAssertEqual(snap.today.inputTokens, 1100)
        XCTAssertEqual(snap.today.outputTokens, 60)
        XCTAssertEqual(snap.today.messageCount, 2)  // requests today, deduped
        XCTAssertEqual(snap.today.cost, 1.0, accuracy: 1e-9)  // 0.10 + 0.90

        // Sparkline: 1h-ago output lands in the last bucket.
        let last = ClaudeUsageScanner.sparklineHours - 1
        XCTAssertEqual(snap.hourlyOutputTokens[last - 1], 10)
    }

    func testWorkTimeSumsGapsUnderIdleThreshold() throws {
        let now = noon
        // Three turns 2 minutes apart (active), then a 30-minute break, then one more.
        try write([
            assistantLine(id: "w1", at: now.addingTimeInterval(-40 * 60), input: 1, output: 1),
            assistantLine(id: "w2", at: now.addingTimeInterval(-38 * 60), input: 1, output: 1),
            assistantLine(id: "w3", at: now.addingTimeInterval(-36 * 60), input: 1, output: 1),
            // 30-min gap (> 5-min idle threshold) — not counted.
            assistantLine(id: "w4", at: now.addingTimeInterval(-6 * 60), input: 1, output: 1),
        ])

        let snap = OmpUsageScanner.scan(ompHome: home, now: now)
        // Two 2-min active gaps counted; the 30-min break and the trailing lone
        // event add nothing.
        XCTAssertEqual(snap.workSecondsToday, 4 * 60)
    }

    func testActiveSecondsUnionsParallelSessions() {
        let base = Date()
        // Two "sessions" interleaved a minute apart — union timeline, no double count.
        let ts = [0, 60, 120, 180].map { base.addingTimeInterval(Double($0)) }
        XCTAssertEqual(OmpUsageScanner.activeSeconds(ts), 180)
        XCTAssertEqual(OmpUsageScanner.activeSeconds([base]), 0)
    }

    func testScanEmptyHome() {
        let snap = OmpUsageScanner.scan(ompHome: home, now: noon)
        XCTAssertTrue(snap.today.isEmpty)
        XCTAssertEqual(snap.workSecondsToday, 0)
    }
}
