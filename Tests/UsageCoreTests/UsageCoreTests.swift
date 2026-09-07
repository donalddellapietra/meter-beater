import Foundation
import Testing
import SQLite3
@testable import UsageCore

@Test("Compact rollups aggregate records without changing stable identities")
func compactRollupsAggregateRecords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 9)))
    let second = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 18)))
    let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 9)))
    var rollups = EventRollupAccumulator(calendar: calendar)

    func event(id: String, timestamp: Date, count: Int, input: Int64, output: Int64) -> UsageEvent {
        UsageEvent(
            id: id,
            provider: .codex,
            sourceID: "codex:/tmp/demo",
            accountID: "unattributed",
            sessionID: "session-1",
            timestamp: timestamp,
            model: "gpt-5",
            sourcePath: "/tmp/demo/session.jsonl",
            eventCount: count,
            usage: TokenUsage(inputTokens: input, outputTokens: output)
        )
    }

    rollups.append(event(id: "one", timestamp: first, count: 2, input: 3, output: 5))
    rollups.append(event(id: "two", timestamp: second, count: 4, input: 7, output: 11))
    rollups.append(event(id: "three", timestamp: nextDay, count: 1, input: 13, output: 17))

    let values = rollups.values
    #expect(values.count == 2)
    #expect(values[0].eventCount == 6)
    #expect(values[0].usage.inputTokens == 10)
    #expect(values[0].usage.outputTokens == 16)
    #expect(values[1].eventCount == 1)
    #expect(values.allSatisfy { $0.id.hasPrefix("rollup:") })

    var replay = EventRollupAccumulator(calendar: calendar)
    replay.append(event(id: "replacement-id", timestamp: first, count: 6, input: 10, output: 16))
    #expect(replay.values[0].id == values[0].id)
}

@Test("Overview queries publish totals without materializing dashboard details")
func overviewDefersBreakdowns() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":3,"output_tokens":7}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])

    let overview = store.overview(sourceIDs: Set([source.id]))
    #expect(overview.eventCount == 1)
    #expect(overview.sessionCount == 1)
    #expect(overview.usage.inputTokens == 3)
    #expect(overview.usage.outputTokens == 7)
    #expect(overview.models.isEmpty)
    #expect(overview.accounts.isEmpty)
    #expect(overview.days.isEmpty)
    #expect(overview.subagents.isEmpty)
    #expect(overview.apiUSD == 0)

    let details = store.summary(sourceIDs: Set([source.id]))
    #expect(details.models.count == 1)
    #expect(details.accounts.count == 1)
    #expect(details.days.count == 1)
    #expect(details.apiUSD > 0)
}

@Test("Windowed scanner preserves usage after an oversized JSONL line")
func windowedScannerPreservesUsageAfterOversizedLine() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/oversized.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    let megabyte = Data(repeating: 0x78, count: 1024 * 1024)
    for _ in 0..<33 { try handle.write(contentsOf: megabyte) }
    try handle.write(contentsOf: Data([0x0A]))
    let usageLine = #"{"type":"assistant","sessionId":"large","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"after-large-line","model":"claude-opus-5","usage":{"input_tokens":3,"output_tokens":7}}}"#
    try handle.write(contentsOf: Data((usageLine + "\n").utf8))
    try handle.close()

    let source = UsageSource(displayName: "windowed", provider: .claude, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let refresh = store.refresh(sources: [source])
    let summary = store.summary(sourceIDs: Set([source.id]))
    #expect(refresh.warnings.isEmpty)
    #expect(summary.eventCount == 1)
    #expect(summary.usage.inputTokens == 3)
    #expect(summary.usage.outputTokens == 7)
}

@Test("Compact menu summary matches priced totals without dashboard collections")
func compactMenuSummaryMatchesFullSummary() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = [
        #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":300,"cache_read_input_tokens":40,"output_tokens":70}}}"#,
        #"{"type":"assistant","sessionId":"s2","timestamp":"2026-08-02T12:00:00.000Z","message":{"id":"m2","model":"claude-haiku-4-5","usage":{"input_tokens":30,"output_tokens":7}}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])

    let compact = store.compactSummary(sourceIDs: Set([source.id]))
    let full = store.summary(sourceIDs: Set([source.id]))
    #expect(compact.usage == full.usage)
    #expect(compact.eventCount == full.eventCount)
    #expect(abs(compact.apiUSD - full.apiUSD) < 0.000_001)
    #expect(compact.unpricedEventCount == full.unpricedEventCount)
    #expect(compact.accounts.count == 1)
    #expect(compact.accounts[0].provider == .claude)
    #expect(compact.accounts[0].usage == compact.usage)
    let compactCosts = try #require(compact.accounts[0].apiCostBreakdown)
    let fullCosts = try #require(full.accounts[0].apiCostBreakdown)
    #expect(abs(compactCosts.uncachedInputUSD - 0.00153) < 0.000_000_001)
    #expect(abs(compactCosts.cachedInputUSD - 0.00002) < 0.000_000_001)
    #expect(abs(compactCosts.outputUSD - 0.001785) < 0.000_000_001)
    #expect(abs(compactCosts.totalUSD - compact.accounts[0].apiUSD) < 0.000_000_001)
    #expect(abs(compactCosts.totalUSD - fullCosts.totalUSD) < 0.000_000_001)
    #expect(compact.models.isEmpty)
    #expect(compact.days.isEmpty)
    #expect(compact.subagents.isEmpty)
}

@Test("Dashboard summaries bound subagent materialization in SQLite")
func dashboardSummaryLimitsSubagents() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("projects/demo/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 1...5 {
        let file = directory.appendingPathComponent("agent-\(index).jsonl")
        let line = """
            {"type":"assistant","sessionId":"parent","agentId":"agent-\(index)","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m\(index)","model":"claude-opus-5","usage":{"input_tokens":\(index * 10),"output_tokens":1}}}
            """
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])

    #expect(store.summary(sourceIDs: Set([source.id])).subagents.count == 5)
    let limited = store.summary(sourceIDs: Set([source.id]), maxSubagents: 2).subagents
    #expect(limited.count == 2)
    #expect(Set(limited.map(\.sessionID)) == Set(["agent:agent-4", "agent:agent-5"]))
}

@Test("Claude streaming fragments are deduplicated")
func claudeStreamingDeduplication() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line1 = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":12,"ephemeral_1h_input_tokens":8},"output_tokens":5}}}"#
    let line2 = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:01.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":12,"ephemeral_1h_input_tokens":8},"output_tokens":5}}}"#
    let line3 = #"{"type":"assistant","sessionId":"s1","agentId":"a1","timestamp":"2026-08-01T12:00:02.000Z","isSidechain":true,"message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":2}}}"#
    let line4 = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:03.000Z","isSidechain":true,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":6}}}"#
    try (line1 + "\n" + line2 + "\n" + line3 + "\n" + line4 + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .claude, rootPath: root.path))
    #expect(result.events.count == 3)
    #expect(result.events.map(\.usage.outputTokens).reduce(0, +) == 13)
    #expect(result.events.first(where: { $0.sessionID == "agent:a1" && $0.usage.outputTokens == 2 })?.parentSessionID == "s1")
    #expect(result.events.contains { $0.sessionID == "s1" && $0.isSubagent && $0.usage.outputTokens == 6 })
    #expect(result.events.first(where: { $0.usage.outputTokens == 5 })?.attributionConfidence == .sourceOnly)
    #expect(result.events.first(where: { $0.usage.outputTokens == 6 })?.attributionConfidence == .ambiguousSidechain)
    #expect(result.events.first(where: { $0.usage.outputTokens == 2 })?.attributionConfidence == .parentSession)
    let aggregated = UsageAggregator.summarize(result.events)
    #expect(aggregated.subagents.count == 2)
    #expect(aggregated.subagents.map(\.usage.outputTokens).reduce(0, +) == 8)
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = db.refresh(sources: [source])
    let indexed = db.summary(sourceIDs: Set([source.id]))
    #expect(indexed.subagents.count == 2)
    #expect(indexed.subagents.first(where: { $0.sessionID == "agent:a1" })?.parentSessionID == "s1")
    #expect(indexed.subagents.map(\.usage.outputTokens).reduce(0, +) == 8)
}

