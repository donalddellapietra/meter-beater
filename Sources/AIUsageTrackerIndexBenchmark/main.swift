import Foundation
import UsageCore

@main
struct AIUsageTrackerIndexBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var sources: [UsageSource] = []
        var parseOnly = false
        var headlineOnly = false
        var compactOnly = false
        var compareFullSummary = false
        var auditAccounting = false
        var maxFiles: Int?
        var bootstrapOnly = false
        var snapshotOnly = false
        var freshDatabase = false
        var databaseURL: URL?
        var repeatCount = 1
        var changedPaths: Set<String>?
        var dateRange: UsageDateRange = .allTime
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--parse-only" {
                parseOnly = true
                index += 1
                continue
            }
            if arguments[index] == "--headline" {
                headlineOnly = true
                index += 1
                continue
            }
            if arguments[index] == "--compact-only" {
                compactOnly = true
                index += 1
                continue
            }
            if arguments[index] == "--compare-full" {
                compareFullSummary = true
                index += 1
                continue
            }
            if arguments[index] == "--audit-accounting" {
                auditAccounting = true
                index += 1
                continue
            }
            if arguments[index] == "--max-files", index + 1 < arguments.count {
                guard let value = Int(arguments[index + 1]), value > 0 else { throw usageError() }
                maxFiles = value
                index += 2
                continue
            }
            if arguments[index] == "--bootstrap" {
                bootstrapOnly = true
                index += 1
                continue
            }
            if arguments[index] == "--snapshot-only" {
                snapshotOnly = true
                index += 1
                continue
            }
            if arguments[index] == "--fresh" {
                freshDatabase = true
                index += 1
                continue
            }
            if arguments[index] == "--database", index + 1 < arguments.count {
                databaseURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
                continue
            }
            if arguments[index] == "--repeat", index + 1 < arguments.count {
                guard let value = Int(arguments[index + 1]), value > 0 else { throw usageError() }
                repeatCount = value
                index += 2
                continue
            }
            if arguments[index] == "--last-days", index + 1 < arguments.count {
                guard let value = Int(arguments[index + 1]), value > 0 else { throw usageError() }
                dateRange = .lastDays(value)
                index += 2
                continue
            }
            if arguments[index] == "--changed-path", index + 1 < arguments.count {
                if changedPaths == nil { changedPaths = [] }
                changedPaths?.insert(arguments[index + 1])
                index += 2
                continue
            }
            guard arguments[index] == "--source", index + 1 < arguments.count else {
                throw usageError()
            }
            let specification = arguments[index + 1]
            let parts = specification.split(separator: "=", maxSplits: 1).map(String.init)
            let provider: Provider
            switch parts.first?.lowercased() {
            case "codex": provider = .codex
            case "claude": provider = .claude
            default: throw usageError()
            }
            guard parts.count == 2, FileManager.default.fileExists(atPath: parts[1]) else {
                throw usageError()
            }
            sources.append(UsageSource(displayName: parts[0], provider: provider, rootPath: parts[1]))
            index += 2
        }
        if sources.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexRoot = home.appendingPathComponent(".codex")
            let claudeRoot = home.appendingPathComponent(".claude")
            if FileManager.default.fileExists(atPath: codexRoot.path) {
                sources.append(UsageSource(displayName: "codex", provider: .codex, rootPath: codexRoot.path))
            }
            if FileManager.default.fileExists(atPath: claudeRoot.path) {
                sources.append(UsageSource(displayName: "claude", provider: .claude, rootPath: claudeRoot.path))
            }
        }
        guard !sources.isEmpty else { throw usageError() }

        if headlineOnly {
            let result = UsageHeadlineScanner.scanCodex(sources: sources, timeLimit: 4)
            print("headline=\(String(format: "%.2f", result.duration))s complete=\(result.complete) events=\(result.summary.eventCount) tokens=\(result.summary.usage.totalTokens) api=\(String(format: "%.2f", result.summary.apiUSD))")
            if result.duration > 5 || result.summary.eventCount == 0 {
                fputs("FAIL: first-frame headline missed its five-second budget\n", stderr)
                exit(2)
            }
            return
        }

        if parseOnly {
            for source in sources {
                let started = Date()
                let result = UsageScanner.scan(source: source, maxFiles: maxFiles)
                print("\(source.displayName): parse=\(String(format: "%.2f", Date().timeIntervalSince(started)))s files=\(result.filesScanned) bytes=\(result.bytesRead) events=\(result.events.count)")
            }
            return
        }

        let temporaryRoot: URL?
        if freshDatabase, databaseURL != nil {
            throw usageError()
        } else if freshDatabase {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageTracker-index-benchmark-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            temporaryRoot = root
            databaseURL = root.appendingPathComponent("overview.sqlite")
        } else if databaseURL == nil {
            // Existing-cache testing is the safe default. A full archive read
            // must be requested explicitly with `--fresh` so a routine local
            // benchmark cannot accidentally rebuild the overview.
            temporaryRoot = nil
            databaseURL = try SQLiteIndexStore.defaultURL()
        } else {
            temporaryRoot = nil
            try FileManager.default.createDirectory(at: databaseURL!.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        defer { if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) } }

        let store = try SQLiteIndexStore(url: databaseURL!)
        let sourceIDs = Set(sources.map(\.id))
        if compactOnly {
            let interval = dateRange.interval()
            for run in 1...repeatCount {
                let started = Date()
                let summary = store.compactSummary(from: interval?.start, to: interval?.end, sourceIDs: sourceIDs)
                let elapsed = Date().timeIntervalSince(started)
                guard accountCostsReconcile(summary.accounts) else {
                    fputs("FAIL: compact API cost categories do not reconcile to provider totals\n", stderr)
                    exit(4)
                }
                let serving = summary.accounts.reduce(into: ServingCostEstimate()) { total, account in
                    total = total + ServingCostCatalog.estimate(apiUSD: account.apiUSD, provider: account.provider)
                }
                var comparison = ""
                if compareFullSummary {
                    let fullStarted = Date()
                    let full = store.summary(from: interval?.start, to: interval?.end, sourceIDs: sourceIDs, maxSubagents: 12)
                    let fullElapsed = Date().timeIntervalSince(fullStarted)
                    guard summary.usage == full.usage,
                          summary.eventCount == full.eventCount,
                          summary.unpricedEventCount == full.unpricedEventCount,
                          abs(summary.apiUSD - full.apiUSD) < 0.005,
                          accountCostsReconcile(full.accounts),
                          costBreakdownsMatch(summary.accounts, full.accounts) else {
                        fputs("FAIL: compact and full cached summaries disagree\n", stderr)
                        exit(3)
                    }
                    comparison = " full=\(String(format: "%.3f", fullElapsed))s costs=exact match=true"
                }
                print("run=\(run) compact=\(String(format: "%.3f", elapsed))s events=\(summary.eventCount) tokens=\(summary.usage.totalTokens) api=\(String(format: "%.2f", summary.apiUSD)) serving=\(String(format: "%.2f", serving.midpointUSD)) range=\(String(format: "%.2f", serving.lowerUSD))...\(String(format: "%.2f", serving.upperUSD)) providers=\(summary.accounts.count)\(comparison)")
                if elapsed > 5 || summary.eventCount == 0 {
                    fputs("FAIL: compact menu summary missed its five-second budget\n", stderr)
                    exit(2)
                }
            }
            return
        }
        for run in 1...repeatCount {
            let started = Date()
            let result = store.refresh(
                sources: sources,
                changedPaths: changedPaths,
                maxFiles: maxFiles,
                bootstrapOnly: bootstrapOnly,
                snapshotOnly: snapshotOnly,
                timeLimit: 25
            )
            let summaryStarted = Date()
            let summary = store.summary(sourceIDs: sourceIDs, maxSubagents: 12)
            let summaryElapsed = Date().timeIntervalSince(summaryStarted)
            let elapsed = Date().timeIntervalSince(started)
            print("run=\(run) elapsed=\(String(format: "%.2f", elapsed))s refresh=\(String(format: "%.2f", result.duration))s summary=\(String(format: "%.3f", summaryElapsed))s files=\(result.changedFiles) bytes=\(result.bytesRead) events=\(summary.eventCount) tokens=\(summary.usage.totalTokens) api=\(String(format: "%.2f", summary.apiUSD)) unpriced=\(summary.unpricedEventCount) warnings=\(result.warnings.count)")
            for source in sources {
                let sourceSummary = store.summary(sourceIDs: Set([source.id]), maxSubagents: 12)
                print("\(source.displayName): events=\(sourceSummary.eventCount) tokens=\(sourceSummary.usage.totalTokens)")
            }
            if auditAccounting {
                for model in summary.models {
                    print("model=\(model.id) events=\(model.eventCount) input=\(model.usage.inputTokens) cached=\(model.usage.cachedInputTokens) output=\(model.usage.outputTokens) api=\(String(format: "%.6f", model.apiUSD))")
                }
                if let accounting = summary.accounting {
                    print("accounting duplicates=\(accounting.duplicateSnapshots) stale=\(accounting.staleSnapshots) inherited=\(accounting.inheritedBaselines) resets=\(accounting.ambiguousResets)")
                }
            }
            for warning in result.warnings { print("warning: \(warning)") }
            if result.didReachTimeLimit || elapsed > 30 {
                fputs("FAIL: bounded overview exceeded its startup budget\n", stderr)
                exit(2)
            }
        }
    }

    private static func accountCostsReconcile(_ accounts: [AccountUsageBreakdown]) -> Bool {
        accounts.allSatisfy { account in
            abs((account.apiCostBreakdown?.totalUSD ?? 0) - account.apiUSD) < 0.005
        }
    }

    private static func costBreakdownsMatch(
        _ lhs: [AccountUsageBreakdown],
        _ rhs: [AccountUsageBreakdown]
    ) -> Bool {
        let left = costBreakdownsByProvider(lhs)
        let right = costBreakdownsByProvider(rhs)
        return Provider.allCases.allSatisfy { provider in
            let a = left[provider] ?? APIUsageCostBreakdown()
            let b = right[provider] ?? APIUsageCostBreakdown()
            return abs(a.uncachedInputUSD - b.uncachedInputUSD) < 0.005
                && abs(a.cachedInputUSD - b.cachedInputUSD) < 0.005
                && abs(a.outputUSD - b.outputUSD) < 0.005
        }
    }

    private static func costBreakdownsByProvider(
        _ accounts: [AccountUsageBreakdown]
    ) -> [Provider: APIUsageCostBreakdown] {
        accounts.reduce(into: [:]) { totals, account in
            guard let costs = account.apiCostBreakdown else { return }
            totals[account.provider] = (totals[account.provider] ?? APIUsageCostBreakdown()) + costs
        }
    }

    private static func usageError() -> NSError {
        NSError(domain: "AIUsageTrackerIndexBenchmark", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Usage: AIUsageTrackerIndexBenchmark [--headline] [--compact-only] [--compare-full] [--audit-accounting] [--last-days N] [--fresh] [--bootstrap] [--snapshot-only] [--database PATH] [--repeat N] [--changed-path PATH] [--source codex=/path/.codex] [--source claude=/path/.claude]"
        ])
    }
}
