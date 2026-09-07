import Foundation

public struct UsageIndexQuery: Sendable, Hashable {
    public let start: Date?
    public let end: Date?
    public let sourceIDs: Set<String>?

    public init(start: Date? = nil, end: Date? = nil, sourceIDs: Set<String>? = nil) {
        self.start = start
        self.end = end
        self.sourceIDs = sourceIDs
    }

    public init(range: UsageDateRange, now: Date = Date(), sourceIDs: Set<String>? = nil) {
        let interval = range.interval(now: now)
        self.init(
            start: interval?.start,
            end: interval.map { range.movesWithTime ? min($0.end, now) : $0.end },
            sourceIDs: sourceIDs
        )
    }
}

public struct UsageIndexRefreshRequest: Sendable {
    public let sources: [UsageSource]
    public let changedPaths: Set<String>?
    public let fullReconciliation: Bool
    public let maxFiles: Int?
    public let bootstrapOnly: Bool
    public let snapshotOnly: Bool
    /// Hard UI safety budget. The store stops between bounded file batches and
    /// preserves the last good rows when this deadline is reached.
    public let timeLimit: TimeInterval?

    public init(
        sources: [UsageSource],
        changedPaths: Set<String>? = nil,
        fullReconciliation: Bool = false,
        maxFiles: Int? = nil,
        bootstrapOnly: Bool = false,
        snapshotOnly: Bool = false,
        timeLimit: TimeInterval? = nil
    ) {
        self.sources = sources
        self.changedPaths = changedPaths
        self.fullReconciliation = fullReconciliation
        self.maxFiles = maxFiles
        self.bootstrapOnly = bootstrapOnly
        self.snapshotOnly = snapshotOnly
        self.timeLimit = timeLimit
    }
}

/// Schedules app-owned index work without putting visible reads behind a scan.
///
/// Writes stay serialized off the main thread at user-initiated QoS. Dashboard
/// queries use a second SQLite connection and queue, allowing WAL to serve the
/// last committed snapshot while a bounded refresh checks provider files.
public final class UsageIndexService: @unchecked Sendable {
    private let store: SQLiteIndexStore
    private let queryStore: SQLiteIndexStore
    private let writeQueue = DispatchQueue(label: "com.donalddellapietra.aiusagetracker.index.write", qos: .userInitiated)
    private let queryQueue = DispatchQueue(label: "com.donalddellapietra.aiusagetracker.index.read", qos: .userInitiated)
    private let headlineQueue = DispatchQueue(label: "com.donalddellapietra.aiusagetracker.headline", qos: .userInitiated)

    public init(store: SQLiteIndexStore, queryStore: SQLiteIndexStore? = nil) {
        self.store = store
        self.queryStore = queryStore ?? store
    }

    public func refresh(_ request: UsageIndexRefreshRequest) async -> RefreshResult {
        await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume(returning: self.store.refresh(
                    sources: request.sources,
                    changedPaths: request.changedPaths,
                    fullReconciliation: request.fullReconciliation,
                    maxFiles: request.maxFiles,
                    bootstrapOnly: request.bootstrapOnly,
                    snapshotOnly: request.snapshotOnly,
                    timeLimit: request.timeLimit
                ))
            }
        }
    }

    public func headline(sources: [UsageSource], timeLimit: TimeInterval = 4) async -> UsageHeadlineResult {
        await withCheckedContinuation { continuation in
            headlineQueue.async {
                continuation.resume(returning: UsageHeadlineScanner.scanCodex(sources: sources, timeLimit: timeLimit))
            }
        }
    }

    public func overview(_ query: UsageIndexQuery) async -> UsageSummary {
        await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: self.queryStore.overview(from: query.start, to: query.end, sourceIDs: query.sourceIDs))
            }
        }
    }

    /// Loads only the priced totals and provider rows used by the menu-bar UI.
    /// It deliberately skips models, days, sessions, and subagent collections.
    public func compactSummary(_ query: UsageIndexQuery) async -> UsageSummary {
        await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: self.queryStore.compactSummary(
                    from: query.start,
                    to: query.end,
                    sourceIDs: query.sourceIDs
                ))
            }
        }
    }

    /// Earliest indexed event timestamp for the given sources; a cheap scalar
    /// read on the query connection.
    public func earliestEventTimestamp(sourceIDs: Set<String>?) async -> Date? {
        await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: self.queryStore.earliestEventTimestamp(sourceIDs: sourceIDs))
            }
        }
    }

    public func details(_ query: UsageIndexQuery) async -> UsageSummary {
        await withCheckedContinuation { continuation in
            queryQueue.async {
                // The dashboard needs representative child-session rows, not
                // tens of thousands of SwiftUI views. Full export queries can
                // still request the unbounded store summary explicitly.
                continuation.resume(returning: self.queryStore.summary(from: query.start, to: query.end, sourceIDs: query.sourceIDs, maxSubagents: 12))
            }
        }
    }

    public func report(_ query: UsageIndexQuery) async -> UsageSummary {
        await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: self.queryStore.summary(from: query.start, to: query.end, sourceIDs: query.sourceIDs))
            }
        }
    }

    public func removeSources(_ sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        writeQueue.async {
            self.store.removeSources(sourceIDs)
        }
    }
}