@Test("Claude resumed histories count provider messages once across files")
func claudeCopiedHistoryDeduplication() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects/demo", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let predecessor = projects.appendingPathComponent("predecessor.jsonl")
    let resumed = projects.appendingPathComponent("resumed.jsonl")
    let sharedOld = #"{"type":"assistant","sessionId":"older-session","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"msg-shared","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"output_tokens":5}}}"#
    let sharedCopy = #"{"type":"assistant","sessionId":"resumed-session","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"msg-shared","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"output_tokens":5}}}"#
    let unique = #"{"type":"assistant","sessionId":"resumed-session","timestamp":"2026-08-01T12:01:00.000Z","message":{"id":"msg-new","model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":6}}}"#
    let synthetic = #"{"type":"assistant","sessionId":"resumed-session","timestamp":"2026-08-01T12:02:00.000Z","message":{"id":"msg-synthetic","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
    try (sharedOld + "\n").write(to: predecessor, atomically: true, encoding: .utf8)
    try (sharedCopy + "\n" + unique + "\n" + synthetic + "\n").write(to: resumed, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "Claude", provider: .claude, rootPath: root.path)
    let direct = UsageScanner.scan(source: source)
    #expect(direct.events.count == 2)
    #expect(Set(direct.events.compactMap(\.providerEventID)) == Set(["msg-shared", "msg-new"]))

    let databaseURL = root.appendingPathComponent("index.sqlite")
    let store = try SQLiteIndexStore(url: databaseURL)
    #expect(store.refresh(sources: [source]).changedFiles == 2)
    #expect(store.events(sourceIDs: Set([source.id])).count == 3)
    var summary = store.summary(sourceIDs: Set([source.id]))
    #expect(summary.eventCount == 2)
    #expect(summary.sessionCount == 2)
    #expect(summary.usage == TokenUsage(inputTokens: 14, cachedInputTokens: 100, outputTokens: 11))
    #expect(summary.unpricedEventCount == 0)

    // Simulate a pre-provider-ID cache mode. The corrective migration must be
    // source-local, atomic, and independent of file modification timestamps.
    var raw: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let raw else {
        throw NSError(domain: "AIUsageTrackerTests", code: 31)
    }
    guard sqlite3_exec(raw, "UPDATE source_config SET storage_mode = 'events'", nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(raw)
        throw NSError(domain: "AIUsageTrackerTests", code: 32)
    }
    sqlite3_close(raw)
    let migrated = store.refresh(sources: [source])
    #expect(migrated.changedFiles == 2)
    #expect(migrated.failedFiles == 0)
    #expect(store.summary(sourceIDs: Set([source.id])).usage == summary.usage)

    try FileManager.default.removeItem(at: predecessor)
    let removed = store.refresh(sources: [source])
    #expect(removed.removedFiles == 1)
    #expect(store.events(sourceIDs: Set([source.id])).count == 2)
    summary = store.summary(sourceIDs: Set([source.id]))
    #expect(summary.eventCount == 2)
    #expect(summary.usage == TokenUsage(inputTokens: 14, cachedInputTokens: 100, outputTokens: 11))
}

@Test("Claude telemetry provides session-verified attribution")
func claudeTelemetryAttribution() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    let telemetry = root.appendingPathComponent("telemetry/events/usage.json")
    let conflictA = root.appendingPathComponent("telemetry/conflicts/a.json")
    let conflictB = root.appendingPathComponent("telemetry/conflicts/b.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: telemetry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: conflictA.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"verified-session","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    try #"{"event_data":{"session_id":"verified-session","auth":{"account_uuid":"acct-telemetry"}}}"#.write(to: telemetry, atomically: true, encoding: .utf8)
    try #"{"event_data":{"session_id":"verified-session","auth":{"account_uuid":"acct-b"}}}"#.write(to: conflictB, atomically: true, encoding: .utf8)
    try #"{"event_data":{"session_id":"verified-session","auth":{"account_uuid":"acct-a"}}}"#.write(to: conflictA, atomically: true, encoding: .utf8)
    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .claude, rootPath: root.path))
    #expect(result.events.count == 1)
    #expect(result.events.first?.accountID == "ambiguous")
    #expect(result.events.first?.attributionConfidence == .ambiguousAccount)
    #expect(result.events.first?.attributionBasis == .claudeAccountConflict)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    let summary = db.summary(sourceIDs: Set([source.id]))
    #expect(summary.attributionCounts[AttributionConfidence.ambiguousAccount.rawValue] == 1)
    #expect(summary.accounts.first?.accountID == "ambiguous")
    #expect(summary.accounts.first?.attributionConfidence == .ambiguousAccount)
}

@Test("Codex cumulative token snapshots become deltas without reading credentials")
func codexCumulativeDeltas() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/08/01"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-test.jsonl")
    let a = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4}}}}"#
    let b = #"{"timestamp":"2026-08-01T12:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":120,"output_tokens":15,"reasoning_output_tokens":6}}}}"#
    let c = #"{"timestamp":"2026-08-01T12:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":120,"output_tokens":15,"reasoning_output_tokens":9}}}}"#
    try (a + "\n" + b + "\n" + c + "\n").write(to: file, atomically: true, encoding: .utf8)
    try #"{"tokens":{"account_id":"must-not-be-read"}}"#.write(to: root.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .codex, rootPath: root.path))
    #expect(result.events.count == 3)
    #expect(result.events.map(\.usage.inputTokens).reduce(0, +) == 30)
    #expect(result.events.map(\.usage.cachedInputTokens).reduce(0, +) == 120)
    #expect(result.events.map(\.usage.outputTokens).reduce(0, +) == 15)
    #expect(result.events.map(\.usage.reasoningOutputTokens).reduce(0, +) == 9)
    #expect(result.events.allSatisfy { $0.accountID == "unattributed" && $0.currentAuthAccountID == nil && $0.attributionConfidence == .sourceOnly && $0.attributionBasis == .none })
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = db.refresh(sources: [UsageSource(displayName: "test", provider: .codex, rootPath: root.path)])
    #expect(db.events().allSatisfy { $0.currentAuthAccountID == nil })
    #expect(db.summary().accounts.first?.currentAuthAccountID == nil)
}

@Test("Codex stale and out-of-order snapshots never become billable usage")
func codexStaleSnapshotsAreDiscarded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/08/01"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-stale.jsonl")
    let first = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}}}"#
    let lower = #"{"timestamp":"2026-08-01T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":60,"output_tokens":8}}}}"#
    let forward = #"{"timestamp":"2026-08-01T12:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":90,"output_tokens":12}}}}"#
    try (first + "\n" + lower + "\n" + forward + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .codex, rootPath: root.path))
    #expect(result.events.count == 2)
    #expect(result.events.map(\.usage.inputTokens).reduce(0, +) == 30)
    #expect(result.events.map(\.usage.cachedInputTokens).reduce(0, +) == 90)
    #expect(result.events.map(\.usage.outputTokens).reduce(0, +) == 12)
    #expect(result.accounting.staleSnapshots == 1)
    #expect(result.accounting.ambiguousResets == 0)
}

@Test("Codex counter decreases remain unresolved when the file never recovers")
func codexTerminalCounterDecreaseIsUnresolved() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/08/01"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-reset.jsonl")
    let first = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}}}"#
    let lower = #"{"timestamp":"2026-08-01T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":60,"output_tokens":8}}}}"#
    try (first + "\n" + lower + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .codex, rootPath: root.path))
    #expect(result.events.count == 1)
    #expect(result.accounting.staleSnapshots == 1)
    #expect(result.accounting.ambiguousResets == 1)
    #expect(result.accounting.hasUnresolvedIssues)
}

@Test("Codex last-token usage is fenced by cumulative progress")
func codexLastUsageDeduplicatesRepeatedSnapshots() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/08/01"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-last.jsonl")
    let first = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}}}"#
    let repeated = #"{"timestamp":"2026-08-01T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5},"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}}}"#
    let next = #"{"timestamp":"2026-08-01T12:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":9},"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":4}}}}"#
    try (first + "\n" + repeated + "\n" + next + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .codex, rootPath: root.path))
    #expect(result.events.count == 2)
    #expect(result.events.map(\.usage.inputTokens).reduce(0, +) == 90)
    #expect(result.events.map(\.usage.outputTokens).reduce(0, +) == 9)
    #expect(result.accounting.duplicateSnapshots == 1)
}

