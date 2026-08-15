import Foundation
import Darwin
import SQLite3

public struct RefreshResult: Sendable {
    public var changedFiles: Int = 0
    public var failedFiles: Int = 0
    public var removedFiles: Int = 0
    public var metadataChanged: Bool = false
    public var metadataUpdatedEvents: Int = 0
    public var staleSourceIDs: Set<String> = []
    public var bytesRead: Int64 = 0
    public var warnings: [String] = []
    public var duration: TimeInterval = 0
    public var isProvisional: Bool = false
    public var didReachTimeLimit: Bool = false
}

private final class ParallelScanResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanResult?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func store(_ value: ScanResult, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func value(at index: Int) -> ScanResult {
        lock.lock()
        defer { lock.unlock() }
        return values[index] ?? ScanResult(warnings: ["Parallel scan did not return a result"])
    }
}

/// App-owned SQLite cache. Provider files are opened read-only and are never modified.
public final class SQLiteIndexStore: @unchecked Sendable {
    private static let rollupThresholdBytes: Int64 = 128 * 1024 * 1024
    private static let claudeMessageStorageMode = "claude-messages-v1"
    private static let deduplicatedEventsCTE = """
        ranked_claude_events AS (
            SELECT events.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY source_id, provider_event_id, is_subagent
                       ORDER BY timestamp DESC, byte_offset DESC, rowid ASC
                   ) AS dedupe_rank
            FROM events
            WHERE provider = 'Claude Code' AND provider_event_id IS NOT NULL
        ),
        deduplicated_events AS (
            SELECT events.*, 1 AS dedupe_rank
            FROM events
            WHERE provider != 'Claude Code'
            UNION ALL
            SELECT * FROM ranked_claude_events WHERE dedupe_rank = 1
        )
        """
    private var database: OpaquePointer?
    private let lock = NSLock()

    public static func defaultURL() throws -> URL {
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_INDEX_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
#endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let base = appSupport.appendingPathComponent("AIUsageTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Cache generations use distinct files. An old multi-million-row
        // detailed index must never be migrated synchronously on app launch;
        // rebuilding this bounded overview cache is both faster and recoverable.
        return base.appendingPathComponent("overview-v2.sqlite")
    }

