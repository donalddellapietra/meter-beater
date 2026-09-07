import Foundation
import SQLite3
import Testing
@testable import UsageCore

private let pricingTestDate = Date(timeIntervalSince1970: 1_788_566_400) // 2026-09-05

@Test("Astra prices every token category and its long-context premium")
func astraPricing() throws {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 1_000_000,
                           cacheWrite5mInputTokens: 1_000_000, cacheWrite1hInputTokens: 1_000_000,
                           outputTokens: 1_000_000)
    for model in ["gpt-6-astra", "GPT-6-ASTRA", "gpt-6-astra-2026-09-03"] {
        let quote = PricingCatalog.quote(usage, provider: .codex, model: model, at: pricingTestDate)
        #expect(quote.apiUSD == 86)
        #expect(quote.codexCredits == 1_525)
        let long = PricingCatalog.quote(usage, pricingContext: APIPricingContext(longContextUsage: usage),
                                        provider: .codex, model: model, at: pricingTestDate)
        #expect(long.apiUSD == 147)
        #expect(long.codexCredits == 1_525)
        #expect(PricingCatalog.longContextThreshold(for: model, provider: .codex) == 272_000)
    }
}

@Test("Fable and Mythos 5.1 use the new cache rate without repricing version 5")
func fableAndMythosPricing() throws {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 4_000_000,
                           cacheWrite5mInputTokens: 1_000_000, cacheWrite1hInputTokens: 1_000_000,
                           outputTokens: 1_000_000)
    for family in ["fable", "mythos"] {
        for suffix in ["", "[1m]", "-20260901"] {
            let quote = PricingCatalog.quote(usage, provider: .claude,
                                            model: "claude-\(family)-5-1\(suffix)", at: pricingTestDate)
            #expect(quote.apiUSD == 93.5)
            #expect(quote.apiCost?.cachedInputUSD == 33.5)
        }
        #expect(PricingCatalog.estimate(usage, provider: .claude,
                                       model: "claude-\(family)-5", at: pricingTestDate).apiUSD == 96.5)
    }
}

@Test("Unknown versions and variants never borrow an older model's price")
func unknownModelVariantsStayUnpriced() {
    for model in ["gpt-5.9", "gpt-5.6-sol-pro", "gpt-6-astra-preview", "gpt-6-astra-2"] {
        #expect(PricingCatalog.rate(for: model, provider: .codex) == nil)
    }
    for model in ["claude-fable-5-2", "claude-mythos-5-2", "claude-opus-4-9"] {
        #expect(PricingCatalog.rate(for: model, provider: .claude) == nil)
    }
}

@Test("Verified older Codex models keep their own published prices")
func explicitLegacyCodexModels() throws {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000)
    for (model, expected) in [("gpt-5.2-codex", 15.925), ("gpt-5.1-codex", 11.375)] {
        for suffix in ["", "-20260101"] {
            let quote = PricingCatalog.estimate(usage, provider: .codex, model: model + suffix, at: pricingTestDate)
            #expect(abs(try #require(quote.apiUSD) - expected) < 0.000001)
        }
    }
}

@Test("GPT-5.6 price reductions preserve earlier API and credit rates")
func historicalModelPriceChanges() throws {
    let usage = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 1_000_000)
    let cases: [(String, Date, Double, Double, Double, Double)] = [
        ("gpt-5.6-sol", PricingCatalog.solRateChange, 35.5, 24.4, 887.5, 610),
        ("gpt-5.6-terra", PricingCatalog.terraLunaRateChange, 17.75, 14.2, 355, 355),
        ("gpt-5.6-luna", PricingCatalog.terraLunaRateChange, 7.1, 1.42, 35.5, 35.5),
    ]
    for (model, cutoff, oldUSD, newUSD, oldCredits, newCredits) in cases {
        let before = PricingCatalog.estimate(usage, provider: .codex, model: model, at: cutoff.addingTimeInterval(-1))
        let after = PricingCatalog.estimate(usage, provider: .codex, model: model, at: cutoff)
        #expect(abs(try #require(before.apiUSD) - oldUSD) < 0.000001)
        #expect(abs(try #require(after.apiUSD) - newUSD) < 0.000001)
        #expect(before.codexCredits == oldCredits)
        #expect(after.codexCredits == newCredits)
    }
}