@Test("Codex fork baselines are retained as diagnostics but not charged")
func codexForkBaselineIsExcluded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/08/01"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-fork.jsonl")
    let meta = #"{"timestamp":"2026-08-01T12:10:00.000Z","type":"session_meta","payload":{"id":"01986f2a-c800-7000-8000-000000000002","forked_from_id":"01986ef3-db00-7000-8000-000000000001","parent_thread_id":"parent-thread","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread"}}}}}"#
    let copiedTask = #"{"timestamp":"2026-08-01T12:10:00.001Z","type":"event_msg","payload":{"type":"task_started","turn_id":"c42af445-f69a-4785-a9c2-d5c4daba6c07","started_at":1785586200}}"#
    let inheritedA = #"{"timestamp":"2026-08-01T12:10:00.002Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100}}}}"#
    let inheritedB = #"{"timestamp":"2026-08-01T12:10:00.003Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1600,"output_tokens":200}}}}"#
    let childTask = #"{"timestamp":"2026-08-01T12:10:00.004Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01986f2a-c800-7000-8000-000000000003","started_at":1785586200}}"#
    let childA = #"{"timestamp":"2026-08-01T12:10:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2040,"cached_input_tokens":1620,"output_tokens":210},"last_token_usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10}}}}"#
    let childB = #"{"timestamp":"2026-08-01T12:10:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2060,"cached_input_tokens":1630,"output_tokens":215},"last_token_usage":{"input_tokens":20,"cached_input_tokens":10,"output_tokens":5}}}}"#
    try ([meta, copiedTask, inheritedA, inheritedB, childTask, childA, childB].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "test", provider: .codex, rootPath: root.path)
    let result = UsageScanner.scan(source: source)
    #expect(result.events.count == 2)
    #expect(result.events.map(\.usage.inputTokens).reduce(0, +) == 30)
    #expect(result.events.map(\.usage.cachedInputTokens).reduce(0, +) == 30)
    #expect(result.events.map(\.usage.outputTokens).reduce(0, +) == 15)
    #expect(result.events.allSatisfy { $0.parentSessionID == "parent-thread" && $0.isSubagent })
    #expect(result.accounting.inheritedBaselines == 1)

    let headline = CodexScanner.quickScanFile(source: source, url: file, metadata: CodexMetadata(root: root))
    #expect(headline.events.isEmpty)
    #expect(headline.accounting.inheritedBaselines == 1)

    let accurateSnapshot = CodexScanner.quickScanFile(source: source, url: file, metadata: CodexMetadata(root: root), includeInheritedUsage: true)
    #expect(accurateSnapshot.events.map(\.usage.inputTokens).reduce(0, +) == 30)
    #expect(accurateSnapshot.events.map(\.usage.cachedInputTokens).reduce(0, +) == 30)
    #expect(accurateSnapshot.events.map(\.usage.outputTokens).reduce(0, +) == 15)

    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])
    #expect(store.summary(sourceIDs: Set([source.id])).accounting?.inheritedBaselines == 1)
}

@Test("Codex user forks exclude copied history without a parent-thread marker")
func codexUserForkBaselineIsExcluded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-user-fork.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let meta = #"{"timestamp":"2026-08-01T12:10:00.000Z","type":"session_meta","payload":{"id":"01986f2a-c800-7000-8000-000000000012","forked_from_id":"01986ef3-db00-7000-8000-000000000011","source":"vscode","thread_source":"user"}}"#
    let copiedTask = #"{"timestamp":"2026-08-01T12:10:00.001Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01986ef3-db00-7000-8000-000000000099","started_at":1785585600}}"#
    let inherited = #"{"timestamp":"2026-08-01T12:10:00.002Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":500}}}}"#
    let ownTask = #"{"timestamp":"2026-08-01T12:10:00.003Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01986f2a-c800-7000-8000-000000000013","started_at":1785586200}}"#
    let ownUsage = #"{"timestamp":"2026-08-01T12:10:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5060,"cached_input_tokens":4030,"output_tokens":515},"last_token_usage":{"input_tokens":60,"cached_input_tokens":30,"output_tokens":15}}}}"#
    try ([meta, copiedTask, inherited, ownTask, ownUsage].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "test", provider: .codex, rootPath: root.path)
    let result = UsageScanner.scan(source: source)
    #expect(result.events.count == 1)
    #expect(result.events.first?.usage == TokenUsage(inputTokens: 30, cachedInputTokens: 30, outputTokens: 15))
    #expect(result.events.first?.parentSessionID == "01986ef3-db00-7000-8000-000000000011")
    #expect(result.events.first?.isSubagent == false)
    #expect(result.accounting.inheritedBaselines == 1)
}

@Test("Codex copy-only forks are excluded without a false warning")
func codexCopyOnlyForkIsExcluded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-copy-only.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let meta = #"{"timestamp":"2026-08-01T12:10:00.000Z","type":"session_meta","payload":{"id":"01986f2a-c800-7000-8000-000000000012","forked_from_id":"01986ef3-db00-7000-8000-000000000011","source":"vscode"}}"#
    let copiedTask = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01986ef3-db00-7000-8000-000000000099","started_at":1785585600}}"#
    let inherited = #"{"timestamp":"2026-08-01T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":500}}}}"#
    try ([meta, copiedTask, inherited].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(source: UsageSource(displayName: "test", provider: .codex, rootPath: root.path))
    #expect(result.events.isEmpty)
    #expect(result.warnings.isEmpty)
    #expect(result.accounting.inheritedBaselines == 1)
    #expect(!result.accounting.hasUnresolvedIssues)
}

@Test("Codex parent-edge metadata without a copied header is not inherited history")
func codexParentEdgeWithoutCopiedHeaderIsCounted() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-independent-agent.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let meta = #"{"timestamp":"2026-08-01T12:10:00.000Z","type":"session_meta","payload":{"id":"independent-agent","source":"vscode"}}"#
    let usage = #"{"timestamp":"2026-08-01T12:10:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60,"cached_input_tokens":30,"output_tokens":15}}}}"#
    try (meta + "\n" + usage + "\n").write(to: file, atomically: true, encoding: .utf8)

    let state = root.appendingPathComponent("state_1.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "AIUsageTrackerTests", code: 50)
    }
    let path = file.path.replacingOccurrences(of: "'", with: "''")
    let sql = "CREATE TABLE threads (id TEXT, rollout_path TEXT, model TEXT, agent_path TEXT); CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('independent-agent', '\(path)', 'gpt-5.6-sol', '/root/worker'); INSERT INTO thread_spawn_edges VALUES ('parent-agent', 'independent-agent');"
    guard sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(raw)
        throw NSError(domain: "AIUsageTrackerTests", code: 51)
    }
    sqlite3_close(raw)

    let source = UsageSource(displayName: "test", provider: .codex, rootPath: root.path)
    let scanned = UsageScanner.scan(source: source)
    #expect(scanned.events.count == 1)
    #expect(scanned.events.first?.usage == TokenUsage(inputTokens: 30, cachedInputTokens: 30, outputTokens: 15))
    #expect(scanned.events.first?.isSubagent == true)
    #expect(scanned.events.first?.parentSessionID == "parent-agent")
    #expect(scanned.accounting.inheritedBaselines == 0)

    let snapshot = CodexScanner.quickScanFile(source: source, url: file, metadata: CodexMetadata(root: root), includeInheritedUsage: true)
    #expect(snapshot.events.count == 1)
    #expect(snapshot.events.first?.isSubagent == true)
}

@Test("Codex snapshot mode stays bounded across updates and supports explicit conversion")
func codexSnapshotModeIsBounded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-fast.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let first = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}}}}"#
    let last = #"{"timestamp":"2026-08-01T12:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":8,"output_tokens":4}}}}"#
    try (first + "\n" + last + "\n").write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "fast", provider: .codex, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let fast = db.refresh(sources: [source], bootstrapOnly: true)
    #expect(fast.isProvisional)
    #expect(db.compactSummary(sourceIDs: Set([source.id])).isProvisional)
    #expect(db.summary(sourceIDs: Set([source.id])).usage.outputTokens == 4)
    let ordinaryRefresh = db.refresh(sources: [source], snapshotOnly: true)
    #expect(ordinaryRefresh.isProvisional)
    #expect(ordinaryRefresh.changedFiles == 0)
    let appended = #"{"timestamp":"2026-08-01T12:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":6}}}}"#
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((appended + "\n").utf8))
    try handle.close()
    let snapshotUpdate = db.refresh(sources: [source], snapshotOnly: true)
    #expect(snapshotUpdate.isProvisional)
    #expect(snapshotUpdate.changedFiles == 1)
    #expect(db.summary(sourceIDs: Set([source.id])).eventCount == 1)
    #expect(db.summary(sourceIDs: Set([source.id])).usage.outputTokens == 6)
    let detailed = db.refresh(sources: [source], fullReconciliation: true)
    #expect(!detailed.isProvisional)
    #expect(!db.compactSummary(sourceIDs: Set([source.id])).isProvisional)
    #expect(db.summary(sourceIDs: Set([source.id])).eventCount == 3)
    #expect(db.summary(sourceIDs: Set([source.id])).usage.outputTokens == 6)
}

@Test("Codex snapshot refresh is driven by transcripts, not state database churn")
func codexSnapshotIgnoresStateDatabaseChurn() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-state-churn.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    #expect(store.refresh(sources: [source], snapshotOnly: true).changedFiles == 1)

    let state = root.appendingPathComponent("state_1.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "AIUsageTrackerTests", code: 40)
    }
    guard sqlite3_exec(raw, "CREATE TABLE threads (id TEXT, rollout_path TEXT, model TEXT, agent_path TEXT)", nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(raw)
        throw NSError(domain: "AIUsageTrackerTests", code: 41)
    }
    sqlite3_close(raw)

    let unchanged = store.refresh(sources: [source], snapshotOnly: true)
    #expect(unchanged.changedFiles == 0)
    #expect(unchanged.bytesRead == 0)
    #expect(!unchanged.metadataChanged)
}