    /// Read just the headline counters from any compatible app-owned index.
    /// This opens SQLite read-only and performs no migration, checkpoint, or
    /// schema work, so an older cache can seed the first frame immediately.
    public static func readOnlyOverview(at url: URL, sourceIDs: Set<String>, timeLimit: TimeInterval = 0.25) -> UsageSummary? {
        guard !sourceIDs.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        final class Deadline: @unchecked Sendable {
            let uptimeNanoseconds: UInt64
            init(after interval: TimeInterval) {
                uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.01, interval) * 1_000_000_000)
            }
        }
        let deadline = Unmanaged.passRetained(Deadline(after: timeLimit))
        let progress: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
            guard let context else { return 1 }
            let deadline = Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue()
            return DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds ? 1 : 0
        }
        sqlite3_progress_handler(database, 4_096, progress, deadline.toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            deadline.release()
        }
        let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
        let claudeSourceIDs = sourceIDs.filter { $0.hasPrefix("\(Provider.claude.rawValue.lowercased()):") }
        if !claudeSourceIDs.isEmpty {
            let modePlaceholders = claudeSourceIDs.map { _ in "?" }.joined(separator: ",")
            let modeSQL = "SELECT COUNT(*) FROM source_config WHERE source_id IN (\(modePlaceholders)) AND storage_mode = ?"
            var modeStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, modeSQL, -1, &modeStatement, nil) == SQLITE_OK,
                  let modeStatement else { return nil }
            defer { sqlite3_finalize(modeStatement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, sourceID) in claudeSourceIDs.sorted().enumerated() {
                sqlite3_bind_text(modeStatement, Int32(offset + 1), sourceID, -1, transient)
            }
            sqlite3_bind_text(modeStatement, Int32(claudeSourceIDs.count + 1), Self.claudeMessageStorageMode, -1, transient)
            guard sqlite3_step(modeStatement) == SQLITE_ROW,
                  Int(sqlite3_column_int(modeStatement, 0)) == claudeSourceIDs.count else { return nil }
        }
        let table = claudeSourceIDs.isEmpty ? "events" : "deduplicated_events"
        let withClause = claudeSourceIDs.isEmpty ? "" : "WITH \(Self.deduplicatedEventsCTE)"
        let sql = """
            \(withClause)
            SELECT
                COALESCE(SUM(event_count), 0),
                COALESCE(SUM(CASE WHEN is_subagent = 1 THEN event_count ELSE 0 END), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(cache_write_5m_tokens), 0),
                COALESCE(SUM(cache_write_1h_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(reasoning_output_tokens), 0),
                COUNT(DISTINCT provider || char(31) || source_id || char(31) || session_id)
            FROM \(table) WHERE source_id IN (\(placeholders))
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, sourceID) in sourceIDs.sorted().enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), sourceID, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        var overview = UsageSummary()
        overview.eventCount = Int(sqlite3_column_int64(statement, 0))
        overview.subagentEventCount = Int(sqlite3_column_int64(statement, 1))
        overview.usage = TokenUsage(
            inputTokens: sqlite3_column_int64(statement, 2),
            cachedInputTokens: sqlite3_column_int64(statement, 3),
            cacheWrite5mInputTokens: sqlite3_column_int64(statement, 4),
            cacheWrite1hInputTokens: sqlite3_column_int64(statement, 5),
            outputTokens: sqlite3_column_int64(statement, 6),
            reasoningOutputTokens: sqlite3_column_int64(statement, 7)
        )
        overview.sessionCount = Int(sqlite3_column_int64(statement, 8))
        overview.isProvisional = true
        return overview.eventCount > 0 ? overview : nil
    }

    public init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if db != nil { sqlite3_close(db) }
            throw NSError(domain: "AIUsageTracker.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        database = db
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA busy_timeout=5000")
        try exec("CREATE TABLE IF NOT EXISTS files (source_id TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL, file_identity TEXT NOT NULL DEFAULT '', parsed_offset INTEGER NOT NULL DEFAULT 0, prefix_hash INTEGER NOT NULL DEFAULT 0, append_guard_hash INTEGER NOT NULL DEFAULT 0, requires_reconciliation INTEGER NOT NULL DEFAULT 0, last_input INTEGER NOT NULL DEFAULT 0, last_cached INTEGER NOT NULL DEFAULT 0, last_cache_5m INTEGER NOT NULL DEFAULT 0, last_cache_1h INTEGER NOT NULL DEFAULT 0, last_output INTEGER NOT NULL DEFAULT 0, last_reasoning INTEGER NOT NULL DEFAULT 0, diagnostic_duplicate INTEGER NOT NULL DEFAULT 0, diagnostic_stale INTEGER NOT NULL DEFAULT 0, diagnostic_inherited INTEGER NOT NULL DEFAULT 0, diagnostic_reset INTEGER NOT NULL DEFAULT 0, last_model TEXT, PRIMARY KEY(source_id, path))")
        try ensureColumn(table: "files", name: "parsed_offset", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "file_identity", definition: "TEXT NOT NULL DEFAULT ''")
        try ensureColumn(table: "files", name: "append_guard_hash", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "requires_reconciliation", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "prefix_hash", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_input", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_cached", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_cache_5m", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_cache_1h", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_output", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_reasoning", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "diagnostic_duplicate", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "diagnostic_stale", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "diagnostic_inherited", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "diagnostic_reset", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "files", name: "last_model", definition: "TEXT")
        try exec("CREATE TABLE IF NOT EXISTS source_metadata (source_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, provider_event_id TEXT, provider TEXT NOT NULL, source_id TEXT NOT NULL, account_id TEXT NOT NULL, current_auth_account_id TEXT, attribution_confidence TEXT NOT NULL DEFAULT 'source-only', attribution_basis TEXT NOT NULL DEFAULT 'none', session_id TEXT NOT NULL, parent_session_id TEXT, timestamp REAL NOT NULL, model TEXT NOT NULL, source_path TEXT NOT NULL, byte_offset INTEGER NOT NULL, is_subagent INTEGER NOT NULL, event_count INTEGER NOT NULL DEFAULT 1, input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL, cache_write_5m_tokens INTEGER NOT NULL, cache_write_1h_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL, long_context_input_tokens INTEGER NOT NULL DEFAULT 0, long_context_cached_input_tokens INTEGER NOT NULL DEFAULT 0, long_context_cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0, long_context_cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0, long_context_output_tokens INTEGER NOT NULL DEFAULT 0, long_context_reasoning_output_tokens INTEGER NOT NULL DEFAULT 0)")
        try ensureColumn(table: "events", name: "provider_event_id", definition: "TEXT")
        try ensureColumn(table: "events", name: "attribution_confidence", definition: "TEXT NOT NULL DEFAULT 'source-only'")
        try ensureColumn(table: "events", name: "attribution_basis", definition: "TEXT NOT NULL DEFAULT 'none'")
        try ensureColumn(table: "events", name: "current_auth_account_id", definition: "TEXT")
        try ensureColumn(table: "events", name: "event_count", definition: "INTEGER NOT NULL DEFAULT 1")
        try ensureColumn(table: "events", name: "long_context_input_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "events", name: "long_context_cached_input_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "events", name: "long_context_cache_write_5m_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "events", name: "long_context_cache_write_1h_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "events", name: "long_context_output_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "events", name: "long_context_reasoning_output_tokens", definition: "INTEGER NOT NULL DEFAULT 0")
        try exec("CREATE TABLE IF NOT EXISTS source_config (source_id TEXT PRIMARY KEY, storage_mode TEXT NOT NULL DEFAULT 'events')")
        try exec("CREATE INDEX IF NOT EXISTS events_time_idx ON events(timestamp)")
        try exec("CREATE INDEX IF NOT EXISTS events_source_time_idx ON events(source_id, timestamp)")
        try exec("CREATE INDEX IF NOT EXISTS events_source_path_idx ON events(source_id, source_path)")
        try exec("CREATE INDEX IF NOT EXISTS events_source_session_idx ON events(source_id, session_id, is_subagent, parent_session_id)")
        try exec("CREATE INDEX IF NOT EXISTS events_provider_identity_idx ON events(provider, source_id, provider_event_id)")
        try exec("CREATE INDEX IF NOT EXISTS events_claude_dedupe_idx ON events(source_id, provider_event_id, is_subagent, timestamp DESC, byte_offset DESC) WHERE provider = 'Claude Code' AND provider_event_id IS NOT NULL")
        try migrateAccountingGeneration()
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Refresh the app-owned index without writing to provider roots.
    ///
    /// A full reconciliation reparses changed cursors that were advanced by
    /// the fast append path. This keeps live updates cheap while giving the
    /// periodic fallback a deterministic way to repair interior edits.
    public func refresh(sources: [UsageSource], changedPaths: Set<String>? = nil, fullReconciliation: Bool = false, maxFiles: Int? = nil, bootstrapOnly: Bool = false, snapshotOnly: Bool = false, timeLimit: TimeInterval? = nil) -> RefreshResult {
        lock.lock()
        defer { lock.unlock() }
        let started = Date()
        let deadline = timeLimit.map { started.addingTimeInterval(max(0.1, $0)) }
        var result = RefreshResult()
        var bulkIndexesDropped = false
        func timeLimitReached() -> Bool {
            guard let deadline, Date() >= deadline else { return false }
            result.didReachTimeLimit = true
            result.isProvisional = true
            return true
        }
        for source in sources where source.enabled {
            if timeLimitReached() { break }
            let existing = fileCursors(sourceID: source.id)
            let indexedPaths = eventPaths(sourceID: source.id)
            let knownPaths = Set(existing.keys).union(indexedPaths)
            guard let selection = relevantFiles(for: source, changedPaths: changedPaths, knownPaths: knownPaths) else {
                let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                let location = source.provider == .codex ? "Codex transcript directories under \(root.path)" : root.appendingPathComponent("projects", isDirectory: true).path
                result.warnings.append("Could not enumerate \(location); cached data was retained")
                result.staleSourceIDs.insert(source.id)
                continue
            }
            let files = maxFiles.map { Array(selection.files.prefix($0)) } ?? selection.files
            let sourceHasExistingData = !existing.isEmpty || !indexedPaths.isEmpty
            let storedStorageMode = sourceStorageMode(sourceID: source.id)
            if source.provider == .claude,
               sourceHasExistingData,
               storedStorageMode != Self.claudeMessageStorageMode {
                guard maxFiles == nil,
                      let completeSelection = relevantFiles(for: source, changedPaths: nil, knownPaths: knownPaths) else {
                    result.warnings.append("Could not enumerate all Claude transcripts; the legacy aggregate was retained")
                    result.staleSourceIDs.insert(source.id)
                    continue
                }
                _ = migrateLegacyClaudeSource(
                    source: source,
                    files: completeSelection.files,
                    deadline: deadline,
                    result: &result
                )
                continue
            }
            // Snapshots seed a brand-new Codex source quickly. Once an accurate
            // rollup exists, a routine startup refresh must preserve it instead
            // of converting the ledger back into one cumulative row per thread.
            let useSnapshots = source.provider == .codex
                && (storedStorageMode == nil || storedStorageMode == "snapshot")
                && (snapshotOnly || (bootstrapOnly && !sourceHasExistingData))
            let initialImportBytes = useSnapshots ? 0 : files.reduce(Int64(0)) { total, file in
                total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let convertFromSnapshots = source.provider == .codex && !useSnapshots && storedStorageMode == "snapshot"
            let useRollups = source.provider != .claude && !useSnapshots && (storedStorageMode == "rollup" || ((convertFromSnapshots || !sourceHasExistingData) && initialImportBytes >= Self.rollupThresholdBytes))
            if storedStorageMode == nil || (source.provider == .claude && !sourceHasExistingData && storedStorageMode != Self.claudeMessageStorageMode) {
                let mode = source.provider == .claude
                    ? Self.claudeMessageStorageMode
                    : useSnapshots ? "snapshot" : useRollups ? "rollup" : "events"
                try? setSourceStorageMode(sourceID: source.id, mode: mode)
            }
            if useSnapshots {
                var metadata: CodexMetadata?
                let convertToSnapshots = storedStorageMode != "snapshot"
                let explicitlyChangedFiles = Set((changedPaths ?? []).compactMap { path in
                    let url = URL(fileURLWithPath: path)
                    return url.pathExtension == "jsonl" ? Self.normalizedPath(path) : nil
                })
                struct PendingSnapshot {
                    let url: URL
                    let size: Int64
                    let modified: TimeInterval
                    let fileIdentity: String
                    let prefixHash: Int64?
                    let scan: ScanResult
                }
                var pendingSnapshots: [PendingSnapshot] = []
                pendingSnapshots.reserveCapacity(convertToSnapshots ? files.count : min(files.count, 16))
                var seen = Set<String>()
                for file in files {
                    if timeLimitReached() {
                        result.staleSourceIDs.insert(source.id)
                        break
                    }
                    seen.insert(file.path)
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = Int64(values?.fileSize ?? 0)
                    let modified = (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
                    let fileIdentity = Self.fileIdentity(at: file)
                    let old = existing[file.path]
                    let explicitlyChanged = explicitlyChangedFiles.contains(Self.normalizedPath(file.path))
                    let fileChanged = convertToSnapshots || explicitlyChanged || old == nil || old?.size != size || old?.modified != modified || old?.fileIdentity != fileIdentity
                    guard fileChanged else { continue }
                    if metadata == nil {
                        metadata = CodexMetadata(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
                    }
                    let quick = CodexScanner.quickScanFile(source: source, url: file, metadata: metadata!, includeInheritedUsage: true)
                    result.warnings.append(contentsOf: quick.warnings)
                    pendingSnapshots.append(PendingSnapshot(url: file, size: size, modified: modified, fileIdentity: fileIdentity, prefixHash: Self.prefixHash(at: file), scan: quick))
                }

                func write(_ snapshot: PendingSnapshot) throws {
                    try deleteEvents(sourceID: source.id, path: snapshot.url.path)
                    try insert(snapshot.scan.events, upsert: false)
                    try upsertFile(
                        sourceID: source.id,
                        path: snapshot.url.path,
                        size: snapshot.size,
                        modified: snapshot.modified,
                        fileIdentity: snapshot.fileIdentity,
                        parsedOffset: snapshot.size,
                        prefixHash: snapshot.prefixHash,
                        appendGuardHash: 0,
                        requiresReconciliation: false,
                        snapshot: snapshot.scan.lastCodexSnapshot,
                        model: snapshot.scan.lastCodexModel,
                        accounting: snapshot.scan.accounting
                    )
                }

                if convertToSnapshots {
                    // A legacy detailed cache is disposable. Convert it in one
                    // atomic generation instead of millions of indexed deletes
                    // spread across one transaction per transcript.
                    if result.didReachTimeLimit && sourceHasExistingData {
                        result.staleSourceIDs.insert(source.id)
                    } else {
                        do {
                            try transaction {
                                try deleteAllEvents(sourceID: source.id)
                                try deleteAllFiles(sourceID: source.id)
                                for snapshot in pendingSnapshots { try write(snapshot) }
                            }
                            result.changedFiles += pendingSnapshots.count
                            result.bytesRead += pendingSnapshots.reduce(0) { $0 + $1.scan.bytesRead }
                            try? setSourceStorageMode(sourceID: source.id, mode: "snapshot")
                        } catch {
                            result.failedFiles += pendingSnapshots.count
                            result.staleSourceIDs.insert(source.id)
                            result.warnings.append("Creating bounded thread snapshots: \(error.localizedDescription)")
                        }
                    }
                } else {
                    for snapshot in pendingSnapshots {
                        do {
                            try transaction { try write(snapshot) }
                            result.changedFiles += 1
                            result.bytesRead += snapshot.scan.bytesRead
                        } catch {
                            result.failedFiles += 1
                            result.staleSourceIDs.insert(source.id)
                            result.warnings.append("Updating thread snapshot for \(snapshot.url.path): \(error.localizedDescription)")
                        }
                    }
                }
                let staleCandidates = result.didReachTimeLimit ? [] : selection.reconcileScopes.map { scopes in
                    knownPaths.filter { path in scopes.contains { scope in Self.path(path, isWithin: scope) } }
                } ?? knownPaths
                for stalePath in staleCandidates where !seen.contains(stalePath) && !FileManager.default.fileExists(atPath: stalePath) {
                    do {
                        try transaction {
                            try deleteEvents(sourceID: source.id, path: stalePath)
                            try deleteFile(sourceID: source.id, path: stalePath)
                        }
                        result.removedFiles += 1
                    } catch {
                        result.warnings.append("Removing stale thread snapshot \(stalePath): \(error.localizedDescription)")
                        result.staleSourceIDs.insert(source.id)
                    }
                }
                result.isProvisional = true
                continue
            }
            if !sourceHasExistingData {
                // This is an app-owned, rebuildable cache. Relaxing SQLite's
                // fsync policy for the initial bulk import avoids paying a
                // durable journal flush for every large batch; normal safety
                // is restored before refresh returns.
                try? exec("PRAGMA synchronous=OFF")
                try? exec("PRAGMA temp_store=MEMORY")
                try? exec("PRAGMA cache_size=-262144")
                try? exec("DROP INDEX IF EXISTS events_time_idx")
                try? exec("DROP INDEX IF EXISTS events_source_path_idx")
                try? exec("DROP INDEX IF EXISTS events_source_time_idx")
                try? exec("DROP INDEX IF EXISTS events_source_session_idx")
                try? exec("DROP INDEX IF EXISTS events_source_parent_session_idx")
                bulkIndexesDropped = true
            }
            let storedFingerprint = sourceMetadata(sourceID: source.id)
            let canSkipMetadataWalk = changedPaths != nil && storedFingerprint != nil && (changedPaths ?? []).allSatisfy { Self.isTranscriptPath($0, source: source) }
            let fingerprint = canSkipMetadataWalk ? storedFingerprint : metadataFingerprint(for: source)
            guard let fingerprint else {
                result.warnings.append("Could not fingerprint metadata for \(source.rootPath); cached data was retained")
                result.staleSourceIDs.insert(source.id)
                continue
            }
            let metadataChanged = storedFingerprint != fingerprint
            result.metadataChanged = result.metadataChanged || metadataChanged
            // Loading state SQLite/telemetry can be relatively expensive. Do
            // it only if at least one transcript actually needs parsing.
            var codexMetadata: CodexMetadata?
            var claudeResolver: ClaudeAccountResolver?
            var seen = Set<String>()
            struct PendingFile {
                let url: URL
                let events: [UsageEvent]
                let warnings: [String]
                let bytesRead: Int64
                let endOffset: Int64?
                let lastCodexSnapshot: [String: Int64]?
                let lastCodexModel: String?
                let isAppend: Bool
                let upsertEvents: Bool
                let size: Int64
                let modified: TimeInterval
                let fileIdentity: String
                let appendGuardHash: Int64
                let requiresReconciliation: Bool
                let accounting: AccountingDiagnostics
            }
            var pendingFiles: [PendingFile] = []
            pendingFiles.reserveCapacity(128)
            var pendingEventCount = 0
            var pendingBytes: Int64 = 0
            struct ScanWork {
                let url: URL
                let isAppend: Bool
                let size: Int64
                let modified: TimeInterval
                let fileIdentity: String
                let appendGuardHash: Int64
                let requiresReconciliation: Bool
                let previousAccounting: AccountingDiagnostics
                let startOffset: Int64
                let previousSnapshot: [String: Int64]?
                let previousModel: String?
                let upsertEvents: Bool
            }
            var scanWorks: [ScanWork] = []
            let budget = IndexWorkBudget.interactive
            let explicitlyChangedFiles = Set((changedPaths ?? []).compactMap { path in
                let url = URL(fileURLWithPath: path)
                return url.pathExtension == "jsonl" ? Self.normalizedPath(path) : nil
            })

            func flushPendingFiles() throws {
                guard !pendingFiles.isEmpty else { return }
                // Each bounded batch is atomic. Keeping batches bounded avoids
                // holding a large parsed transcript set in memory or blocking
                // summary readers for the entire source import.
                try transaction {
                    for pending in pendingFiles {
                        if pending.warnings.isEmpty {
                            // A new source has no prior events, so avoid a
                            // full-table delete for every file during bulk
                            // import. Existing sources still delete before a
                            // full reparse so atomic rewrites remain exact.
                            if !pending.isAppend && pending.upsertEvents { try deleteEvents(sourceID: source.id, path: pending.url.path) }
                            try insert(pending.events, upsert: pending.upsertEvents, accumulate: useRollups && pending.isAppend)
                            try upsertFile(sourceID: source.id, path: pending.url.path, size: pending.size, modified: pending.modified, fileIdentity: pending.fileIdentity, parsedOffset: pending.endOffset ?? pending.size, prefixHash: Self.prefixHash(at: pending.url), appendGuardHash: pending.appendGuardHash, requiresReconciliation: pending.requiresReconciliation, snapshot: pending.lastCodexSnapshot, model: pending.lastCodexModel, accounting: pending.accounting)
                        } else {
                            // Keep the last known-good events. Removing only
                            // the cursor makes the file retryable on the next
                            // refresh without exposing a partial scan.
                            try deleteFile(sourceID: source.id, path: pending.url.path)
                        }
                    }
                }
                pendingFiles.removeAll(keepingCapacity: true)
                pendingEventCount = 0
                pendingBytes = 0
            }

            func scanAndQueue(_ works: [ScanWork]) {
                guard !works.isEmpty else { return }
                if source.provider == .codex, codexMetadata == nil {
                    codexMetadata = CodexMetadata(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
                } else if source.provider == .claude, claudeResolver == nil {
                    claudeResolver = ClaudeAccountResolver(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
                }
                let codex = codexMetadata
                let claude = claudeResolver
                let results = ParallelScanResults(count: works.count)
                DispatchQueue.global(qos: .userInitiated).sync {
                    DispatchQueue.concurrentPerform(iterations: works.count) { index in
                        let work = works[index]
                        let scan = autoreleasepool { () -> ScanResult in
                            switch source.provider {
                            case .codex:
                                return CodexScanner.scanFile(source: source, url: work.url, interval: nil, metadata: codex, startOffset: work.startOffset, previousSnapshot: work.previousSnapshot, previousModel: work.previousModel, compact: useRollups)
                            case .claude:
                                return ClaudeCodeScanner.scanFile(source: source, url: work.url, interval: nil, resolver: claude, startOffset: work.startOffset, compact: useRollups)
                            }
                        }
                        results.store(scan, at: index)
                    }
                }
                for (index, work) in works.enumerated() {
                    let scan = results.value(at: index)
                    let events = scan.events
                    let parsedOffset = scan.endOffset ?? work.size
                    let appendGuardHash = Self.appendGuardHash(at: work.url, endingAt: parsedOffset) ?? 0
                    let accounting = work.isAppend ? work.previousAccounting + scan.accounting : scan.accounting
                    pendingFiles.append(PendingFile(url: work.url, events: events, warnings: scan.warnings, bytesRead: scan.bytesRead, endOffset: scan.endOffset, lastCodexSnapshot: scan.lastCodexSnapshot, lastCodexModel: scan.lastCodexModel, isAppend: work.isAppend, upsertEvents: work.upsertEvents, size: work.size, modified: work.modified, fileIdentity: work.fileIdentity, appendGuardHash: appendGuardHash, requiresReconciliation: work.requiresReconciliation, accounting: accounting))
                    pendingEventCount += events.count
                    pendingBytes += scan.bytesRead
                    result.changedFiles += 1
                    result.bytesRead += scan.bytesRead
                    result.warnings.append(contentsOf: scan.warnings)
                    if !scan.warnings.isEmpty { result.staleSourceIDs.insert(source.id) }
                    if pendingFiles.count >= budget.maxPendingFiles || pendingEventCount >= budget.maxPendingEvents || pendingBytes >= budget.maxPendingBytes {
                        do {
                            try flushPendingFiles()
                        } catch {
                            result.warnings.append("Writing indexed files for \(source.rootPath): \(error.localizedDescription)")
                            result.failedFiles += pendingFiles.count
                            pendingFiles.removeAll(keepingCapacity: true)
                            pendingEventCount = 0
                            pendingBytes = 0
                        }
                    }
                }
            }

            for file in files {
                if timeLimitReached() {
                    result.staleSourceIDs.insert(source.id)
                    break
                }
                let key = file.path
                seen.insert(key)
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
                let fileIdentity = Self.fileIdentity(at: file)
                let old = existing[key]
                let identityNeedsMigration = old?.fileIdentity.isEmpty == true && !fileIdentity.isEmpty
                let identityChanged = old.map { !$0.fileIdentity.isEmpty && $0.fileIdentity != fileIdentity } == true
                // Fast append cursors are deliberately rechecked from offset
                // zero during the periodic full reconciliation. This is the
                // correctness backstop for edits outside bounded hash guards.
                let fullReconciliationNeeded = fullReconciliation && old?.requiresReconciliation == true
                let explicitlyChanged = explicitlyChangedFiles.contains(Self.normalizedPath(key))
                let fileChanged = convertFromSnapshots || explicitlyChanged || old == nil || old?.size != size || old?.modified != modified || identityNeedsMigration || identityChanged || fullReconciliationNeeded
                guard fileChanged else { continue }
                // The persisted identity distinguishes append-only growth from
                // the atomic replacement pattern used by provider writers. The
                // prefix and parsed-tail guards also reject common in-place
                // rewrites; an unavailable identity or guard is never treated
                // as append-only, preserving the safe full-parse path.
                let isAppend = !fullReconciliation && old != nil && !old!.fileIdentity.isEmpty && !fileIdentity.isEmpty && old!.fileIdentity == fileIdentity && size > old!.size && old!.parsedOffset <= old!.size && old!.prefixHash != 0 && Self.prefixHash(at: file) == old!.prefixHash && old!.appendGuardHash != 0 && Self.appendGuardHash(at: file, endingAt: old!.parsedOffset) == old!.appendGuardHash

                scanWorks.append(ScanWork(url: file, isAppend: isAppend, size: size, modified: modified, fileIdentity: fileIdentity, appendGuardHash: 0, requiresReconciliation: isAppend, previousAccounting: isAppend ? old!.accounting : AccountingDiagnostics(), startOffset: isAppend ? old!.parsedOffset : 0, previousSnapshot: isAppend ? old!.snapshot : nil, previousModel: isAppend ? old!.lastModel : nil, upsertEvents: sourceHasExistingData))
                if scanWorks.count >= budget.workerCount {
                    scanAndQueue(scanWorks)
                    scanWorks.removeAll(keepingCapacity: true)
                }
            }
            scanAndQueue(scanWorks)
            scanWorks.removeAll(keepingCapacity: true)
            do {
                try flushPendingFiles()
            } catch {
                result.warnings.append("Writing indexed files for \(source.rootPath): \(error.localizedDescription)")
                result.failedFiles += pendingFiles.count
                result.staleSourceIDs.insert(source.id)
                pendingFiles.removeAll(keepingCapacity: true)
                pendingEventCount = 0
                pendingBytes = 0
            }

            // New imports already attach the metadata available while parsing
            // each transcript. Never materialize and rewrite millions of
            // freshly inserted events just because a provider metadata DB is
            // temporarily locked; a later metadata fingerprint change can
            // enrich them without rereading transcripts.
            let metadataAvailableInline = !sourceHasExistingData && !result.staleSourceIDs.contains(source.id)
            var metadataApplied = !metadataChanged || metadataAvailableInline
            if metadataChanged && !metadataAvailableInline {
                do {
                    switch source.provider {
                    case .codex:
                        if codexMetadata == nil { codexMetadata = CodexMetadata(root: URL(fileURLWithPath: source.rootPath, isDirectory: true)) }
                        guard codexMetadata!.isComplete else { throw MetadataReadError.incomplete }
                        result.metadataUpdatedEvents += try updateStoredCodexMetadata(sourceID: source.id, metadata: codexMetadata!)
                    case .claude:
                        if claudeResolver == nil { claudeResolver = ClaudeAccountResolver(root: URL(fileURLWithPath: source.rootPath, isDirectory: true)) }
                        result.metadataUpdatedEvents += try updateStoredClaudeMetadata(sourceID: source.id, resolver: claudeResolver!)
                    }
                    metadataApplied = true
                } catch {
                    result.warnings.append("Updating metadata for \(source.rootPath): \(error.localizedDescription)")
                }
            }

            let staleCandidates = result.didReachTimeLimit ? [] : selection.reconcileScopes.map { scopes in
                knownPaths.filter { path in scopes.contains { scope in Self.path(path, isWithin: scope) } }
            } ?? knownPaths
            for stalePath in staleCandidates where !seen.contains(stalePath) {
                // DirectoryEnumerator can be incomplete when a nested folder
                // becomes unavailable. Never delete a cached path that still
                // exists but was absent from that walk; retry it next time.
                if FileManager.default.fileExists(atPath: stalePath) {
                    result.warnings.append("Retained \(stalePath); it was not visible in the complete directory walk")
                    continue
                }
                do {
                    try transaction {
                        try deleteEvents(sourceID: source.id, path: stalePath)
                        try deleteFile(sourceID: source.id, path: stalePath)
                    }
                    result.removedFiles += 1
                } catch {
                    result.warnings.append("Removing stale file \(stalePath): \(error.localizedDescription)")
                    result.staleSourceIDs.insert(source.id)
                }
            }
            if metadataApplied {
                do { try upsertSourceMetadata(sourceID: source.id, fingerprint: fingerprint) }
                catch { result.warnings.append("Saving metadata fingerprint: \(error.localizedDescription)") }
            } else {
                result.warnings.append("Metadata fingerprint was not advanced; the source will be retried")
                result.staleSourceIDs.insert(source.id)
            }
            if convertFromSnapshots && !result.didReachTimeLimit && result.failedFiles == 0 {
                try? setSourceStorageMode(sourceID: source.id, mode: useRollups ? "rollup" : "events")
            }
        }
        if bulkIndexesDropped {
            do {
                try exec("CREATE INDEX IF NOT EXISTS events_time_idx ON events(timestamp)")
                try exec("CREATE INDEX IF NOT EXISTS events_source_time_idx ON events(source_id, timestamp)")
                try exec("CREATE INDEX IF NOT EXISTS events_source_path_idx ON events(source_id, source_path)")
                try exec("CREATE INDEX IF NOT EXISTS events_source_session_idx ON events(source_id, session_id, is_subagent, parent_session_id)")
            } catch {
                result.warnings.append("Rebuilding event indexes: \(error.localizedDescription)")
            }
            try? exec("PRAGMA journal_mode=WAL")
            try? exec("PRAGMA synchronous=NORMAL")
        }
        // A fast bootstrap deliberately leaves transcript cursors at zero.
        // Preserve that state across launches and ordinary changed-file polls;
        // otherwise snapshot rows could be mistaken for detailed history.
        if sources.lazy.filter(\.enabled).contains(where: { hasPendingReconciliation(sourceID: $0.id) }) {
            result.isProvisional = true
        }
        if result.didReachTimeLimit {
            result.warnings.append("Refresh stopped at the configured time limit; the last good overview was retained")
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Replace legacy Claude day rollups with provider-message rows in one
    /// atomic generation. Resumed Claude sessions copy prior transcript lines;
    /// keeping the provider message ID lets summary queries count those copies
    /// once while still retaining every source path for deletion/retry safety.
    private func migrateLegacyClaudeSource(
        source: UsageSource,
        files: [URL],
        deadline: Date?,
        result: inout RefreshResult
    ) -> Bool {
        struct MigratedFile {
            let url: URL
            let size: Int64
            let modified: TimeInterval
            let fileIdentity: String
            let prefixHash: Int64?
            let appendGuardHash: Int64
            let scan: ScanResult
        }

        func deadlineReached() -> Bool {
            guard let deadline, Date() >= deadline else { return false }
            result.didReachTimeLimit = true
            result.isProvisional = true
            result.staleSourceIDs.insert(source.id)
            return true
        }

        guard !deadlineReached(),
              let fingerprintBefore = metadataFingerprint(for: source) else {
            result.warnings.append("Could not prepare the Claude aggregate migration; the previous cache was retained")
            result.staleSourceIDs.insert(source.id)
            return false
        }

        let resolver = ClaudeAccountResolver(root: URL(fileURLWithPath: source.rootPath, isDirectory: true))
        let budget = IndexWorkBudget.interactive
        var migrated: [MigratedFile] = []
        migrated.reserveCapacity(files.count)

        for start in stride(from: 0, to: files.count, by: budget.workerCount) {
            if deadlineReached() {
                result.warnings.append("Claude migration stopped at the safety limit; the previous cache was retained")
                return false
            }
            let end = min(files.count, start + budget.workerCount)
            let batch = Array(files[start..<end])
            let scans = ParallelScanResults(count: batch.count)
            DispatchQueue.global(qos: .userInitiated).sync {
                DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                    scans.store(
                        ClaudeCodeScanner.scanFile(
                            source: source,
                            url: batch[index],
                            interval: nil,
                            resolver: resolver,
                            compact: false
                        ),
                        at: index
                    )
                }
            }

            for (index, url) in batch.enumerated() {
                let scan = scans.value(at: index)
                result.bytesRead += scan.bytesRead
                guard scan.warnings.isEmpty else {
                    result.warnings.append(contentsOf: scan.warnings)
                    result.warnings.append("Claude migration retained the previous cache because a transcript was incomplete")
                    result.staleSourceIDs.insert(source.id)
                    return false
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
                guard scan.endOffset == size else {
                    result.warnings.append("Claude transcript changed during migration; the previous cache was retained")
                    result.staleSourceIDs.insert(source.id)
                    return false
                }
                migrated.append(MigratedFile(
                    url: url,
                    size: size,
                    modified: modified,
                    fileIdentity: Self.fileIdentity(at: url),
                    prefixHash: Self.prefixHash(at: url),
                    appendGuardHash: Self.appendGuardHash(at: url, endingAt: size) ?? 0,
                    scan: scan
                ))
            }
        }

        guard !deadlineReached(),
              let fingerprintAfter = metadataFingerprint(for: source),
              fingerprintAfter == fingerprintBefore else {
            result.warnings.append("Claude metadata changed during migration; the previous cache was retained")
            result.staleSourceIDs.insert(source.id)
            return false
        }

        do {
            try transaction {
                try deleteAllEvents(sourceID: source.id)
                try deleteAllFiles(sourceID: source.id)
                for file in migrated {
                    try insert(file.scan.events, upsert: false)
                    try upsertFile(
                        sourceID: source.id,
                        path: file.url.path,
                        size: file.size,
                        modified: file.modified,
                        fileIdentity: file.fileIdentity,
                        parsedOffset: file.scan.endOffset ?? file.size,
                        prefixHash: file.prefixHash,
                        appendGuardHash: file.appendGuardHash,
                        requiresReconciliation: false,
                        snapshot: nil,
                        model: nil,
                        accounting: file.scan.accounting
                    )
                }
                try setSourceStorageMode(sourceID: source.id, mode: Self.claudeMessageStorageMode)
                try upsertSourceMetadata(sourceID: source.id, fingerprint: fingerprintAfter)
            }
            result.changedFiles += migrated.count
            result.metadataChanged = true
            return true
        } catch {
            result.failedFiles += migrated.count
            result.warnings.append("Could not publish the corrected Claude aggregate: \(error.localizedDescription)")
            result.staleSourceIDs.insert(source.id)
            return false
        }
    }

    public func removeSources(_ sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try transaction {
                for sourceID in sourceIDs {
                    try deleteAllEvents(sourceID: sourceID)
                    try deleteAllFiles(sourceID: sourceID)
                    try deleteSourceMetadata(sourceID: sourceID)
                }
            }
        } catch {
            // The dashboard will surface the data again only if the source is
            // re-added; a failed cleanup is kept out of provider files.
        }
    }

    public func events(from start: Date? = nil, to end: Date? = nil, sourceIDs: Set<String>? = nil) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT id, provider_event_id, provider, source_id, account_id, current_auth_account_id, attribution_confidence, attribution_basis, session_id, parent_session_id, timestamp, model, source_path, byte_offset, is_subagent, event_count, input_tokens, cached_input_tokens, cache_write_5m_tokens, cache_write_1h_tokens, output_tokens, reasoning_output_tokens, long_context_input_tokens, long_context_cached_input_tokens, long_context_cache_write_5m_tokens, long_context_cache_write_1h_tokens, long_context_output_tokens, long_context_reasoning_output_tokens FROM events"
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs, !sourceIDs.isEmpty { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if let sourceIDs, sourceIDs.isEmpty { return [] }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " ORDER BY timestamp ASC"
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let start { sqlite3_bind_double(statement, index, start.timeIntervalSince1970); index += 1 }
        if let end { sqlite3_bind_double(statement, index, end.timeIntervalSince1970); index += 1 }
        if let sourceIDs { for sourceID in sourceIDs.sorted() { bind(sourceID, to: statement, at: index); index += 1 } }
        var output: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let provider = Provider(rawValue: text(statement, 2) ?? ""), let sourceID = text(statement, 3), let accountID = text(statement, 4), let sessionID = text(statement, 8), let model = text(statement, 11), let path = text(statement, 12) else { continue }
            let confidence = AttributionConfidence(rawValue: text(statement, 6) ?? "") ?? .sourceOnly
            let basis = AttributionBasis(rawValue: text(statement, 7) ?? "") ?? .none
            let parent = text(statement, 9)
            let usage = TokenUsage(inputTokens: sqlite3_column_int64(statement, 16), cachedInputTokens: sqlite3_column_int64(statement, 17), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 18), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 19), outputTokens: sqlite3_column_int64(statement, 20), reasoningOutputTokens: sqlite3_column_int64(statement, 21))
            let longContextUsage = TokenUsage(inputTokens: sqlite3_column_int64(statement, 22), cachedInputTokens: sqlite3_column_int64(statement, 23), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 24), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 25), outputTokens: sqlite3_column_int64(statement, 26), reasoningOutputTokens: sqlite3_column_int64(statement, 27))
            output.append(UsageEvent(id: id, providerEventID: text(statement, 1), provider: provider, sourceID: sourceID, accountID: accountID, currentAuthAccountID: text(statement, 5), attributionConfidence: confidence, attributionBasis: basis, sessionID: sessionID, parentSessionID: parent, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)), model: model, sourcePath: path, byteOffset: sqlite3_column_int64(statement, 13), isSubagent: sqlite3_column_int(statement, 14) != 0, eventCount: Int(sqlite3_column_int64(statement, 15)), usage: usage, pricingContext: APIPricingContext(longContextUsage: longContextUsage)))
        }
        return output
    }

    /// Load only the information needed for the first visible dashboard frame.
    ///
    /// This intentionally skips model/account/day/subagent materialization and
    /// pricing. Those collections are loaded by the detailed summary after the
    /// overview is already interactive.
    public func overview(from start: Date? = nil, to end: Date? = nil, sourceIDs: Set<String>? = nil) -> UsageSummary {
        lock.lock(); defer { lock.unlock() }
        var overview = UsageSummary()
        if let sourceIDs, sourceIDs.isEmpty { return overview }
        var sql = """
            WITH \(Self.deduplicatedEventsCTE)
            SELECT
                COALESCE(SUM(event_count), 0),
                COALESCE(SUM(CASE WHEN is_subagent = 1 THEN event_count ELSE 0 END), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(cache_write_5m_tokens), 0),
                COALESCE(SUM(cache_write_1h_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(reasoning_output_tokens), 0),
                COUNT(DISTINCT provider || char(31) || source_id || char(31) || session_id)
            FROM deduplicated_events
            """
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        guard let statement = prepare(sql) else { return overview }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        if let start { sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970); bindIndex += 1 }
        if let end { sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970); bindIndex += 1 }
        if let sourceIDs {
            for sourceID in sourceIDs.sorted() {
                bind(sourceID, to: statement, at: bindIndex)
                bindIndex += 1
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return overview }
        overview.eventCount = Int(sqlite3_column_int64(statement, 0))
        overview.subagentEventCount = Int(sqlite3_column_int64(statement, 1))
        overview.usage = TokenUsage(
            inputTokens: sqlite3_column_int64(statement, 2),
            cachedInputTokens: sqlite3_column_int64(statement, 3),
            cacheWrite5mInputTokens: sqlite3_column_int64(statement, 4),
            cacheWrite1hInputTokens: sqlite3_column_int64(statement, 5),
            outputTokens: sqlite3_column_int64(statement, 6),
            reasoningOutputTokens: sqlite3_column_int64(statement, 7)
        )
        overview.sessionCount = Int(sqlite3_column_int64(statement, 8))
        overview.accounting = accountingDiagnostics(sourceIDs: sourceIDs)
        return overview
    }

    /// Aggregate the exact data shown by the menu-bar panel: priced totals and
    /// one row per provider. This avoids constructing the former dashboard's
    /// model, account, day, and subagent collections every time the app opens.
    /// Earliest indexed event timestamp for the given sources. A single
    /// index-backed scalar read used to span "all time" in the UI; it never
    /// materializes rows.
    public func earliestEventTimestamp(sourceIDs: Set<String>? = nil) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let sourceIDs, sourceIDs.isEmpty { return nil }
        var sql = "SELECT MIN(timestamp) FROM events"
        if let sourceIDs {
            sql += " WHERE source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))"
        }
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        if let sourceIDs {
            var bindIndex: Int32 = 1
            for sourceID in sourceIDs.sorted() {
                bind(sourceID, to: statement, at: bindIndex)
                bindIndex += 1
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func compactSummary(from start: Date? = nil, to end: Date? = nil, sourceIDs: Set<String>? = nil) -> UsageSummary {
        lock.lock(); defer { lock.unlock() }
        var summary = UsageSummary()
        if let sourceIDs, sourceIDs.isEmpty { return summary }

        let cutoff = PricingCatalog.sonnet5RateChange.timeIntervalSince1970
        let pricingPeriod = "CASE WHEN provider = 'Claude Code' AND lower(model) LIKE 'claude-sonnet-5%' AND timestamp >= \(cutoff) THEN 1 ELSE 0 END"
        var sql = """
            WITH \(Self.deduplicatedEventsCTE)
            SELECT provider, model, \(pricingPeriod),
                   SUM(event_count),
                   SUM(input_tokens), SUM(cached_input_tokens),
                   SUM(cache_write_5m_tokens), SUM(cache_write_1h_tokens),
                   SUM(output_tokens), SUM(reasoning_output_tokens),
                   SUM(long_context_input_tokens), SUM(long_context_cached_input_tokens),
                   SUM(long_context_cache_write_5m_tokens), SUM(long_context_cache_write_1h_tokens),
                   SUM(long_context_output_tokens), SUM(long_context_reasoning_output_tokens)
            FROM deduplicated_events
            """
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " GROUP BY provider, model, \(pricingPeriod)"

        guard let statement = prepare(sql) else { return summary }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        if let start { sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970); bindIndex += 1 }
        if let end { sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970); bindIndex += 1 }
        if let sourceIDs {
            for sourceID in sourceIDs.sorted() {
                bind(sourceID, to: statement, at: bindIndex)
                bindIndex += 1
            }
        }

        var providers: [Provider: AccountUsageBreakdown] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let provider = Provider(rawValue: text(statement, 0) ?? ""),
                  let model = text(statement, 1) else { continue }
            let count = Int(sqlite3_column_int64(statement, 3))
            let usage = TokenUsage(
                inputTokens: sqlite3_column_int64(statement, 4),
                cachedInputTokens: sqlite3_column_int64(statement, 5),
                cacheWrite5mInputTokens: sqlite3_column_int64(statement, 6),
                cacheWrite1hInputTokens: sqlite3_column_int64(statement, 7),
                outputTokens: sqlite3_column_int64(statement, 8),
                reasoningOutputTokens: sqlite3_column_int64(statement, 9)
            )
            let pricingContext = APIPricingContext(longContextUsage: TokenUsage(
                inputTokens: sqlite3_column_int64(statement, 10),
                cachedInputTokens: sqlite3_column_int64(statement, 11),
                cacheWrite5mInputTokens: sqlite3_column_int64(statement, 12),
                cacheWrite1hInputTokens: sqlite3_column_int64(statement, 13),
                outputTokens: sqlite3_column_int64(statement, 14),
                reasoningOutputTokens: sqlite3_column_int64(statement, 15)
            ))
            let pricedAt = sqlite3_column_int(statement, 2) == 0
                ? PricingCatalog.sonnet5RateChange.addingTimeInterval(-1)
                : PricingCatalog.sonnet5RateChange.addingTimeInterval(1)
            let quote = UsageAccounting.quote(usage: usage, pricingContext: pricingContext, provider: provider, model: model, at: pricedAt)
            UsageAccounting.recordTotals(usage: usage, recordCount: count, quote: quote, in: &summary)

            var row = providers[provider] ?? AccountUsageBreakdown(
                id: "provider:\(provider.rawValue)",
                provider: provider,
                accountID: "provider-total"
            )
            UsageAccounting.record(usage: usage, recordCount: count, quote: quote, in: &row)
            providers[provider] = row
        }
        summary.accounts = Provider.allCases.compactMap { providers[$0] }
        summary.accounting = accountingDiagnostics(sourceIDs: sourceIDs)
        summary.isProvisional = hasSnapshotStorage(sourceIDs: sourceIDs)
        return summary
    }

    /// Aggregate directly in SQLite so the dashboard does not materialize a
    /// potentially multi-million-row event range in memory.
    public func summary(from start: Date? = nil, to end: Date? = nil, sourceIDs: Set<String>? = nil, maxSubagents: Int? = nil) -> UsageSummary {
        lock.lock(); defer { lock.unlock() }
        var summary = UsageSummary()
        if let sourceIDs, sourceIDs.isEmpty { return summary }
        let materialized = materializeSummaryEvents(from: start, to: end, sourceIDs: sourceIDs)
        defer {
            if materialized { try? exec("DROP TABLE IF EXISTS temp.dashboard_summary_events") }
        }
        let eventsTable = materialized ? "dashboard_summary_events" : "deduplicated_events"
        let dedupePrefix = materialized ? "" : "WITH \(Self.deduplicatedEventsCTE) "
        let sonnet5Cutoff = PricingCatalog.sonnet5RateChange.timeIntervalSince1970
        let pricingPeriod = "CASE WHEN provider = 'Claude Code' AND lower(model) LIKE 'claude-sonnet-5%' AND timestamp >= \(sonnet5Cutoff) THEN 1 ELSE 0 END"
        var sql = "\(dedupePrefix)SELECT provider, model, account_id, current_auth_account_id, attribution_confidence, attribution_basis, source_id, strftime('%Y-%m-%d', timestamp, 'unixepoch', 'localtime'), SUM(event_count), SUM(CASE WHEN is_subagent = 1 THEN event_count ELSE 0 END), SUM(input_tokens), SUM(cached_input_tokens), SUM(cache_write_5m_tokens), SUM(cache_write_1h_tokens), SUM(output_tokens), SUM(reasoning_output_tokens), SUM(long_context_input_tokens), SUM(long_context_cached_input_tokens), SUM(long_context_cache_write_5m_tokens), SUM(long_context_cache_write_1h_tokens), SUM(long_context_output_tokens), SUM(long_context_reasoning_output_tokens), \(pricingPeriod) FROM \(eventsTable)"
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " GROUP BY provider, model, account_id, current_auth_account_id, attribution_confidence, attribution_basis, source_id, strftime('%Y-%m-%d', timestamp, 'unixepoch', 'localtime'), \(pricingPeriod)"
        guard let statement = prepare(sql) else { return summary }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        if let start { sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970); bindIndex += 1 }
        if let end { sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970); bindIndex += 1 }
        if let sourceIDs { for sourceID in sourceIDs.sorted() { bind(sourceID, to: statement, at: bindIndex); bindIndex += 1 } }

        var models: [String: ModelUsageBreakdown] = [:]
        var accounts: [String: AccountUsageBreakdown] = [:]
        var days: [String: DailyUsageBreakdown] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let provider = Provider(rawValue: text(statement, 0) ?? ""), let model = text(statement, 1), let accountID = text(statement, 2), let sourceID = text(statement, 6), let day = text(statement, 7) else { continue }
            let currentAuthAccountID = text(statement, 3)
            let confidence = AttributionConfidence(rawValue: text(statement, 4) ?? "") ?? .sourceOnly
            let basis = AttributionBasis(rawValue: text(statement, 5) ?? "") ?? .none
            let count = Int(sqlite3_column_int64(statement, 8))
            let usage = TokenUsage(inputTokens: sqlite3_column_int64(statement, 10), cachedInputTokens: sqlite3_column_int64(statement, 11), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 12), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 13), outputTokens: sqlite3_column_int64(statement, 14), reasoningOutputTokens: sqlite3_column_int64(statement, 15))
            let pricingContext = APIPricingContext(longContextUsage: TokenUsage(inputTokens: sqlite3_column_int64(statement, 16), cachedInputTokens: sqlite3_column_int64(statement, 17), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 18), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 19), outputTokens: sqlite3_column_int64(statement, 20), reasoningOutputTokens: sqlite3_column_int64(statement, 21)))
            let dayStart = DateParsing.parse("\(day)T00:00:00Z") ?? Date()
            let isPostSonnet5Rate = sqlite3_column_int(statement, 22) != 0
            let at = isPostSonnet5Rate ? PricingCatalog.sonnet5RateChange.addingTimeInterval(1) : dayStart
            let quote = UsageAccounting.quote(usage: usage, pricingContext: pricingContext, provider: provider, model: model, at: at)
            UsageAccounting.recordTotals(usage: usage, recordCount: count, subagentRecordCount: Int(sqlite3_column_int64(statement, 9)), attributionConfidence: confidence, quote: quote, in: &summary)

            let modelKey = "\(provider.rawValue):\(model)"
            var modelBreakdown = models[modelKey] ?? ModelUsageBreakdown(id: modelKey)
            UsageAccounting.record(usage: usage, recordCount: count, quote: quote, in: &modelBreakdown)
            models[modelKey] = modelBreakdown

            let accountKey = UsageAggregator.accountKey(provider: provider, accountID: accountID, sourceID: sourceID, currentAuthAccountID: currentAuthAccountID, attributionConfidence: confidence, attributionBasis: basis)
            var accountBreakdown = accounts[accountKey] ?? AccountUsageBreakdown(id: accountKey, provider: provider, sourceID: sourceID, accountID: accountID, currentAuthAccountID: currentAuthAccountID, attributionConfidence: confidence, attributionBasis: basis)
            UsageAccounting.record(usage: usage, recordCount: count, quote: quote, in: &accountBreakdown)
            accounts[accountKey] = accountBreakdown

            var daily = days[day] ?? DailyUsageBreakdown(day: day)
            UsageAccounting.record(usage: usage, quote: quote, in: &daily)
            days[day] = daily
        }
        summary.models = models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        summary.accounts = accounts.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        summary.subagents = subagentBreakdowns(from: start, to: end, sourceIDs: sourceIDs, limit: maxSubagents, eventsTable: eventsTable, includeDedupeCTE: !materialized)
        summary.days = days.values.sorted { $0.day < $1.day }
        summary.sessionCount = distinctSessionCount(start: start, end: end, sourceIDs: sourceIDs, eventsTable: eventsTable, includeDedupeCTE: !materialized)
        summary.accounting = accountingDiagnostics(sourceIDs: sourceIDs)
        summary.isProvisional = hasSnapshotStorage(sourceIDs: sourceIDs)
        return summary
    }

    /// Dashboard details need three aggregate queries over the same corrected
    /// Claude response set. Materialize that set once in connection-local
    /// memory instead of rerunning the windowed provider-ID dedupe three times.
    private func materializeSummaryEvents(from start: Date?, to end: Date?, sourceIDs: Set<String>?) -> Bool {
        try? exec("DROP TABLE IF EXISTS temp.dashboard_summary_events")
        var sql = """
            CREATE TEMP TABLE dashboard_summary_events AS
            WITH \(Self.deduplicatedEventsCTE)
            SELECT provider, source_id, account_id, current_auth_account_id,
                   attribution_confidence, attribution_basis, session_id,
                   parent_session_id, timestamp, model, is_subagent, event_count,
                   input_tokens, cached_input_tokens, cache_write_5m_tokens,
                   cache_write_1h_tokens, output_tokens, reasoning_output_tokens,
                   long_context_input_tokens, long_context_cached_input_tokens,
                   long_context_cache_write_5m_tokens, long_context_cache_write_1h_tokens,
                   long_context_output_tokens, long_context_reasoning_output_tokens
            FROM deduplicated_events
            """
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let start { sqlite3_bind_double(statement, index, start.timeIntervalSince1970); index += 1 }
        if let end { sqlite3_bind_double(statement, index, end.timeIntervalSince1970); index += 1 }
        if let sourceIDs {
            for sourceID in sourceIDs.sorted() {
                bind(sourceID, to: statement, at: index)
                index += 1
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            try? exec("DROP TABLE IF EXISTS temp.dashboard_summary_events")
            return false
        }
        try? exec("CREATE INDEX temp.dashboard_summary_subagent_idx ON dashboard_summary_events(is_subagent, provider, source_id, session_id, parent_session_id)")
        return true
    }

    private func accountingDiagnostics(sourceIDs: Set<String>?) -> AccountingDiagnostics {
        guard let statement = prepare("SELECT COALESCE(SUM(diagnostic_duplicate), 0), COALESCE(SUM(diagnostic_stale), 0), COALESCE(SUM(diagnostic_inherited), 0), COALESCE(SUM(diagnostic_reset), 0) FROM files\(sourcePredicate(sourceIDs))") else { return AccountingDiagnostics() }
        defer { sqlite3_finalize(statement) }
        bindSourceIDs(sourceIDs, to: statement, startingAt: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return AccountingDiagnostics() }
        return AccountingDiagnostics(
            duplicateSnapshots: Int(sqlite3_column_int64(statement, 0)),
            staleSnapshots: Int(sqlite3_column_int64(statement, 1)),
            inheritedBaselines: Int(sqlite3_column_int64(statement, 2)),
            ambiguousResets: Int(sqlite3_column_int64(statement, 3))
        )
    }

    private func subagentBreakdowns(from start: Date?, to end: Date?, sourceIDs: Set<String>?, limit: Int?, eventsTable: String = "deduplicated_events", includeDedupeCTE: Bool = true) -> [SubagentUsageBreakdown] {
        let cutoff = PricingCatalog.sonnet5RateChange.timeIntervalSince1970
        let pricingPeriod = "CASE WHEN e.provider = 'Claude Code' AND lower(e.model) LIKE 'claude-sonnet-5%' AND e.timestamp >= \(cutoff) THEN 1 ELSE 0 END"
        func predicates(alias: String) -> [String] {
            var values = ["\(alias)is_subagent = 1"]
            if start != nil { values.append("\(alias)timestamp >= ?") }
            if end != nil { values.append("\(alias)timestamp < ?") }
            if let sourceIDs { values.append("\(alias)source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
            return values
        }
        let selectedLimit = limit.map { max(1, $0) }
        var sql = includeDedupeCTE ? "WITH \(Self.deduplicatedEventsCTE)" : ""
        if let selectedLimit {
            sql += includeDedupeCTE ? ", ranked AS (" : "WITH ranked AS ("
            sql += """
                    SELECT provider, source_id, session_id, parent_session_id,
                           SUM(input_tokens + cached_input_tokens + cache_write_5m_tokens + cache_write_1h_tokens + output_tokens) AS total_tokens
                    FROM \(eventsTable)
                    WHERE \(predicates(alias: "").joined(separator: " AND "))
                    GROUP BY provider, source_id, session_id, parent_session_id
                    ORDER BY total_tokens DESC
                    LIMIT \(selectedLimit)
                )
                """
        }
        sql += " SELECT e.provider, e.source_id, e.session_id, e.parent_session_id, e.model, SUM(e.event_count), SUM(e.input_tokens), SUM(e.cached_input_tokens), SUM(e.cache_write_5m_tokens), SUM(e.cache_write_1h_tokens), SUM(e.output_tokens), SUM(e.reasoning_output_tokens), SUM(e.long_context_input_tokens), SUM(e.long_context_cached_input_tokens), SUM(e.long_context_cache_write_5m_tokens), SUM(e.long_context_cache_write_1h_tokens), SUM(e.long_context_output_tokens), SUM(e.long_context_reasoning_output_tokens), \(pricingPeriod) FROM \(eventsTable) e"
        if selectedLimit != nil {
            sql += " INNER JOIN ranked r ON r.provider = e.provider AND r.source_id = e.source_id AND r.session_id = e.session_id AND r.parent_session_id IS e.parent_session_id"
        }
        sql += " WHERE " + predicates(alias: "e.").joined(separator: " AND ")
        sql += " GROUP BY e.provider, e.source_id, e.session_id, e.parent_session_id, e.model, \(pricingPeriod)"
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        for _ in 0..<(selectedLimit == nil ? 1 : 2) {
            if let start { sqlite3_bind_double(statement, bindIndex, start.timeIntervalSince1970); bindIndex += 1 }
            if let end { sqlite3_bind_double(statement, bindIndex, end.timeIntervalSince1970); bindIndex += 1 }
            if let sourceIDs { for sourceID in sourceIDs.sorted() { bind(sourceID, to: statement, at: bindIndex); bindIndex += 1 } }
        }

        var result: [String: SubagentUsageBreakdown] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let provider = Provider(rawValue: text(statement, 0) ?? ""), let sourceID = text(statement, 1), let sessionID = text(statement, 2), let model = text(statement, 4) else { continue }
            let parentSessionID = text(statement, 3)
            let count = Int(sqlite3_column_int64(statement, 5))
            let usage = TokenUsage(inputTokens: sqlite3_column_int64(statement, 6), cachedInputTokens: sqlite3_column_int64(statement, 7), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 8), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 9), outputTokens: sqlite3_column_int64(statement, 10), reasoningOutputTokens: sqlite3_column_int64(statement, 11))
            let pricingContext = APIPricingContext(longContextUsage: TokenUsage(inputTokens: sqlite3_column_int64(statement, 12), cachedInputTokens: sqlite3_column_int64(statement, 13), cacheWrite5mInputTokens: sqlite3_column_int64(statement, 14), cacheWrite1hInputTokens: sqlite3_column_int64(statement, 15), outputTokens: sqlite3_column_int64(statement, 16), reasoningOutputTokens: sqlite3_column_int64(statement, 17)))
            let isPostSonnet5Rate = sqlite3_column_int(statement, 18) != 0
            let at = isPostSonnet5Rate ? PricingCatalog.sonnet5RateChange.addingTimeInterval(1) : PricingCatalog.sonnet5RateChange.addingTimeInterval(-1)
            let quote = UsageAccounting.quote(usage: usage, pricingContext: pricingContext, provider: provider, model: model, at: at)
            let key = "\(provider.rawValue):\(sourceID):\(sessionID):parent=\(parentSessionID ?? "none")"
            var breakdown = result[key] ?? SubagentUsageBreakdown(id: key, provider: provider, sourceID: sourceID, sessionID: sessionID, parentSessionID: parentSessionID)
            UsageAccounting.record(usage: usage, recordCount: count, quote: quote, in: &breakdown)
            result[key] = breakdown
        }
        return result.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func distinctSessionCount(start: Date?, end: Date?, sourceIDs: Set<String>?, eventsTable: String = "deduplicated_events", includeDedupeCTE: Bool = true) -> Int {
        // Session IDs are provider-local. Include the provider and source root
        // so separately preserved accounts and same-named sessions do not merge.
        let prefix = includeDedupeCTE ? "WITH \(Self.deduplicatedEventsCTE) " : ""
        var sql = "\(prefix)SELECT COUNT(DISTINCT provider || ':' || source_id || ':' || session_id) FROM \(eventsTable)"
        var predicates: [String] = []
        if start != nil { predicates.append("timestamp >= ?") }
        if end != nil { predicates.append("timestamp < ?") }
        if let sourceIDs { predicates.append("source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))") }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        guard let statement = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let start { sqlite3_bind_double(statement, index, start.timeIntervalSince1970); index += 1 }
        if let end { sqlite3_bind_double(statement, index, end.timeIntervalSince1970); index += 1 }
        if let sourceIDs { for sourceID in sourceIDs.sorted() { bind(sourceID, to: statement, at: index); index += 1 } }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private struct FileCursor {
        let size: Int64
        let modified: TimeInterval
        let fileIdentity: String
        let parsedOffset: Int64
        let prefixHash: Int64
        let appendGuardHash: Int64
        let requiresReconciliation: Bool
        let snapshot: [String: Int64]
        let lastModel: String?
        let accounting: AccountingDiagnostics
    }

    private func fileCursors(sourceID: String) -> [String: FileCursor] {
        guard let statement = prepare("SELECT path, size, modified, file_identity, parsed_offset, prefix_hash, append_guard_hash, requires_reconciliation, last_input, last_cached, last_cache_5m, last_cache_1h, last_output, last_reasoning, diagnostic_duplicate, diagnostic_stale, diagnostic_inherited, diagnostic_reset, last_model FROM files WHERE source_id = ?") else { return [:] }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        var result: [String: FileCursor] = [:]
        while sqlite3_step(statement) == SQLITE_ROW, let path = text(statement, 0) {
            result[path] = FileCursor(size: sqlite3_column_int64(statement, 1), modified: sqlite3_column_double(statement, 2), fileIdentity: text(statement, 3) ?? "", parsedOffset: sqlite3_column_int64(statement, 4), prefixHash: sqlite3_column_int64(statement, 5), appendGuardHash: sqlite3_column_int64(statement, 6), requiresReconciliation: sqlite3_column_int(statement, 7) != 0, snapshot: ["input": sqlite3_column_int64(statement, 8), "cached": sqlite3_column_int64(statement, 9), "cache_5m": sqlite3_column_int64(statement, 10), "cache_1h": sqlite3_column_int64(statement, 11), "output": sqlite3_column_int64(statement, 12), "reasoning": sqlite3_column_int64(statement, 13)], lastModel: text(statement, 18), accounting: AccountingDiagnostics(duplicateSnapshots: Int(sqlite3_column_int64(statement, 14)), staleSnapshots: Int(sqlite3_column_int64(statement, 15)), inheritedBaselines: Int(sqlite3_column_int64(statement, 16)), ambiguousResets: Int(sqlite3_column_int64(statement, 17))))
        }
        return result
    }

    private func sourceMetadata(sourceID: String) -> String? {
        guard let statement = prepare("SELECT fingerprint FROM source_metadata WHERE source_id = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func sourceStorageMode(sourceID: String) -> String? {
        guard let statement = prepare("SELECT storage_mode FROM source_config WHERE source_id = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func hasSnapshotStorage(sourceIDs: Set<String>?) -> Bool {
        var sql = "SELECT 1 FROM source_config WHERE storage_mode = 'snapshot'"
        if let sourceIDs {
            guard !sourceIDs.isEmpty else { return false }
            sql += " AND source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))"
        }
        sql += " LIMIT 1"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bindSourceIDs(sourceIDs, to: statement, startingAt: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func hasPendingReconciliation(sourceID: String) -> Bool {
        guard let statement = prepare("SELECT 1 FROM files WHERE source_id = ? AND requires_reconciliation = 1 LIMIT 1") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func setSourceStorageMode(sourceID: String, mode: String) throws {
        guard let statement = prepare("INSERT OR REPLACE INTO source_config (source_id, storage_mode) VALUES (?, ?)") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        bind(mode, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func upsertSourceMetadata(sourceID: String, fingerprint: String) throws {
        guard let statement = prepare("INSERT OR REPLACE INTO source_metadata (source_id, fingerprint) VALUES (?, ?)") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1); bind(fingerprint, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func metadataFingerprint(for source: UsageSource) -> String? {
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        var urls: [URL] = []
        if source.provider == .codex {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            let stateFiles = children.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            urls.append(contentsOf: stateFiles)
            // URL.appendingPathExtension("-wal") produces `state.sqlite.-wal`.
            // SQLite's sidecars are sibling paths named `state.sqlite-wal` and
            // `state.sqlite-shm`.
            urls.append(contentsOf: stateFiles.flatMap {
                [URL(fileURLWithPath: $0.path + "-wal"), URL(fileURLWithPath: $0.path + "-shm")]
            })
        } else {
            urls.append(root.appendingPathComponent(".claude.json"))
            let telemetry = root.appendingPathComponent("telemetry", isDirectory: true)
            var complete = true
            if (try? telemetry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let enumerator = FileManager.default.enumerator(at: telemetry, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                    complete = false
                    return false
                }) {
                    urls.append(contentsOf: enumerator.compactMap { $0 as? URL })
                }
            }
            guard complete else { return nil }
            let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL.path
            if root.standardizedFileURL.path == defaultRoot {
                let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
                if (try? support.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if let enumerator = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                        complete = false
                        return false
                    }) {
                        urls.append(contentsOf: enumerator.compactMap { $0 as? URL })
                    }
                }
                guard complete else { return nil }
            }
        }
        let fileFingerprint = urls.sorted { $0.path < $1.path }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|")
        // Bump this when event identity or parser semantics change so an
        // existing app-owned cache is rebuilt instead of mixed with old IDs.
        return "usage-core-index-v8|\(fileFingerprint)"
    }

    private struct FileSelection {
        let files: [URL]
        /// Nil means a complete source reconciliation. Non-nil contains the
        /// changed file/directory scopes whose cached paths may be deleted.
        let reconcileScopes: [String]?
    }

    private func relevantFiles(for source: UsageSource, changedPaths: Set<String>?, knownPaths: Set<String>) -> FileSelection? {
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let directories = source.provider == .codex
            ? CodexScanner.transcriptDirectories(root: root)
            : [root.appendingPathComponent("projects", isDirectory: true)].filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !directories.isEmpty else { return nil }

        if let changedPaths {
            let rootPath = Self.normalizedPath(root.path)
            let rawScopes = changedPaths.filter { Self.path($0, isWithin: rootPath) }.map { Self.normalizedPath($0) }
            // FSEvents can report both a directory and the file below it in
            // one batch. Prefer the narrower scopes so a single file change
            // does not accidentally trigger a recursive walk of the archive.
            let scopes = rawScopes.filter { scope in
                !rawScopes.contains { other in other != scope && Self.path(other, isWithin: scope) }
            }
            var files = Set<URL>()
            let transcriptPaths = directories.map { Self.normalizedPath($0.path) }
            func intersectsTranscriptDirectory(_ scope: String) -> Bool {
                transcriptPaths.contains { transcriptPath in
                    Self.path(scope, isWithin: transcriptPath) || Self.path(transcriptPath, isWithin: scope)
                }
            }
            for scope in scopes {
                let url = URL(fileURLWithPath: scope)
                if url.pathExtension == "jsonl" {
                    guard transcriptPaths.contains(where: { Self.path(scope, isWithin: $0) }) else { continue }
                    if FileManager.default.fileExists(atPath: url.path) {
                        let existingPath = knownPaths.first { Self.normalizedPath($0) == scope }
                        files.insert(URL(fileURLWithPath: existingPath ?? scope))
                    }
                    continue
                }
                guard intersectsTranscriptDirectory(scope) else { continue }
                // A root-level event can cover metadata and transcripts at
                // once. Walk only the provider's transcript directories so an
                // unrelated JSONL file cannot be parsed or indexed.
                let walkRoots = directories.filter { directory in
                    Self.path(directory.path, isWithin: scope) || Self.path(scope, isWithin: directory.path)
                }
                for walkRoot in walkRoots {
                    let enumeratorRoot = Self.path(walkRoot.path, isWithin: scope) ? walkRoot : url
                    guard let enumerator = FileManager.default.enumerator(at: enumeratorRoot, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else { continue }
                    files.formUnion(enumerator.compactMap { item -> URL? in
                        guard let url = item as? URL, url.pathExtension == "jsonl",
                              directories.contains(where: { Self.path(url.path, isWithin: $0.path) }) else { return nil }
                        return url
                    })
                }
            }
            // A file deletion does not enumerate, but its cached path remains
            // in knownPaths and is removed by the scoped stale-path pass.
            let transcriptScopes = scopes.filter(intersectsTranscriptDirectory)
            return FileSelection(files: Array(files).sorted { $0.path < $1.path }, reconcileScopes: transcriptScopes)
        }

        var complete = true
        var files: [URL] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                complete = false
                return false
            }) else {
                complete = false
                continue
            }
            files.append(contentsOf: enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
                return url
            })
        }
        return complete ? FileSelection(files: files, reconcileScopes: nil) : nil
    }

    private static func path(_ path: String, isWithin scope: String) -> Bool {
        let normalizedCandidate = normalizedPath(path)
        let normalizedScope = normalizedPath(scope)
        return normalizedCandidate == normalizedScope || normalizedCandidate.hasPrefix(normalizedScope.hasSuffix("/") ? normalizedScope : normalizedScope + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix("/private/var/") ? String(standardized.dropFirst("/private".count)) : standardized
    }

    private static func isTranscriptPath(_ path: String, source: UsageSource) -> Bool {
        let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
        let directories = source.provider == .codex
            ? CodexScanner.transcriptDirectories(root: root)
            : [root.appendingPathComponent("projects", isDirectory: true)]
        return directories.contains { Self.path(path, isWithin: $0.path) }
    }

    private func insert(_ events: [UsageEvent], upsert: Bool, accumulate: Bool = false) throws {
        let columns = "id, provider_event_id, provider, source_id, account_id, current_auth_account_id, attribution_confidence, attribution_basis, session_id, parent_session_id, timestamp, model, source_path, byte_offset, is_subagent, event_count, input_tokens, cached_input_tokens, cache_write_5m_tokens, cache_write_1h_tokens, output_tokens, reasoning_output_tokens, long_context_input_tokens, long_context_cached_input_tokens, long_context_cache_write_5m_tokens, long_context_cache_write_1h_tokens, long_context_output_tokens, long_context_reasoning_output_tokens"
        let upsertSuffix = accumulate
            ? " ON CONFLICT(id) DO UPDATE SET event_count=events.event_count + excluded.event_count, input_tokens=events.input_tokens + excluded.input_tokens, cached_input_tokens=events.cached_input_tokens + excluded.cached_input_tokens, cache_write_5m_tokens=events.cache_write_5m_tokens + excluded.cache_write_5m_tokens, cache_write_1h_tokens=events.cache_write_1h_tokens + excluded.cache_write_1h_tokens, output_tokens=events.output_tokens + excluded.output_tokens, reasoning_output_tokens=events.reasoning_output_tokens + excluded.reasoning_output_tokens, long_context_input_tokens=events.long_context_input_tokens + excluded.long_context_input_tokens, long_context_cached_input_tokens=events.long_context_cached_input_tokens + excluded.long_context_cached_input_tokens, long_context_cache_write_5m_tokens=events.long_context_cache_write_5m_tokens + excluded.long_context_cache_write_5m_tokens, long_context_cache_write_1h_tokens=events.long_context_cache_write_1h_tokens + excluded.long_context_cache_write_1h_tokens, long_context_output_tokens=events.long_context_output_tokens + excluded.long_context_output_tokens, long_context_reasoning_output_tokens=events.long_context_reasoning_output_tokens + excluded.long_context_reasoning_output_tokens"
            : " ON CONFLICT(id) DO UPDATE SET provider_event_id=excluded.provider_event_id, provider=excluded.provider, source_id=excluded.source_id, account_id=excluded.account_id, current_auth_account_id=excluded.current_auth_account_id, attribution_confidence=excluded.attribution_confidence, attribution_basis=excluded.attribution_basis, session_id=excluded.session_id, parent_session_id=excluded.parent_session_id, timestamp=excluded.timestamp, model=excluded.model, source_path=excluded.source_path, byte_offset=excluded.byte_offset, is_subagent=excluded.is_subagent, event_count=excluded.event_count, input_tokens=excluded.input_tokens, cached_input_tokens=excluded.cached_input_tokens, cache_write_5m_tokens=excluded.cache_write_5m_tokens, cache_write_1h_tokens=excluded.cache_write_1h_tokens, output_tokens=excluded.output_tokens, reasoning_output_tokens=excluded.reasoning_output_tokens, long_context_input_tokens=excluded.long_context_input_tokens, long_context_cached_input_tokens=excluded.long_context_cached_input_tokens, long_context_cache_write_5m_tokens=excluded.long_context_cache_write_5m_tokens, long_context_cache_write_1h_tokens=excluded.long_context_cache_write_1h_tokens, long_context_output_tokens=excluded.long_context_output_tokens, long_context_reasoning_output_tokens=excluded.long_context_reasoning_output_tokens WHERE excluded.timestamp >= events.timestamp"
        let row = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        let chunkSize = 1024

        for start in stride(from: 0, to: events.count, by: chunkSize) {
            let end = min(events.count, start + chunkSize)
            let values = Array(repeating: row, count: end - start).joined(separator: ",")
            let suffix = upsert ? upsertSuffix : ""
            let sql = "INSERT INTO events (\(columns)) VALUES \(values)\(suffix)"
            guard let statement = prepare(sql) else { throw databaseError() }
            var parameter: Int32 = 1
            for event in events[start..<end] {
                bind(event.id, to: statement, at: parameter); parameter += 1
                bind(event.providerEventID, to: statement, at: parameter); parameter += 1
                bind(event.provider.rawValue, to: statement, at: parameter); parameter += 1
                bind(event.sourceID, to: statement, at: parameter); parameter += 1
                bind(event.accountID, to: statement, at: parameter); parameter += 1
                bind(event.currentAuthAccountID, to: statement, at: parameter); parameter += 1
                bind(event.attributionConfidence.rawValue, to: statement, at: parameter); parameter += 1
                bind(event.attributionBasis.rawValue, to: statement, at: parameter); parameter += 1
                bind(event.sessionID, to: statement, at: parameter); parameter += 1
                bind(event.parentSessionID, to: statement, at: parameter); parameter += 1
                sqlite3_bind_double(statement, parameter, event.timestamp.timeIntervalSince1970); parameter += 1
                bind(event.model, to: statement, at: parameter); parameter += 1
                bind(event.sourcePath, to: statement, at: parameter); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.byteOffset); parameter += 1
                sqlite3_bind_int(statement, parameter, event.isSubagent ? 1 : 0); parameter += 1
                sqlite3_bind_int64(statement, parameter, Int64(event.eventCount)); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.inputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.cachedInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.cacheWrite5mInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.cacheWrite1hInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.outputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.usage.reasoningOutputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.inputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.cachedInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.cacheWrite5mInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.cacheWrite1hInputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.outputTokens); parameter += 1
                sqlite3_bind_int64(statement, parameter, event.pricingContext.longContextUsage.reasoningOutputTokens); parameter += 1
            }
            let status = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { throw databaseError() }
        }
    }

    private func deleteEvents(sourceID: String, path: String) throws {
        guard let statement = prepare("DELETE FROM events WHERE source_id = ? AND source_path = ?") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1); bind(path, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func eventPaths(sourceID: String) -> Set<String> {
        guard let statement = prepare("SELECT DISTINCT source_path FROM events WHERE source_id = ?") else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let path = text(statement, 0) {
            paths.insert(path)
        }
        return paths
    }

    private struct StoredSessionMetadata {
        let sessionID: String
        let parentSessionID: String?
        let isSubagent: Bool
        let accountID: String
        let attributionConfidence: AttributionConfidence
        let attributionBasis: AttributionBasis
    }

    private func storedSessionMetadata(sourceID: String) -> [StoredSessionMetadata] {
        let sql = "SELECT DISTINCT session_id, parent_session_id, is_subagent, account_id, attribution_confidence, attribution_basis FROM events WHERE source_id = ?"
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        var rows: [StoredSessionMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let session = text(statement, 0) else { continue }
            rows.append(StoredSessionMetadata(
                sessionID: session,
                parentSessionID: text(statement, 1),
                isSubagent: sqlite3_column_int(statement, 2) != 0,
                accountID: text(statement, 3) ?? "unattributed",
                attributionConfidence: AttributionConfidence(rawValue: text(statement, 4) ?? "") ?? .sourceOnly,
                attributionBasis: AttributionBasis(rawValue: text(statement, 5) ?? "") ?? .none
            ))
        }
        return rows
    }

    private func updateStoredCodexMetadata(sourceID: String, metadata: CodexMetadata) throws -> Int {
        let paths = eventPaths(sourceID: sourceID).sorted()
        guard !paths.isEmpty else { return 0 }
        var updated = 0
        try transaction {
            let sql = """
                UPDATE events SET
                    account_id = 'unattributed',
                    current_auth_account_id = ?,
                    attribution_confidence = ?,
                    attribution_basis = ?,
                    session_id = COALESCE(?, session_id),
                    parent_session_id = CASE WHEN ? = 1 THEN ? ELSE parent_session_id END,
                    model = CASE
                        WHEN model = 'unknown' THEN COALESCE(?, model)
                        ELSE model
                    END,
                    is_subagent = CASE WHEN ? = 1 THEN ? ELSE is_subagent END
                WHERE source_id = ? AND source_path = ?
                """
            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            for path in paths {
                let thread = metadata.exactThread(for: URL(fileURLWithPath: path))
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(nil, to: statement, at: 1)
                bind(AttributionConfidence.sourceOnly.rawValue, to: statement, at: 2)
                bind(AttributionBasis.none.rawValue, to: statement, at: 3)
                bind(thread?.id, to: statement, at: 4)
                sqlite3_bind_int(statement, 5, thread == nil ? 0 : 1)
                bind(thread?.parentID, to: statement, at: 6)
                bind(thread?.model, to: statement, at: 7)
                sqlite3_bind_int(statement, 8, thread == nil ? 0 : 1)
                sqlite3_bind_int(statement, 9, thread?.isSubagent == true ? 1 : 0)
                bind(sourceID, to: statement, at: 10)
                bind(path, to: statement, at: 11)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                updated += Int(sqlite3_changes(database))
            }
        }
        return updated
    }

    private func updateStoredClaudeMetadata(sourceID: String, resolver: ClaudeAccountResolver) throws -> Int {
        let rows = storedSessionMetadata(sourceID: sourceID)
        guard !rows.isEmpty else { return 0 }
        var updated = 0
        try transaction {
            let sql = """
                UPDATE events SET
                    account_id = ?,
                    attribution_confidence = ?,
                    attribution_basis = ?
                WHERE source_id = ?
                    AND session_id = ?
                    AND is_subagent = ?
                    AND parent_session_id IS ?
                """
            guard let statement = prepare(sql) else { throw databaseError() }
            defer { sqlite3_finalize(statement) }
            for row in rows {
                let parentSession = row.parentSessionID ?? row.sessionID
                let explicit = resolver.attribution(for: parentSession)
                let fallback = ClaudeAccountAttribution(accountID: row.accountID, confidence: row.attributionConfidence, basis: row.attributionBasis)
                let attribution = explicit ?? (row.attributionConfidence == .sessionVerified ? fallback : resolver.defaultAttribution)
                let isAmbiguousSidechain = row.isSubagent && row.sessionID == parentSession
                let confidence: AttributionConfidence = attribution.confidence == .ambiguousAccount ? .ambiguousAccount : (isAmbiguousSidechain ? .ambiguousSidechain : (row.isSubagent ? .parentSession : attribution.confidence))
                let basis: AttributionBasis = attribution.confidence == .ambiguousAccount ? .claudeAccountConflict : (row.isSubagent ? .parentSession : attribution.basis)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(attribution.accountID, to: statement, at: 1)
                bind(confidence.rawValue, to: statement, at: 2)
                bind(basis.rawValue, to: statement, at: 3)
                bind(sourceID, to: statement, at: 4)
                bind(row.sessionID, to: statement, at: 5)
                sqlite3_bind_int(statement, 6, row.isSubagent ? 1 : 0)
                bind(row.parentSessionID, to: statement, at: 7)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                updated += Int(sqlite3_changes(database))
            }
        }
        return updated
    }

    private func upsertFile(sourceID: String, path: String, size: Int64, modified: TimeInterval, fileIdentity: String, parsedOffset: Int64, prefixHash: Int64?, appendGuardHash: Int64, requiresReconciliation: Bool, snapshot: [String: Int64]?, model: String?, accounting: AccountingDiagnostics) throws {
        guard let statement = prepare("INSERT OR REPLACE INTO files (source_id, path, size, modified, file_identity, parsed_offset, prefix_hash, append_guard_hash, requires_reconciliation, last_input, last_cached, last_cache_5m, last_cache_1h, last_output, last_reasoning, diagnostic_duplicate, diagnostic_stale, diagnostic_inherited, diagnostic_reset, last_model) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        let snapshot = snapshot ?? [:]
        bind(sourceID, to: statement, at: 1); bind(path, to: statement, at: 2); sqlite3_bind_int64(statement, 3, size); sqlite3_bind_double(statement, 4, modified); bind(fileIdentity, to: statement, at: 5); sqlite3_bind_int64(statement, 6, parsedOffset); sqlite3_bind_int64(statement, 7, prefixHash ?? 0); sqlite3_bind_int64(statement, 8, appendGuardHash); sqlite3_bind_int(statement, 9, requiresReconciliation ? 1 : 0); sqlite3_bind_int64(statement, 10, snapshot["input"] ?? 0); sqlite3_bind_int64(statement, 11, snapshot["cached"] ?? 0); sqlite3_bind_int64(statement, 12, snapshot["cache_5m"] ?? 0); sqlite3_bind_int64(statement, 13, snapshot["cache_1h"] ?? 0); sqlite3_bind_int64(statement, 14, snapshot["output"] ?? 0); sqlite3_bind_int64(statement, 15, snapshot["reasoning"] ?? 0); sqlite3_bind_int64(statement, 16, Int64(accounting.duplicateSnapshots)); sqlite3_bind_int64(statement, 17, Int64(accounting.staleSnapshots)); sqlite3_bind_int64(statement, 18, Int64(accounting.inheritedBaselines)); sqlite3_bind_int64(statement, 19, Int64(accounting.ambiguousResets)); bind(model, to: statement, at: 20)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private static func fileIdentity(at url: URL) -> String {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { return "" }
        return String(describing: info.st_dev) + ":" + String(describing: info.st_ino)
    }

    private static func prefixHash(at url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }

    private static func appendGuardHash(at url: URL, endingAt end: Int64) -> Int64? {
        guard end > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = max(0, end - 64 * 1024)
        do {
            try handle.seek(toOffset: UInt64(start))
            guard let data = try handle.read(upToCount: Int(end - start)), !data.isEmpty else { return nil }
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return Int64(bitPattern: hash)
        } catch {
            return nil
        }
    }

    private func deleteFile(sourceID: String, path: String) throws {
        guard let statement = prepare("DELETE FROM files WHERE source_id = ? AND path = ?") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1); bind(path, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func deleteAllEvents(sourceID: String) throws {
        guard let statement = prepare("DELETE FROM events WHERE source_id = ?") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func deleteAllFiles(sourceID: String) throws {
        guard let statement = prepare("DELETE FROM files WHERE source_id = ?") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func deleteSourceMetadata(sourceID: String) throws {
        guard let statement = prepare("DELETE FROM source_metadata WHERE source_id = ?") else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(sourceID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try work(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func migrateAccountingGeneration() throws {
        let currentGeneration = 6
        guard userVersion() < currentGeneration else { return }
        // The cache is disposable app-owned state. The prior generation
        // lacks per-request model attribution, a resumable active-model cursor,
        // and long-context pricing subsets,
        // so retaining it would make a corrected price look authoritative while
        // still using thread-level model guesses. Rebuild from provider files.
        try transaction {
            try exec("DELETE FROM events")
            try exec("DELETE FROM files")
            try exec("DELETE FROM source_metadata")
            try exec("DELETE FROM source_config")
            try exec("PRAGMA user_version = \(currentGeneration)")
        }
    }

    private func userVersion() -> Int {
        guard let statement = prepare("PRAGMA user_version") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sourcePredicate(_ sourceIDs: Set<String>?) -> String {
        guard let sourceIDs else { return "" }
        guard !sourceIDs.isEmpty else { return " WHERE 0" }
        return " WHERE source_id IN (\(sourceIDs.map { _ in "?" }.joined(separator: ",")))"
    }

    private func bindSourceIDs(_ sourceIDs: Set<String>?, to statement: OpaquePointer?, startingAt index: Int32) {
        guard let sourceIDs else { return }
        for (offset, sourceID) in sourceIDs.sorted().enumerated() {
            bind(sourceID, to: statement, at: index + Int32(offset))
        }
    }

    private func ensureColumn(table: String, name: String, definition: String) throws {
        guard let statement = prepare("PRAGMA table_info(\(table))") else { throw databaseError() }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == name { exists = true; break }
        }
        sqlite3_finalize(statement)
        if !exists { try exec("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)") }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? databaseError().localizedDescription
            sqlite3_free(error)
            throw NSError(domain: "AIUsageTracker.SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? { var statement: OpaquePointer?; return sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK ? statement : nil }
    private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) { if let value { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(statement, index) } }
    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let pointer = sqlite3_column_text(statement, index) else { return nil }; return String(cString: pointer) }
    private func databaseError() -> Error { NSError(domain: "AIUsageTracker.SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"]) }
}

private enum MetadataReadError: LocalizedError {
    case incomplete

    var errorDescription: String? { "provider metadata could not be read completely" }
}
