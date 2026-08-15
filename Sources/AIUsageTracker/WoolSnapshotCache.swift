import Foundation
import UsageCore

/// The first-frame snapshot contains aggregate counters and provider totals
/// only. It never persists provider content, paths, account IDs, or bookmarks.
struct WoolSnapshotCache {
    struct Value: Codable, Sendable {
        let schemaVersion: Int
        let sourceIDs: Set<String>
        let updatedAt: Date
        let summary: UsageSummary
    }

    private static let schemaVersion = 6

    static func load(sourceIDs: Set<String>) -> Value? {
        guard !sourceIDs.isEmpty,
              let data = try? Data(contentsOf: cacheURL()),
              let cached = try? JSONDecoder().decode(Value.self, from: data),
              cached.schemaVersion == schemaVersion,
              cached.sourceIDs == sourceIDs,
              cached.summary.eventCount > 0 else { return nil }
        return cached
    }

    static func save(summary: UsageSummary, sourceIDs: Set<String>, updatedAt: Date) {
        guard !sourceIDs.isEmpty, summary.eventCount > 0 else { return }
        var snapshot = UsageSummary()
        snapshot.usage = summary.usage
        snapshot.eventCount = summary.eventCount
        snapshot.apiUSD = summary.apiUSD
        snapshot.codexCredits = summary.codexCredits
        snapshot.unpricedEventCount = summary.unpricedEventCount
        snapshot.accounting = summary.accounting
        snapshot.isProvisional = summary.isProvisional
        snapshot.accounts = providerRows(from: summary.accounts)

        let value = Value(
            schemaVersion: schemaVersion,
            sourceIDs: sourceIDs,
            updatedAt: updatedAt,
            summary: snapshot
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL(), options: [.atomic])
    }

    private static func providerRows(from accounts: [AccountUsageBreakdown]) -> [AccountUsageBreakdown] {
        var rows: [Provider: AccountUsageBreakdown] = [:]
        for account in accounts {
            var row = rows[account.provider] ?? AccountUsageBreakdown(
                id: "provider:\(account.provider.rawValue)",
                provider: account.provider,
                accountID: "provider-total"
            )
            row.usage = row.usage + account.usage
            row.eventCount += account.eventCount
            row.apiUSD += account.apiUSD
            if let apiCosts = account.apiCostBreakdown {
                row.apiCostBreakdown = (row.apiCostBreakdown ?? APIUsageCostBreakdown()) + apiCosts
            }
            row.codexCredits += account.codexCredits
            rows[account.provider] = row
        }
        return Provider.allCases.compactMap { rows[$0] }
    }

    private static func cacheURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("AIUsageTracker", isDirectory: true)
            .appendingPathComponent("headline-v1.json")
    }
}