@Test("Codex threads without token counters are checkpointed once")
func codexEmptyThreadSnapshotIsStable() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-empty.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#.write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))

    let first = store.refresh(sources: [source], snapshotOnly: true)
    let second = store.refresh(sources: [source], snapshotOnly: true)
    #expect(first.changedFiles == 1)
    #expect(second.changedFiles == 0)
    #expect(second.bytesRead == 0)
    #expect(second.warnings.isEmpty)
    #expect(store.summary(sourceIDs: Set([source.id])).eventCount == 0)
}

@Test("First-frame Codex headline does not require SQLite")
func codexHeadlineIsDatabaseIndependent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-headline.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":30,"output_tokens":5}}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)

    let headline = UsageHeadlineScanner.scanCodex(sources: [source], timeLimit: 4)
    #expect(headline.complete)
    #expect(headline.summary.eventCount == 1)
    #expect(headline.summary.usage.inputTokens == 10)
    #expect(headline.summary.usage.cachedInputTokens == 30)
    #expect(headline.summary.usage.outputTokens == 5)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("index.sqlite").path))
}

@Test("Bounded Codex headlines fail closed when a child baseline is outside the head window")
func boundedHeadlineRequiresInheritedBaseline() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-child.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let spawn = #"{"type":"event_msg","payload":{"type":"thread_spawn","forked_from_id":"parent","parent_thread_id":"parent"}}"#
    let padding = #"{"type":"response_item","payload":""# + String(repeating: "x", count: 600_000) + #""}"#
    let counter = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":900000,"output_tokens":10000}}}}"#
    try ([spawn, padding, counter].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let result = CodexScanner.quickScanFile(
        source: source,
        url: file,
        metadata: CodexMetadata(root: root),
        maximumTailWindow: 512 * 1024
    )

    #expect(result.events.isEmpty)
    #expect(result.accounting.inheritedBaselines == 1)
    #expect(result.warnings.count == 1)
}

@Test("A compatible index can seed a read-only first-frame headline")
func readOnlyHeadlineSeed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"seed-session","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"seed-message","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":11}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "claude", provider: .claude, rootPath: root.path)
    let database = root.appendingPathComponent("index.sqlite")
    let store = try SQLiteIndexStore(url: database)
    _ = store.refresh(sources: [source])

    let headline = try #require(SQLiteIndexStore.readOnlyOverview(at: database, sourceIDs: Set([source.id])))
    #expect(headline.eventCount == 1)
    #expect(headline.sessionCount == 1)
    #expect(headline.usage.inputTokens == 7)
    #expect(headline.usage.outputTokens == 11)
}

@Test("Codex archived sessions are included")
func codexArchivedSessions() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("archived_sessions/rollout-archived.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4}}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)
    let scanned = UsageScanner.scan(source: source)
    #expect(scanned.events.count == 1)
    #expect(scanned.events.first?.sourcePath.hasSuffix("/archived_sessions/rollout-archived.jsonl") == true)

    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let refreshed = db.refresh(sources: [source])
    #expect(refreshed.changedFiles == 1)
    #expect(db.events(sourceIDs: Set([source.id])).count == 1)
}

@Test("Codex metadata enriches identity without overwriting turn models")
func codexMetadataOnlyEnrichment() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-test.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = #"{"timestamp":"2026-08-01T11:59:59.000Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#
    let line = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4}}}}"#
    try (context + "\n" + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)
    let first = db.refresh(sources: [source])
    let before = try #require(db.events(sourceIDs: Set([source.id])).first)
    #expect(first.changedFiles == 1)
    #expect(before.model == "gpt-5.6-luna")

    let state = root.appendingPathComponent("state_1.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 10) }
    guard sqlite3_exec(raw, "CREATE TABLE threads (id TEXT, rollout_path TEXT, model TEXT, agent_path TEXT)", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 11) }
    var statement: OpaquePointer?
    let insert = "INSERT INTO threads (id, rollout_path, model, agent_path) VALUES (?, ?, ?, NULL)"
    guard sqlite3_prepare_v2(raw, insert, -1, &statement, nil) == SQLITE_OK, let statement else { throw NSError(domain: "AIUsageTrackerTests", code: 12) }
    sqlite3_bind_text(statement, 1, "thread-1", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, file.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 3, "gpt-5.5", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "AIUsageTrackerTests", code: 13) }
    sqlite3_finalize(statement)
    sqlite3_close(raw)

    let second = db.refresh(sources: [source])
    let after = try #require(db.events(sourceIDs: Set([source.id])).first)
    #expect(second.changedFiles == 0)
    #expect(second.bytesRead == 0)
    #expect(second.metadataChanged)
    #expect(second.metadataUpdatedEvents == 1)
    #expect(after.id == before.id)
    #expect(after.usage == before.usage)
    #expect(after.model == "gpt-5.6-luna")
    #expect(after.sessionID == "thread-1")
}

@Test("Claude attribution changes enrich without rereading transcripts")
func claudeMetadataOnlyEnrichment() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"session-1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "claude", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    let before = try #require(db.events(sourceIDs: Set([source.id])).first)
    #expect(before.attributionConfidence == .sourceOnly)

    let telemetry = root.appendingPathComponent("telemetry/session.json")
    try FileManager.default.createDirectory(at: telemetry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"event_data":{"session_id":"session-1","auth":{"account_uuid":"acct-verified"}}}"#.write(to: telemetry, atomically: true, encoding: .utf8)
    let second = db.refresh(sources: [source])
    let after = try #require(db.events(sourceIDs: Set([source.id])).first)
    #expect(second.changedFiles == 0)
    #expect(second.bytesRead == 0)
    #expect(second.metadataChanged)
    #expect(second.metadataUpdatedEvents == 1)
    #expect(after.id == before.id)
    #expect(after.usage == before.usage)
    #expect(after.accountID == "acct-verified")
    #expect(after.attributionConfidence == .sessionVerified)
}

@Test("Incomplete Codex metadata is retried without advancing its fingerprint")
func incompleteCodexMetadataRetries() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/01/rollout-test.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"timestamp":"2026-08-01T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "codex", provider: .codex, rootPath: root.path)
    _ = db.refresh(sources: [source])

    let state = root.appendingPathComponent("state_1.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 20) }
    sqlite3_close(raw)
    raw = nil
    let failed = db.refresh(sources: [source])
    #expect(failed.metadataChanged)
    #expect(failed.metadataUpdatedEvents == 0)
    #expect(failed.bytesRead == 0)
    #expect(!failed.warnings.isEmpty)

    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 21) }
    guard sqlite3_exec(raw, "CREATE TABLE threads (id TEXT, rollout_path TEXT, model TEXT, agent_path TEXT)", nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 22) }
    let insert = "INSERT INTO threads (id, rollout_path, model, agent_path) VALUES ('thread-1', '\(file.path.replacingOccurrences(of: "'", with: "''"))', 'gpt-5.5', NULL)"
    guard sqlite3_exec(raw, insert, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 23) }
    sqlite3_close(raw)
    raw = nil
    let retried = db.refresh(sources: [source])
    #expect(retried.bytesRead == 0)
    #expect(retried.metadataUpdatedEvents == 1)
    #expect(db.events(sourceIDs: Set([source.id])).first?.model == "gpt-5.5")
}

@Test("Index refresh is idempotent and skips unchanged files")
func indexRefreshIsIncremental() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/demo"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":2,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":4}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let first = db.refresh(sources: [source])
    let second = db.refresh(sources: [source])
    #expect(first.changedFiles == 1)
    #expect(second.changedFiles == 0)
    #expect(second.bytesRead == 0)
    #expect(db.events().count == 1)

    let appended = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:01.000Z","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":4,"cache_read_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":6}}}"#
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((appended + "\n").utf8))
    try handle.close()
    let third = db.refresh(sources: [source])
    #expect(third.changedFiles == 1)
    #expect(db.events().count == 2)
    let summary = db.summary(from: DateParsing.parse("2026-08-01T00:00:00Z"), to: DateParsing.parse("2026-08-02T00:00:00Z"), sourceIDs: Set([source.id]))
    #expect(summary.eventCount == 2)
    #expect(summary.usage.outputTokens == 10)
    #expect(summary.sessionCount == 1)
    #expect(summary.attributionCounts[AttributionConfidence.sourceOnly.rawValue] == 2)
}

