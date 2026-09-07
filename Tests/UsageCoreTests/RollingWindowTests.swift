import Foundation
import SQLite3
import Testing
@testable import UsageCore

@Test("Last 24 hours and Today have different starts, including across DST")
func rollingHoursVersusToday() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    for components in [
        DateComponents(year: 2026, month: 9, day: 7, hour: 14, minute: 30),
        DateComponents(year: 2026, month: 3, day: 8, hour: 14, minute: 30),
        DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 30),
    ] {
        let now = try #require(calendar.date(from: components))
        let rolling = try #require(UsageDateRange.lastHours(24).interval(now: now, calendar: calendar))
        let today = try #require(UsageDateRange.currentDay.interval(now: now, calendar: calendar))
        #expect(rolling.duration == 86_400)
        #expect(rolling.end == now)
        #expect(today.start == calendar.startOfDay(for: now))
        #expect(rolling.start < today.start)
        #expect(UsageDateRange.lastDays(7).interval(now: now, calendar: calendar)?.duration == 604_800)
        #expect(UsageDateRange.lastDays(30).interval(now: now, calendar: calendar)?.duration == 2_592_000)
    }
    #expect(UsageDateRange.lastHours(24).movesWithTime)
    #expect(UsageDateRange.currentDay.movesWithTime)
    #expect(!UsageDateRange.allTime.movesWithTime)
    #expect(!UsageDateRange.custom(start: Date(), end: Date()).movesWithTime)
}

@Test("Indexed rolling windows use half-open instants in event and compact storage")
func exactRollingIndexBoundaries() throws {
    for compact in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(DateParsing.parse("2026-09-07T18:30:00Z"))
        let start = now.addingTimeInterval(-86_400)
        let today = UsageDateRange.gregorianCurrent.startOfDay(for: now)
        let times = [start.addingTimeInterval(-1), start, start.addingTimeInterval(1),
                     today.addingTimeInterval(1), now.addingTimeInterval(-1), now, now.addingTimeInterval(1)]
        try writeRollingTranscript(root: root, name: "boundary", times: times)
        let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
        let database = root.appendingPathComponent("index.sqlite")
        let store = try SQLiteIndexStore(url: database)
        if compact {
            try rollingSQL(database, "INSERT INTO source_config VALUES ('\(source.id)', 'rollup')")
        }
        let refresh = store.refresh(sources: [source])
        #expect(refresh.warnings.isEmpty)
        #expect(store.events().map(\.timestamp).sorted() == times.sorted())
        let query = UsageIndexQuery(range: .lastHours(24), now: now, sourceIDs: [source.id])
        #expect(query.start == start)
        #expect(query.end == now)
        let total = store.compactSummary(from: query.start, to: query.end, sourceIDs: query.sourceIDs)
        let detailed = store.summary(from: query.start, to: query.end, sourceIDs: query.sourceIDs)
        #expect(total.eventCount == 4)
        #expect(total.usage.inputTokens == 4)
        #expect(total.usage == detailed.usage)
        #expect(total.apiUSD == detailed.apiUSD)
        #expect(!total.isProvisional)
        let scanned = UsageScanner.scan(source: source, interval: DateInterval(start: start, end: now))
        #expect(scanned.events.count == 4)
        #expect(UsageAggregator.summarize(scanned.events).usage == total.usage)
        let todayQuery = UsageIndexQuery(range: .currentDay, now: now, sourceIDs: [source.id])
        #expect(todayQuery.start == today)
        #expect(todayQuery.end == now)
        #expect(store.compactSummary(from: todayQuery.start, to: todayQuery.end).eventCount == 2)
        #expect(store.refresh(sources: [source]).changedFiles == 0)
        // The start-boundary event expires without any source write or rescan.
        let later = UsageIndexQuery(range: .lastHours(24), now: now.addingTimeInterval(0.5))
        let laterTotal = store.compactSummary(from: later.start, to: later.end)
        #expect(laterTotal.eventCount == 4) // One expired; the event at the old end enters.
        let expired = UsageIndexQuery(range: .lastHours(24), now: now.addingTimeInterval(2 * 86_400))
        #expect(store.compactSummary(from: expired.start, to: expired.end).eventCount == 0)
    }
}

@Test("Legacy daily rows replay once without clearing valid cached totals")
func legacyRollingTimestampMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = try #require(DateParsing.parse("2026-09-07T18:30:00Z"))
    let start = now.addingTimeInterval(-86_400)
    try writeRollingTranscript(root: root, name: "legacy", times: [start.addingTimeInterval(-1), start, now.addingTimeInterval(-1)])
    try writeRollingTranscript(root: root, name: "unaffected", times: [now.addingTimeInterval(-2)])
    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let database = root.appendingPathComponent("index.sqlite")
    do {
        let store = try SQLiteIndexStore(url: database)
        #expect(store.refresh(sources: [source]).changedFiles == 2)
    }
    // Generation 7 day rows remain visible until the file replacement commits.
    try rollingSQL(database, """
        UPDATE events SET id = 'rollup:' || id, timestamp = \(UsageDateRange.gregorianCurrent.startOfDay(for: start).timeIntervalSince1970)
        WHERE source_path LIKE '%/legacy.jsonl';
        UPDATE source_config SET storage_mode = 'rollup';
        PRAGMA user_version = 7;
        """)
    let migrated = try SQLiteIndexStore(url: database)
    #expect(migrated.compactSummary().eventCount == 4)
    #expect(!migrated.compactSummary().isProvisional)
    #expect(migrated.compactSummary(from: start, to: now).isProvisional)
    let refresh = migrated.refresh(sources: [source])
    #expect(refresh.changedFiles == 1)
    #expect(refresh.warnings.isEmpty)
    let exact = migrated.compactSummary(from: start, to: now)
    #expect(exact.eventCount == 3)
    #expect(!exact.isProvisional)
    #expect(migrated.compactSummary().eventCount == 4)
    #expect(migrated.refresh(sources: [source]).changedFiles == 0)
}

@Test("Claude scans and indexed queries agree at exact rolling boundaries")
func claudeRollingBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = try #require(DateParsing.parse("2026-09-07T18:30:00Z"))
    let start = now.addingTimeInterval(-86_400)
    let times = [start.addingTimeInterval(-1), start, now.addingTimeInterval(-1), now]
    let directory = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let lines = times.enumerated().map { index, time in
        """
        {"timestamp":"\(formatter.string(from: time))","type":"assistant","sessionId":"demo","message":{"id":"m\(index)","model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":0}}}
        """
    }
    try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "Claude", provider: .claude, rootPath: root.path)
    let scan = UsageScanner.scan(source: source, interval: DateInterval(start: start, end: now))
    #expect(scan.events.count == 2)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    #expect(store.refresh(sources: [source]).warnings.isEmpty)
    let total = store.compactSummary(from: start, to: now)
    #expect(total.eventCount == 2)
    #expect(total.usage == UsageAggregator.summarize(scan.events).usage)
}

private func writeRollingTranscript(root: URL, name: String, times: [Date]) throws {
    let directory = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let lines = times.enumerated().map { index, time in
        """
        {"timestamp":"\(formatter.string(from: time))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(index + 1),"cached_input_tokens":0,"output_tokens":0}}}}
        """
    }
    let header = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4\"}}\n"
    try (header + lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
}

private func rollingSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
}