@Test("All summary paths keep rate periods separate across price changes")
func summaryPricingPeriods() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let cases: [(String, Date)] = [
        ("gpt-5.6-sol", PricingCatalog.solRateChange),
        ("gpt-5.6-terra", PricingCatalog.terraLunaRateChange),
        ("gpt-5.6-luna", PricingCatalog.terraLunaRateChange),
    ]
    for (index, entry) in cases.enumerated() {
        for offset in [-1.0, 0.0, 1.0] {
            try writePricingTranscript(root: root, name: "\(index)-\(offset)", model: entry.0,
                                       date: entry.1.addingTimeInterval(offset))
        }
    }
    let scanned = UsageScanner.scan(source: source)
    let direct = UsageAggregator.summarize(scanned.events)
    #expect(abs(direct.apiUSD - 140.39) < 0.000001)
    var rollups = EventRollupAccumulator()
    for event in scanned.events {
        // Put both sides of each cutoff in the same transcript/session so this
        // catches accidental merging within a local day, not just SQL grouping.
        rollups.append(UsageEvent(id: event.id, provider: event.provider,
                                  sourceID: event.sourceID, accountID: event.accountID,
                                  sessionID: "same-session", timestamp: event.timestamp,
                                  model: event.model, sourcePath: "same-transcript",
                                  usage: event.usage, pricingContext: event.pricingContext))
    }
    #expect(rollups.values.count == 9)
    #expect(abs(UsageAggregator.summarize(rollups.values).apiUSD - direct.apiUSD) < 0.000001)

    let url = root.appendingPathComponent("index.sqlite")
    let store = try SQLiteIndexStore(url: url)
    #expect(store.refresh(sources: [source]).warnings.isEmpty)
    try pricingSQL(url, "UPDATE events SET is_subagent = 1, parent_session_id = 'parent'")
    let compact = store.compactSummary()
    let full = store.summary()
    #expect(abs(compact.apiUSD - direct.apiUSD) < 0.000001)
    #expect(abs(full.apiUSD - direct.apiUSD) < 0.000001)
    #expect(abs(full.subagents.reduce(0) { $0 + $1.apiUSD } - direct.apiUSD) < 0.000001)
    #expect(abs(compact.codexCredits - direct.codexCredits) < 0.000001)
}

@Test("Upgrading reparses Astra long-context data but preserves unaffected cached files")
func astraCacheMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try writePricingTranscript(root: root, name: "astra", model: "gpt-6-astra", date: pricingTestDate)
    try writePricingTranscript(root: root, name: "older", model: "gpt-5.5", date: pricingTestDate)
    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let url = root.appendingPathComponent("index.sqlite")
    do {
        let store = try SQLiteIndexStore(url: url)
        #expect(store.refresh(sources: [source]).changedFiles == 2)
    }
    // Reproduce 1.1.2's missing Astra long-context classification.
    try pricingSQL(url, """
        UPDATE events SET long_context_input_tokens = 0, long_context_cached_input_tokens = 0,
                          long_context_output_tokens = 0 WHERE model = 'gpt-6-astra';
        PRAGMA user_version = 6;
        """)
    let migrated = try SQLiteIndexStore(url: url)
    #expect(migrated.events().count == 2)
    let refresh = migrated.refresh(sources: [source])
    #expect(refresh.warnings.isEmpty)
    #expect(refresh.changedFiles == 1)
    let astra = try #require(migrated.events().first { $0.model == "gpt-6-astra" })
    #expect(astra.pricingContext.longContextUsage == astra.usage)
    #expect(abs(migrated.compactSummary().apiUSD - UsageAggregator.summarize(UsageScanner.scan(source: source).events).apiUSD) < 0.000001)
    #expect(migrated.refresh(sources: [source]).changedFiles == 0)
}

@Test("Upgrading splits legacy Codex rollups that cross a new pricing boundary")
func pricingBoundaryCacheMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cutoff = PricingCatalog.solRateChange
    try writePricingTranscript(root: root, name: "boundary", model: "gpt-5.6-sol",
                               date: cutoff.addingTimeInterval(-1))
    let transcript = root.appendingPathComponent("sessions/boundary.jsonl")
    let first = try String(contentsOf: transcript, encoding: .utf8)
    let second = """
    {"timestamp":"2026-08-21T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":2000000,"output_tokens":2000000}}}}
    """
    try (first + second + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    let source = UsageSource(displayName: "Codex", provider: .codex, rootPath: root.path)
    let url = root.appendingPathComponent("index.sqlite")
    do {
        let store = try SQLiteIndexStore(url: url)
        #expect(store.refresh(sources: [source]).changedFiles == 1)
    }
    // Simulate the old day-only aggregate that combined both rate periods.
    try pricingSQL(url, """
        DELETE FROM events WHERE timestamp >= \(cutoff.timeIntervalSince1970);
        UPDATE events SET id = 'rollup:legacy-rate-boundary', event_count = 2,
                          input_tokens = 2000000, cached_input_tokens = 2000000,
                          output_tokens = 2000000;
        UPDATE source_config SET storage_mode = 'rollup';
        PRAGMA user_version = 6;
        """)
    let migrated = try SQLiteIndexStore(url: url)
    #expect(migrated.events().count == 1) // Retained until atomic replacement.
    let result = migrated.refresh(sources: [source])
    #expect(result.warnings.isEmpty)
    #expect(result.changedFiles == 1)
    #expect(migrated.events().count == 2)
    #expect(migrated.events().allSatisfy { $0.id.hasPrefix("rollup-v2:") })
    #expect(abs(migrated.compactSummary().apiUSD - 59.9) < 0.000001)
    #expect(migrated.refresh(sources: [source]).changedFiles == 0)
}

private func writePricingTranscript(root: URL, name: String, model: String, date: Date) throws {
    let directory = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: date)
    // Summary fixtures use one million of each token class. Only Astra includes
    // explicit per-request counters; cumulative totals alone must not trigger
    // the long-context premium.
    let lines = """
    {"type":"turn_context","payload":{"model":"\(model)"}}
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000000,"cached_input_tokens":1000000,"output_tokens":1000000}\(model == "gpt-6-astra" ? ",\"last_token_usage\":{\"input_tokens\":2000000,\"cached_input_tokens\":1000000,\"output_tokens\":1000000}" : "")}}}
    """
    try (lines + "\n").write(to: directory.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
}

private func pricingSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "PricingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