@Test("Large append-only transcripts stay incremental while atomic replacements reparse")
func largeTranscriptAppendUsesFileIdentity() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let file = projects.appendingPathComponent("large.jsonl")
    let padding = String(repeating: "x", count: 180)
    func line(_ index: Int) -> String {
        #"{"type":"assistant","sessionId":"large","timestamp":"2026-08-01T12:00:00Z","message":{"id":"m-\#(index)","model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":2},"padding":"\#(padding)"}}"#
    }
    let initial = (0..<500).map(line).joined(separator: "\n") + "\n"
    #expect(initial.utf8.count > 64 * 1024)
    try initial.write(to: file, atomically: true, encoding: .utf8)

    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "large", provider: .claude, rootPath: root.path)
    #expect(db.refresh(sources: [source]).changedFiles == 1)

    let appended = line(500) + "\n"
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appended.utf8))
    try handle.close()
    let incremental = db.refresh(sources: [source])
    #expect(incremental.bytesRead == Int64(appended.utf8.count))
    #expect(db.events(sourceIDs: Set([source.id])).count == 501)

    let rewritten = (0..<250).map(line).joined(separator: "\n") + "\n" + (1000..<1300).map(line).joined(separator: "\n") + "\n"
    let rewriteHandle = try FileHandle(forWritingTo: file)
    try rewriteHandle.truncate(atOffset: 0)
    try rewriteHandle.seek(toOffset: 0)
    try rewriteHandle.write(contentsOf: Data(rewritten.utf8))
    try rewriteHandle.close()
    let inPlaceRewrite = db.refresh(sources: [source])
    #expect(inPlaceRewrite.bytesRead == Int64(rewritten.utf8.count))
    #expect(db.events(sourceIDs: Set([source.id])).count == 550)
    #expect(!db.events(sourceIDs: Set([source.id])).contains { $0.id.contains("m-300") })

    let interiorEdited = rewritten.replacingOccurrences(of: "m-1050", with: "m-2050") + line(3000) + "\n"
    let interiorHandle = try FileHandle(forWritingTo: file)
    try interiorHandle.truncate(atOffset: 0)
    try interiorHandle.seek(toOffset: 0)
    try interiorHandle.write(contentsOf: Data(interiorEdited.utf8))
    try interiorHandle.close()
    _ = db.refresh(sources: [source])
    #expect(db.events(sourceIDs: Set([source.id])).contains { $0.id.contains("m-1050") })
    let reconciled = db.refresh(sources: [source], fullReconciliation: true)
    #expect(reconciled.bytesRead == Int64(interiorEdited.utf8.count))
    #expect(!db.events(sourceIDs: Set([source.id])).contains { $0.id.contains("m-1050") })
    #expect(db.events(sourceIDs: Set([source.id])).contains { $0.id.contains("m-2050") })

    let replacement = initial + line(1002) + "\n"
    try replacement.write(to: file, atomically: true, encoding: .utf8)
    let reparsed = db.refresh(sources: [source])
    #expect(reparsed.bytesRead == Int64(replacement.utf8.count))
    #expect(db.events(sourceIDs: Set([source.id])).count == 501)
    #expect(db.events(sourceIDs: Set([source.id])).contains { $0.id.contains("m-1002") })
}

@Test("FSEvent-scoped refresh indexes only changed files and removes deletions")
func fseventScopedRefresh() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let fileA = projects.appendingPathComponent("a.jsonl")
    let fileB = projects.appendingPathComponent("b.jsonl")
    let lineA = #"{"type":"assistant","sessionId":"a","timestamp":"2026-08-01T12:00:00Z","message":{"id":"a1","model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":2}}}"#
    let lineB = #"{"type":"assistant","sessionId":"b","timestamp":"2026-08-01T12:00:00Z","message":{"id":"b1","model":"claude-sonnet-4-6","usage":{"input_tokens":3,"output_tokens":4}}}"#
    try (lineA + "\n").write(to: fileA, atomically: true, encoding: .utf8)
    try (lineB + "\n").write(to: fileB, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "targeted", provider: .claude, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    #expect(db.refresh(sources: [source]).changedFiles == 2)

    let updatedA = #"{"type":"assistant","sessionId":"a","timestamp":"2026-08-01T12:00:00Z","message":{"id":"a1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20}}}"#
    try (updatedA + "\n").write(to: fileA, atomically: true, encoding: .utf8)
    let changed = db.refresh(sources: [source], changedPaths: Set([fileA.path]))
    #expect(changed.changedFiles == 1)
    #expect(changed.bytesRead == Int64(updatedA.utf8.count + 1))
    #expect(db.summary().usage.outputTokens == 24)

    let sameSizeA = updatedA.replacingOccurrences(of: #""output_tokens":20"#, with: #""output_tokens":21"#)
    #expect(sameSizeA.utf8.count == updatedA.utf8.count)
    try sameSizeA.write(to: fileA, atomically: false, encoding: .utf8)
    let sameSizeRefresh = db.refresh(sources: [source], changedPaths: Set([fileA.path]))
    #expect(sameSizeRefresh.changedFiles == 1)
    #expect(db.summary().usage.outputTokens == 25)

    let fileC = projects.appendingPathComponent("c.jsonl")
    let lineC = #"{"type":"assistant","sessionId":"c","timestamp":"2026-08-01T12:00:00Z","message":{"id":"c1","model":"claude-sonnet-4-6","usage":{"input_tokens":5,"output_tokens":6}}}"#
    try (lineC + "\n").write(to: fileC, atomically: true, encoding: .utf8)
    #expect(db.refresh(sources: [source], changedPaths: Set([fileC.path])).changedFiles == 1)
    try FileManager.default.removeItem(at: fileB)
    let removed = db.refresh(sources: [source], changedPaths: Set([fileB.path]))
    #expect(removed.removedFiles == 1)
    #expect(db.events().count == 2)
}

@Test("Root-scoped refresh ignores unrelated JSONL files")
func rootScopedRefreshIgnoresUnrelatedJSONL() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects/demo")
    let unrelated = root.appendingPathComponent("other/not-a-transcript.jsonl")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
    let projectLine = #"{"type":"assistant","sessionId":"project","timestamp":"2026-08-01T12:00:00Z","message":{"id":"project-1","model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":2}}}"#
    let unrelatedLine = #"{"type":"assistant","sessionId":"wrong","timestamp":"2026-08-01T12:00:00Z","message":{"id":"wrong-1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":200}}}"#
    try (projectLine + "\n").write(to: projects.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    try (unrelatedLine + "\n").write(to: unrelated, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "scoped", provider: .claude, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    #expect(db.refresh(sources: [source]).changedFiles == 1)
    #expect(db.events(sourceIDs: Set([source.id])).count == 1)

    let changed = db.refresh(sources: [source], changedPaths: Set([root.path]))
    #expect(changed.changedFiles == 0)
    #expect(db.events(sourceIDs: Set([source.id])).count == 1)
    #expect(db.events(sourceIDs: Set([source.id])).first?.sessionID == "project")
}

@Test("Index refresh batches changed file writes")
func indexRefreshBatchesChangedFiles() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    for index in 0..<129 {
        let file = projects.appendingPathComponent("session-\(index).jsonl")
        let line = #"{"type":"assistant","sessionId":"s-\#(index)","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m-\#(index)","model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":2}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    let source = UsageSource(displayName: "batched", provider: .claude, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let first = db.refresh(sources: [source])
    let second = db.refresh(sources: [source])
    #expect(first.changedFiles == 129)
    #expect(db.events(sourceIDs: Set([source.id])).count == 129)
    #expect(second.changedFiles == 0)
    #expect(second.bytesRead == 0)
}

@Test("Disabled sources are excluded until re-enabled")
func disabledSourcesAreExcluded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let disabled = UsageSource(displayName: "disabled", provider: .claude, rootPath: root.path, enabled: false)
    #expect(db.refresh(sources: [disabled]).changedFiles == 0)
    #expect(db.events().isEmpty)
    let enabled = UsageSource(id: disabled.id, displayName: disabled.displayName, provider: disabled.provider, rootPath: disabled.rootPath, enabled: true)
    #expect(db.refresh(sources: [enabled]).changedFiles == 1)
    #expect(db.events().count == 1)
}

@Test("Source settings preserve identity, enabled state, and bookmarks")
func sourceSettingsRoundTrip() throws {
    let source = UsageSource(id: "claude:/preserved/account", displayName: "Account", provider: .claude, rootPath: "/preserved/account", enabled: false, bookmarkData: Data([1, 2, 3]), monthlySubscriptionUSD: 20)
    let encoded = try JSONEncoder().encode([source])
    let decoded = try JSONDecoder().decode([UsageSource].self, from: encoded)
    #expect(decoded == [source])
    let legacy = try JSONDecoder().decode([UsageSource].self, from: Data(#"[{"id":"claude:/legacy","displayName":"Legacy","provider":"Claude Code","rootPath":"/legacy","enabled":true}]"#.utf8))
    #expect(legacy.first?.monthlySubscriptionUSD == nil)
}

@Test("Subscription proration uses calendar days and survives reversed ranges")
func subscriptionProrationIsCalendarBased() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 30))!
    #expect(SubscriptionAccounting.calendarDays(from: start, to: end, calendar: calendar) == 30)
    #expect(SubscriptionAccounting.calendarDays(from: end, to: start, calendar: calendar) == 30)
    #expect(abs(SubscriptionAccounting.proratedCost(monthlyUSD: 30, startDate: start, endDate: end, calendar: calendar) - 30) < 0.001)
    #expect(SubscriptionAccounting.calendarDays(from: start, to: start, calendar: calendar) == 1)
    #expect(SubscriptionAccounting.valueMultiple(apiUSD: 100, subscriptionUSD: 20) == 5)
    #expect(SubscriptionAccounting.valueMultiple(apiUSD: 100, subscriptionUSD: 0) == nil)
    #expect(SubscriptionAccounting.proratedCost(monthlyUSD: Double.greatestFiniteMagnitude, startDate: start, endDate: end, calendar: calendar).isFinite)
}

@Test("Usage date ranges use inclusive local calendar days")
func usageDateRangeIntervals() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 18)))

    let week = try #require(UsageDateRange.lastDays(7).interval(now: now, calendar: calendar))
    #expect(week.start == calendar.date(from: DateComponents(year: 2026, month: 7, day: 28)))
    #expect(week.end == calendar.date(from: DateComponents(year: 2026, month: 8, day: 4)))

    let augustFirst = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
    let augustThird = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3)))
    let reversed = try #require(UsageDateRange.custom(start: augustThird, end: augustFirst).interval(now: now, calendar: calendar))
    #expect(reversed.start == augustFirst)
    #expect(reversed.end == calendar.date(from: DateComponents(year: 2026, month: 8, day: 4)))

    let year = try #require(UsageDateRange.yearToDate.interval(now: now, calendar: calendar))
    #expect(year.start == calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
    #expect(year.end == calendar.date(from: DateComponents(year: 2026, month: 8, day: 4)))

    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let fallBackDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    let dstInterval = try #require(UsageDateRange.custom(start: fallBackDay, end: fallBackDay).interval(calendar: calendar))
    #expect(dstInterval.duration == 25 * 60 * 60)

    let ranges: [UsageDateRange] = [.allTime, .lastDays(30), .yearToDate, .custom(start: augustFirst, end: augustThird)]
    for range in ranges {
        let encoded = try JSONEncoder().encode(range)
        #expect(try JSONDecoder().decode(UsageDateRange.self, from: encoded) == range)
    }
}

@Test("Date-filtered summaries query cached aggregates without rescanning")
func indexedDateRangeFiltering() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let first = #"{"type":"assistant","sessionId":"older","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":3,"output_tokens":5}}}"#
    let second = #"{"type":"assistant","sessionId":"selected","timestamp":"2026-08-02T12:00:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":11}}}"#
    try (first + "\n" + second + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    #expect(db.refresh(sources: [source]).changedFiles == 1)
    #expect(db.summary(sourceIDs: Set([source.id])).eventCount == 2)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let selectedDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
    let interval = try #require(UsageDateRange.custom(start: selectedDay, end: selectedDay).interval(calendar: calendar))
    let selected = db.summary(from: interval.start, to: interval.end, sourceIDs: Set([source.id]))
    #expect(selected.eventCount == 1)
    #expect(selected.sessionCount == 1)
    #expect(selected.usage.inputTokens == 7)
    #expect(selected.usage.outputTokens == 11)
    #expect(selected.days.map(\.day) == ["2026-08-02"])

    let compact = db.compactSummary(from: interval.start, to: interval.end, sourceIDs: Set([source.id]))
    #expect(compact.eventCount == 1)
    #expect(compact.usage == selected.usage)
    #expect(abs(compact.apiUSD - selected.apiUSD) < 0.000_001)
    #expect(compact.accounts.count == 1)
}

@Test("Usage export snapshot is versioned and excludes bookmark data")
func usageExportSnapshotRoundTrip() throws {
    let source = UsageSource(displayName: "Account", provider: .codex, rootPath: "/Users/private/.codex", bookmarkData: Data([1, 2, 3]), monthlySubscriptionUSD: 20)
    var summary = UsageSummary()
    summary.eventCount = 1
    summary.usage = TokenUsage(inputTokens: 4, outputTokens: 2)
    summary.accounts = [AccountUsageBreakdown(id: "codex:/Users/private/.codex", provider: .codex, sourceID: source.id, accountID: "unattributed", currentAuthAccountID: "acct-private", usage: summary.usage, eventCount: 1, apiUSD: 1, codexCredits: 2)]
    let snapshot = UsageExportSnapshot(
        start: Date(timeIntervalSince1970: 1_000),
        endExclusive: Date(timeIntervalSince1970: 2_000),
        timezone: "America/New_York",
        sources: [source],
        summary: summary,
        monthlySubscriptionUSD: 20,
        proratedSubscriptionUSD: 1,
        apiValueMultiple: 5
    )
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(UsageExportSnapshot.self, from: encoded)
    #expect(decoded.schemaVersion == UsageExportSnapshot.currentSchemaVersion)
    #expect(decoded.sources.first?.displayName == "Account")
    #expect(decoded.sources.first?.monthlySubscriptionUSD == 20)
    #expect(decoded.sources.first?.id == "source-1")
    #expect(String(data: encoded, encoding: .utf8)?.contains("bookmarkData") == false)
    #expect(String(data: encoded, encoding: .utf8)?.contains("/Users/private") == false)
    #expect(String(data: encoded, encoding: .utf8)?.contains("acct-private") == false)
    #expect(decoded.summary.accounts.first?.id == "account-1")
    #expect(decoded.summary.accounts.first?.sourceID == "source-1")
    #expect(decoded.summary.accounts.first?.currentAuthAccountID == "current-auth-1")
    #expect(decoded.summary.eventCount == 1)
}

@Test("Concurrent refresh and summary calls remain serialized")
func concurrentIndexAccessIsSafe() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "concurrent", provider: .claude, rootPath: root.path)
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "AIUsageTrackerTests.concurrent", attributes: .concurrent)
    for _ in 0..<4 {
        group.enter()
        queue.async {
            _ = db.refresh(sources: [source])
            _ = db.summary(sourceIDs: Set([source.id]))
            group.leave()
        }
    }
    group.wait()
    #expect(db.events().count == 1)
    #expect(db.summary(sourceIDs: Set([source.id])).eventCount == 1)
}

@Test("Claude pricing includes cache creation and reads")
func claudePricing() {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 2_000_000, cacheWrite5mInputTokens: 3_000_000, cacheWrite1hInputTokens: 4_000_000, outputTokens: 5_000_000)
    let estimate = PricingCatalog.estimate(usage, provider: .claude, model: "claude-opus-5", at: Date())
    let costs = PricingCatalog.apiCostBreakdown(usage, provider: .claude, model: "claude-opus-5", at: Date())
    #expect(abs((estimate.apiUSD ?? 0) - 189.75) < 0.001)
    #expect(costs?.uncachedInputUSD == 5)
    #expect(costs?.cachedInputUSD == 59.75)
    #expect(costs?.outputUSD == 125)
    #expect(costs?.totalUSD == estimate.apiUSD)
    #expect(PricingCatalog.estimate(TokenUsage(outputTokens: 1_000_000), provider: .claude, model: "claude-opus-4-8[1m]", at: Date()).apiUSD == 25)
    #expect(PricingCatalog.estimate(TokenUsage(outputTokens: 1_000_000), provider: .claude, model: "claude-sonnet-4-20250514", at: Date()).apiUSD == 15)
}

@Test("Sonnet 5 keeps its introductory price after the cancelled increase")
func sonnet5PricingTransition() {
    let cutoff = DateParsing.parse("2026-09-01T00:00:00Z")!
    let before = PricingCatalog.estimate(TokenUsage(outputTokens: 1_000_000), provider: .claude, model: "claude-sonnet-5", at: cutoff.addingTimeInterval(-1))
    let after = PricingCatalog.estimate(TokenUsage(outputTokens: 1_000_000), provider: .claude, model: "claude-sonnet-5", at: cutoff.addingTimeInterval(1))
    #expect(before.apiUSD == 10)
    #expect(after.apiUSD == 10)
}

@Test("Current Codex Terra and Luna rates match the published cards")
func currentCodexRates() {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000)
    let terra = PricingCatalog.estimate(usage, provider: .codex, model: "gpt-5.6-terra", at: Date())
    #expect(abs((terra.apiUSD ?? 0) - 14.2) < 0.0001)
    #expect(abs((terra.codexCredits ?? 0) - 355) < 0.0001)

    let luna = PricingCatalog.estimate(usage, provider: .codex, model: "gpt-5.6-luna", at: Date())
    #expect(abs((luna.apiUSD ?? 0) - 1.42) < 0.0001)
    #expect(abs((luna.codexCredits ?? 0) - 35.5) < 0.0001)
}

@Test("Codex pricing applies long-context premiums only to explicit request usage")
func codexLongContextPricing() {
    let usage = TokenUsage(inputTokens: 100_000, cachedInputTokens: 200_000, outputTokens: 10_000)
    let quote = UsageAccounting.quote(
        usage: usage,
        pricingContext: APIPricingContext(longContextUsage: usage),
        provider: .codex,
        model: "gpt-5.6-sol",
        at: Date()
    )
    #expect(abs((quote.apiCost?.uncachedInputUSD ?? 0) - 0.8) < 0.000001)
    #expect(abs((quote.apiCost?.cachedInputUSD ?? 0) - 0.16) < 0.000001)
    #expect(abs((quote.apiCost?.outputUSD ?? 0) - 0.3) < 0.000001)
    #expect(abs((quote.apiUSD ?? 0) - 1.26) < 0.000001)
    #expect(abs((quote.codexCredits ?? 0) - 17) < 0.000001)
}

@Test("Codex scanner attributes each request to its turn model")
func codexPerTurnModelAttribution() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/03/rollout-model-switch.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let luna = #"{"timestamp":"2026-08-03T12:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#
    let first = #"{"timestamp":"2026-08-03T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":250000,"output_tokens":10000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":250000,"output_tokens":10000}}}}"#
    let sol = #"{"timestamp":"2026-08-03T12:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    let second = #"{"timestamp":"2026-08-03T12:01:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300100,"cached_input_tokens":250050,"output_tokens":10010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}}}"#
    try ([luna, first, sol, second].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let scanned = UsageScanner.scan(source: source)
    #expect(scanned.events.map(\.model) == ["gpt-5.6-luna", "gpt-5.6-sol"])
    #expect(scanned.events[0].pricingContext.longContextUsage == scanned.events[0].usage)
    #expect(scanned.events[1].pricingContext.longContextUsage == TokenUsage())

    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])
    let compact = store.compactSummary(sourceIDs: Set([source.id]))
    let full = store.summary(sourceIDs: Set([source.id]))
    #expect(abs(compact.apiUSD - full.apiUSD) < 0.000001)
    #expect(abs(compact.apiUSD - UsageAggregator.summarize(scanned.events).apiUSD) < 0.000001)
}

@Test("Incremental Codex scans resume the active turn model")
func codexIncrementalModelCursorMatchesFreshReplay() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/03/rollout-model-cursor.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = #"{"timestamp":"2026-08-03T12:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#
    let first = #"{"timestamp":"2026-08-03T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":250000,"output_tokens":10000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":250000,"output_tokens":10000}}}}"#
    try ([context, first].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let incrementalStore = try SQLiteIndexStore(url: root.appendingPathComponent("incremental.sqlite"))
    _ = incrementalStore.refresh(sources: [source])

    let second = #"{"timestamp":"2026-08-03T12:01:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300100,"cached_input_tokens":250050,"output_tokens":10010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}}}"#
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((second + "\n").utf8))
    try handle.close()
    _ = incrementalStore.refresh(sources: [source], changedPaths: Set([file.path]))
    let incremental = incrementalStore.summary(sourceIDs: Set([source.id]))

    let freshStore = try SQLiteIndexStore(url: root.appendingPathComponent("fresh.sqlite"))
    _ = freshStore.refresh(sources: [source])
    let fresh = freshStore.summary(sourceIDs: Set([source.id]))

    #expect(incremental.usage == fresh.usage)
    #expect(incremental.eventCount == fresh.eventCount)
    #expect(abs(incremental.apiUSD - fresh.apiUSD) < 0.000001)
    #expect(incremental.models == fresh.models)
    #expect(incremental.models.map(\.id) == ["Codex:gpt-5.6-luna"])
}

@Test("A large multi-turn Codex chat reconciles raw counters through pricing")
func auditedLargeCodexChatAccounting() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions/2026/08/03/rollout-audited.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

    // These are the first and final provider counters from a manually audited
    // 158-message, 18,546-snapshot chat. The repeated middle row proves a
    // duplicate cumulative snapshot cannot repeat its `last_token_usage`.
    // `input_tokens` includes cached input, and reasoning is already included
    // in output, so neither category may be double counted.
    let first = #"{"timestamp":"2026-07-14T05:08:43.981Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15802,"cached_input_tokens":9984,"cache_write_input_tokens":0,"output_tokens":735,"reasoning_output_tokens":363,"total_tokens":16537},"last_token_usage":{"input_tokens":15802,"cached_input_tokens":9984,"cache_write_input_tokens":0,"output_tokens":735,"reasoning_output_tokens":363,"total_tokens":16537}}}}"#
    let duplicate = #"{"timestamp":"2026-07-14T05:08:44.981Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15802,"cached_input_tokens":9984,"cache_write_input_tokens":0,"output_tokens":735,"reasoning_output_tokens":363,"total_tokens":16537},"last_token_usage":{"input_tokens":15802,"cached_input_tokens":9984,"cache_write_input_tokens":0,"output_tokens":735,"reasoning_output_tokens":363,"total_tokens":16537}}}}"#
    let final = #"{"timestamp":"2026-07-21T20:27:35.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2482602067,"cached_input_tokens":2413521408,"cache_write_input_tokens":0,"output_tokens":6283102,"reasoning_output_tokens":1559065,"total_tokens":2488885169}}}}"#
    try ([first, duplicate, final].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

    let state = root.appendingPathComponent("state_1.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(state.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "AIUsageTrackerTests", code: 30)
    }
    let path = file.path.replacingOccurrences(of: "'", with: "''")
    let statements = [
        "CREATE TABLE threads (id TEXT, rollout_path TEXT, model TEXT, agent_path TEXT)",
        "INSERT INTO threads (id, rollout_path, model, agent_path) VALUES ('audited-chat', '\(path)', 'gpt-5.6-sol', NULL)"
    ]
    for statement in statements {
        guard sqlite3_exec(raw, statement, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(raw)
            throw NSError(domain: "AIUsageTrackerTests", code: 31)
        }
    }
    sqlite3_close(raw)

    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let store = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    _ = store.refresh(sources: [source])
    let summary = store.summary(sourceIDs: Set([source.id]))

    #expect(summary.eventCount == 2)
    #expect(summary.usage.inputTokens == 69_080_659)
    #expect(summary.usage.cachedInputTokens == 2_413_521_408)
    #expect(summary.usage.outputTokens == 6_283_102)
    #expect(summary.usage.reasoningOutputTokens == 1_559_065)
    #expect(summary.usage.totalTokens == 2_488_885_169)
    #expect(abs(summary.apiUSD - 1_740.657059) < 0.000001)
    #expect(abs(summary.codexCredits - 43_516.426475) < 0.000001)
}

@Test("Codex research preview remains explicitly unpriced")
func codexResearchPreviewIsUnpriced() {
    let estimate = PricingCatalog.estimate(TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000), provider: .codex, model: "gpt-5.3-codex-spark", at: Date())
    #expect(estimate.apiUSD == nil)
    #expect(estimate.codexCredits == nil)
}

@Test("Serving-cost estimates reverse provider-specific API margin bands")
func servingCostEstimateUsesProviderMargins() {
    let openAI = ServingCostCatalog.estimate(apiUSD: 1_000, provider: .codex)
    #expect(openAI == ServingCostEstimate(lowerUSD: 400, midpointUSD: 450, upperUSD: 500))

    let anthropic = ServingCostCatalog.estimate(apiUSD: 1_000, provider: .claude)
    #expect(anthropic == ServingCostEstimate(lowerUSD: 450, midpointUSD: 525, upperUSD: 600))

    let combined = openAI + anthropic
    #expect(combined == ServingCostEstimate(lowerUSD: 850, midpointUSD: 975, upperUSD: 1_100))
    #expect(ServingCostCatalog.estimate(apiUSD: .nan, provider: .codex) == ServingCostEstimate())

    let custom = ServingCostCatalog.estimate(apiUSD: 1_000, provider: .codex, midpointRatio: 0.30)
    #expect(custom == ServingCostEstimate(lowerUSD: 250, midpointUSD: 300, upperUSD: 350))
    #expect(ServingCostCatalog.defaultMidpointRatio(for: .codex) == 0.45)
    #expect(ServingCostCatalog.defaultMidpointRatio(for: .claude) == 0.525)
}

@Test("Indexed summaries do not apply the cancelled Sonnet 5 price increase")
func indexedPricingTransition() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let before = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-31T12:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-5","usage":{"output_tokens":1000000}}}"#
    let after = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-01T01:00:00.000Z","message":{"id":"m2","model":"claude-sonnet-5","usage":{"output_tokens":1000000}}}"#
    try (before + "\n" + after + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    #expect(abs(db.summary().apiUSD - 20) < 0.001)
}

@Test("Unterminated JSONL tail is re-read after append")
func unterminatedTailRecovery() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/demo"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    let line1 = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    let line2 = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:01.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":3,"output_tokens":4}}}"#
    try line1.write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    #expect(db.events().count == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(("\n" + line2 + "\n").utf8)); try handle.close()
    _ = db.refresh(sources: [source])
    #expect(db.events().count == 2)
}

@Test("Identical Claude message IDs remain isolated across account roots")
func multiSourceIsolation() throws {
    let rootA = try makeRoot()
    let rootB = try makeRoot()
    defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
    let line = #"{"type":"assistant","sessionId":"same-session","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"same-message","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    for root in [rootA, rootB] {
        let file = root.appendingPathComponent("projects/demo/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    let db = try SQLiteIndexStore(url: rootA.appendingPathComponent("index.sqlite"))
    let sourceA = UsageSource(displayName: "A", provider: .claude, rootPath: rootA.path)
    let sourceB = UsageSource(displayName: "B", provider: .claude, rootPath: rootB.path)
    _ = db.refresh(sources: [sourceA, sourceB])
    #expect(db.events().count == 2)
    let summary = db.summary(sourceIDs: Set([sourceA.id, sourceB.id]))
    #expect(summary.eventCount == 2)
    #expect(summary.sessionCount == 2)
    #expect(summary.accounts.count == 2)
    #expect(summary.accounts.allSatisfy { $0.attributionConfidence == .sourceOnly })
}

@Test("An unavailable source retains its cached events")
func unavailableSourceRetainsCache() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    try FileManager.default.removeItem(at: root.appendingPathComponent("projects"))
    let refresh = db.refresh(sources: [source])
    #expect(!refresh.warnings.isEmpty)
    #expect(refresh.staleSourceIDs.contains(source.id))
    #expect(db.events().count == 1)
}

@Test("A scan warning retains the last known-good events")
func scanWarningRetainsCache() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    let db = try SQLiteIndexStore(url: root.appendingPathComponent("index.sqlite"))
    let source = UsageSource(displayName: "test", provider: .claude, rootPath: root.path)
    _ = db.refresh(sources: [source])
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0xFF]))
    try handle.close()
    let refresh = db.refresh(sources: [source])
    #expect(!refresh.warnings.isEmpty)
    #expect(db.events().count == 1)
}

@Test("Legacy SQLite indexes migrate attribution columns")
func legacyIndexMigration() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = UsageSource(displayName: "legacy", provider: .claude, rootPath: root.path)
    let databaseURL = root.appendingPathComponent("legacy.sqlite")
    var raw: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "AIUsageTrackerTests", code: 1)
    }
    defer { sqlite3_close(raw) }
    let oldFiles = "CREATE TABLE files (source_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL, parsed_offset INTEGER NOT NULL DEFAULT 0, last_input INTEGER NOT NULL DEFAULT 0, last_cached INTEGER NOT NULL DEFAULT 0, last_cache_5m INTEGER NOT NULL DEFAULT 0, last_cache_1h INTEGER NOT NULL DEFAULT 0, last_output INTEGER NOT NULL DEFAULT 0, last_reasoning INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_id, path))"
    let oldEvents = "CREATE TABLE events (id TEXT PRIMARY KEY, provider TEXT NOT NULL, source_id TEXT NOT NULL, account_id TEXT NOT NULL, session_id TEXT NOT NULL, parent_session_id TEXT, timestamp REAL NOT NULL, model TEXT NOT NULL, source_path TEXT NOT NULL, byte_offset INTEGER NOT NULL, is_subagent INTEGER NOT NULL, input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL, cache_write_5m_tokens INTEGER NOT NULL, cache_write_1h_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL)"
    for sql in [oldFiles, oldEvents, "CREATE TABLE source_metadata (source_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)"] {
        guard sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "AIUsageTrackerTests", code: 2) }
    }
    let legacyPath = root.appendingPathComponent("projects/demo/legacy.txt").path
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: legacyPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("legacy placeholder".utf8).write(to: URL(fileURLWithPath: legacyPath))
    let insert = "INSERT INTO events (id, provider, source_id, account_id, session_id, parent_session_id, timestamp, model, source_path, byte_offset, is_subagent, input_tokens, cached_input_tokens, cache_write_5m_tokens, cache_write_1h_tokens, output_tokens, reasoning_output_tokens) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, 7, 0, 11, 13, 17, 19, 23, 29)"
    var legacyStatement: OpaquePointer?
    guard sqlite3_prepare_v2(raw, insert, -1, &legacyStatement, nil) == SQLITE_OK, let legacyStatement else { throw NSError(domain: "AIUsageTrackerTests", code: 3) }
    defer { sqlite3_finalize(legacyStatement) }
    for (index, value) in ["legacy-event", "Claude Code", source.id, "legacy-account", "legacy-session"] .enumerated() {
        sqlite3_bind_text(legacyStatement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    sqlite3_bind_double(legacyStatement, 6, Date(timeIntervalSince1970: 1_754_060_400).timeIntervalSince1970)
    sqlite3_bind_text(legacyStatement, 7, "claude-opus-5", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(legacyStatement, 8, legacyPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(legacyStatement) == SQLITE_DONE else { throw NSError(domain: "AIUsageTrackerTests", code: 4) }
    sqlite3_close(raw)
    raw = nil

    let file = root.appendingPathComponent("projects/demo/session.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-01T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
    let fileData = Data((line + "\n").utf8)
    try fileData.write(to: file, options: [.atomic])
    var cursorDB: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &cursorDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let cursorDB else { throw NSError(domain: "AIUsageTrackerTests", code: 5) }
    let legacyCursorSQL = "INSERT INTO files (source_id, path, size, modified, parsed_offset, last_input, last_cached, last_cache_5m, last_cache_1h, last_output, last_reasoning) VALUES (?, ?, ?, 0, 0, 0, 0, 0, 0, 0, 0)"
    var cursorStatement: OpaquePointer?
    guard sqlite3_prepare_v2(cursorDB, legacyCursorSQL, -1, &cursorStatement, nil) == SQLITE_OK, let cursorStatement else { sqlite3_close(cursorDB); throw NSError(domain: "AIUsageTrackerTests", code: 6) }
    sqlite3_bind_text(cursorStatement, 1, source.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(cursorStatement, 2, file.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int64(cursorStatement, 3, Int64(fileData.count))
    guard sqlite3_step(cursorStatement) == SQLITE_DONE else { sqlite3_finalize(cursorStatement); sqlite3_close(cursorDB); throw NSError(domain: "AIUsageTrackerTests", code: 7) }
    sqlite3_finalize(cursorStatement)
    sqlite3_close(cursorDB)
    let store = try SQLiteIndexStore(url: databaseURL)
    let migrated = store.events(sourceIDs: Set([source.id]))
    // The old cache generation used unsafe counter-reset semantics. It must
    // be discarded before corrected events are imported.
    #expect(migrated.isEmpty)
    let refreshed = store.refresh(sources: [source])
    #expect(refreshed.bytesRead == Int64(fileData.count))
    #expect(store.summary(sourceIDs: Set([source.id])).eventCount == 1)
}

@Test("Conventional root discovery finds local Codex and Claude Code roots")
func conventionalRootDiscovery() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)

    let sources = ProviderRootDiscovery.conventionalSources(home: home)
    #expect(sources.map(\.provider) == [.codex, .claude])
    #expect(sources.map(\.rootPath) == [home.appendingPathComponent(".codex").path, home.appendingPathComponent(".claude").path])
    #expect(ProviderRootDiscovery.isReadableDirectory(home.appendingPathComponent(".codex").path))
}

@Test("Temp artifact janitor removes only stale prefixed entries")
func tempArtifactJanitorSweep() throws {
    let dir = try makeRoot()
    defer { try? FileManager.default.removeItem(at: dir) }

    let stale = dir.appendingPathComponent("AIUsageTrackerRealBenchmark-\(UUID().uuidString).sqlite")
    let staleSidecar = dir.appendingPathComponent(stale.lastPathComponent + "-wal")
    let fresh = dir.appendingPathComponent("AIUsageTrackerRealBenchmark-\(UUID().uuidString).sqlite")
    let unrelated = dir.appendingPathComponent("keep-me.sqlite")
    for url in [stale, staleSidecar, fresh, unrelated] {
        try Data("x".utf8).write(to: url)
    }
    let old = Date().addingTimeInterval(-48 * 60 * 60)
    for url in [stale, staleSidecar] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    let removed = TempArtifactJanitor.sweep(olderThan: 24 * 60 * 60, in: dir)

    #expect(removed == 2)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: staleSidecar.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageTrackerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
