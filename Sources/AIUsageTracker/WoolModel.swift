import AppKit
import Foundation
import Observation
import SwiftUI
import UsageCore

/// The complete presentation state for the menu-bar app.
///
/// The visible number comes from a tiny persisted snapshot or a four-second
/// bounded transcript headline. Priced provider totals load separately, and
/// background refreshes publish a single immutable replacement only after a
/// bounded index pass completes.
/// The billing cadence a subscription price is quoted in.
enum SpendPeriod: String, CaseIterable, Identifiable {
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var dayLength: Double {
        switch self {
        case .weekly: return 7
        case .monthly: return 365.25 / 12
        case .yearly: return 365.25
        }
    }
}

@MainActor
@Observable
final class WoolModel {
    private(set) var sources: [UsageSource]
    private(set) var summary = UsageSummary()
    private(set) var isRefreshing = false
    private(set) var staleSourceIDs: Set<String> = []
    private(set) var lastRefresh: Date?
    private(set) var hasLoadedSummary = false
    private(set) var codexServingCostRatio: Double
    private(set) var claudeServingCostRatio: Double
    private(set) var codexSpendAmount: Double
    private(set) var codexSpendPeriod: SpendPeriod
    private(set) var claudeSpendAmount: Double
    private(set) var claudeSpendPeriod: SpendPeriod
    private(set) var cycleWeekStart: Int
    private(set) var cycleMonthStart: Int
    private(set) var appLanguage: AppLanguage
    private(set) var dateRange: UsageDateRange
    private(set) var isDateQuerying = false
    private(set) var earliestUsageDay: Date?
    /// True when the last refresh hit its time limit, so displayed totals may
    /// lag the archive until the follow-up pass completes.
    private(set) var isIndexIncomplete = false

    @ObservationIgnored private let indexService: UsageIndexService?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var activeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var sourceChangeTask: Task<Void, Never>?
    @ObservationIgnored private var fileChangeTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var dateQueryTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatcher: ProviderFileWatcher?
    @ObservationIgnored private var pendingRefresh: RefreshIntent?
    @ObservationIgnored private var pendingProviderPaths = Set<String>()
    @ObservationIgnored private var firstPendingChangeAt: ContinuousClock.Instant?
    @ObservationIgnored private var fileChangeRevision: UInt64 = 0
    @ObservationIgnored private var configurationRevision: UInt64 = 0
    @ObservationIgnored private var dateQueryRevision: UInt64 = 0
    @ObservationIgnored private var canRetryTimedOutRefresh = true
    @ObservationIgnored private var displayedSourceIDs: Set<String>?
    @ObservationIgnored private var displayedDateRange: UsageDateRange?
    @ObservationIgnored private var securityScopesToStop = Set<String>()
    @ObservationIgnored private var activeSecurityScopedURLs: [String: URL] = [:]
    private static let sourcesKey = "AIUsageTracker.sources"
    private static let codexServingCostKey = "AIUsageTracker.servingCost.codex"
    private static let claudeServingCostKey = "AIUsageTracker.servingCost.claude"
    private static let appLanguageKey = "AIUsageTracker.appLanguage"
    private static let dateRangeKey = "AIUsageTracker.dateRange"
    private static let codexSpendAmountKey = "MeterBeater.spend.codex.amount"
    private static let codexSpendPeriodKey = "MeterBeater.spend.codex.period"
    private static let claudeSpendAmountKey = "MeterBeater.spend.claude.amount"
    private static let claudeSpendPeriodKey = "MeterBeater.spend.claude.period"
    private static let cycleWeekStartKey = "MeterBeater.cycle.weekStart"
    private static let cycleMonthStartKey = "MeterBeater.cycle.monthStart"
    static let defaultSpendAmount: Double = 200
    private static let fileQuietPeriod = Duration.seconds(8)
    private static let fileMaximumLatency = Duration.seconds(60)
    private static let queuedRefreshDelay = Duration.seconds(5)
    private static let safetyRefreshInterval = Duration.seconds(300)
    private static let panelRefreshMaximumAge: TimeInterval = 60

    private struct RefreshIntent: Sendable {
        /// Nil requests a bounded check of all enabled roots. A path set is a
        /// cheap filesystem-scoped update. A full request always wins a merge.
        var changedPaths: Set<String>?

        mutating func merge(_ other: RefreshIntent) {
            switch (changedPaths, other.changedPaths) {
            case (.none, _), (_, .none): changedPaths = nil
            case let (.some(current), .some(incoming)): changedPaths = current.union(incoming)
            }
        }
    }

    init() {
        appLanguage = Self.loadAppLanguage()
        let initialDateRange = Self.loadDateRange()
        dateRange = initialDateRange
        codexServingCostRatio = Self.loadServingCostRatio(
            key: Self.codexServingCostKey,
            provider: .codex
        )
        claudeServingCostRatio = Self.loadServingCostRatio(
            key: Self.claudeServingCostKey,
            provider: .claude
        )
        codexSpendAmount = Self.loadSpendAmount(key: Self.codexSpendAmountKey)
        codexSpendPeriod = Self.loadSpendPeriod(key: Self.codexSpendPeriodKey)
        claudeSpendAmount = Self.loadSpendAmount(key: Self.claudeSpendAmountKey)
        claudeSpendPeriod = Self.loadSpendPeriod(key: Self.claudeSpendPeriodKey)
        cycleWeekStart = Self.loadBoundedInt(
            key: Self.cycleWeekStartKey,
            range: 1...7,
            fallback: Calendar.current.firstWeekday
        )
        cycleMonthStart = Self.loadBoundedInt(key: Self.cycleMonthStartKey, range: 1...31, fallback: 1)
        let discovered = ProviderRootDiscovery.conventionalSources()
        var resolved = Self.loadSources(discovered: discovered)
        for index in resolved.indices where resolved[index].enabled {
            if let bookmark = resolved[index].bookmarkData {
                guard let url = Self.resolveBookmark(bookmark, source: &resolved[index]),
                      url.startAccessingSecurityScopedResource() else {
                    resolved[index].enabled = false
                    continue
                }
                activeSecurityScopedURLs[resolved[index].id] = url
            } else if !ProviderRootDiscovery.isReadableDirectory(resolved[index].rootPath) {
                resolved[index].enabled = false
            }
        }
        sources = resolved

        let sourceIDs = Set(resolved.filter(\.enabled).map(\.id))
        if let cached = WoolSnapshotCache.load(sourceIDs: sourceIDs) {
            lastRefresh = cached.updatedAt
            if initialDateRange.isAllTime {
                summary = cached.summary
                displayedSourceIDs = sourceIDs
                displayedDateRange = .allTime
                hasLoadedSummary = true
            }
        }

        if let url = try? SQLiteIndexStore.defaultURL(),
           let store = try? SQLiteIndexStore(url: url) {
            indexService = UsageIndexService(store: store, queryStore: try? SQLiteIndexStore(url: url))
        } else {
            indexService = nil
        }

        fileWatcher = ProviderFileWatcher(
            onChange: { [weak self] paths in
                Task { @MainActor [weak self] in self?.providerFilesChanged(paths: paths) }
            },
            onRescanRequired: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.requestRefresh(RefreshIntent(changedPaths: nil))
                }
            }
        )
        saveSources()
        updateFileWatcher()
        startSafetyRefreshes()

        startupTask = Task { @MainActor [weak self] in
            // Let AppKit install the status item before any archive or SQLite IO.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            if !self.hasLoadedSummary, self.dateRange.isAllTime { await self.loadFastHeadline() }
            guard !Task.isCancelled else { return }
            await self.loadCompactSummary()
            guard !Task.isCancelled else { return }
#if DEBUG
            if ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_DISABLE_REFRESH"] == "1" { return }
#endif
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self.requestRefresh(RefreshIntent(changedPaths: nil))
        }
    }

    deinit {
        startupTask?.cancel()
        activeRefreshTask?.cancel()
        sourceChangeTask?.cancel()
        fileChangeTask?.cancel()
        pollingTask?.cancel()
        dateQueryTask?.cancel()
        fileWatcher?.stop()
        for url in activeSecurityScopedURLs.values { url.stopAccessingSecurityScopedResource() }
    }

    func refresh() {
        canRetryTimedOutRefresh = true
        requestRefresh(RefreshIntent(changedPaths: nil))
    }

    func panelBecameActive() {
        refreshDateWindow()
        guard !isRefreshing else { return }
        guard lastRefresh.map({ Date().timeIntervalSince($0) >= Self.panelRefreshMaximumAge }) ?? true else {
            return
        }
        requestRefresh(RefreshIntent(changedPaths: nil))
    }

    func detectSources() {
        let existingIDs = Set(sources.map(\.id))
        let additions = ProviderRootDiscovery.conventionalSources().filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return }
        sources.append(contentsOf: additions)
        configurationDidChange()
    }

    func addSource(provider: Provider) {
        // An LSUIElement app is not the active app while its panel is open, so
        // without activation the open panel can appear behind other windows.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = copy.useFolder
        panel.message = copy.chooseDataRoot(provider)
        guard panel.runModal() == .OK, let url = panel.url,
              url.startAccessingSecurityScopedResource() else { return }

        let source = UsageSource(
            displayName: "\(provider.rawValue) · \(url.lastPathComponent)",
            provider: provider,
            rootPath: url.path,
            bookmarkData: try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        )
        guard !sources.contains(where: { $0.id == source.id }) else {
            url.stopAccessingSecurityScopedResource()
            return
        }
        activeSecurityScopedURLs[source.id] = url
        sources.append(source)
        configurationDidChange()
    }

    func setSourceEnabled(_ sourceID: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }),
              sources[index].enabled != enabled else { return }
        if enabled, activeSecurityScopedURLs[sourceID] == nil, !activateSecurityScope(for: index) {
            staleSourceIDs.insert(sourceID)
            return
        }
        sources[index].enabled = enabled
        if enabled {
            securityScopesToStop.remove(sourceID)
            staleSourceIDs.remove(sourceID)
        } else {
            securityScopesToStop.insert(sourceID)
            staleSourceIDs.remove(sourceID)
        }
        configurationDidChange()
    }

    func servingCostRatio(for provider: Provider) -> Double {
        provider == .codex ? codexServingCostRatio : claudeServingCostRatio
    }

    func spendAmount(for provider: Provider) -> Double {
        provider == .codex ? codexSpendAmount : claudeSpendAmount
    }

    func spendPeriod(for provider: Provider) -> SpendPeriod {
        provider == .codex ? codexSpendPeriod : claudeSpendPeriod
    }

    /// Combined subscription spend per day across both providers.
    var dailySpendTotal: Double {
        codexSpendAmount / codexSpendPeriod.dayLength
            + claudeSpendAmount / claudeSpendPeriod.dayLength
    }

    func setSpend(amount: Double, period: SpendPeriod, for provider: Provider) {
        let normalized = amount.isFinite ? min(max(amount, 0), 1_000_000) : Self.defaultSpendAmount
        switch provider {
        case .codex:
            guard codexSpendAmount != normalized || codexSpendPeriod != period else { return }
            codexSpendAmount = normalized
            codexSpendPeriod = period
            UserDefaults.standard.set(normalized, forKey: Self.codexSpendAmountKey)
            UserDefaults.standard.set(period.rawValue, forKey: Self.codexSpendPeriodKey)
        case .claude:
            guard claudeSpendAmount != normalized || claudeSpendPeriod != period else { return }
            claudeSpendAmount = normalized
            claudeSpendPeriod = period
            UserDefaults.standard.set(normalized, forKey: Self.claudeSpendAmountKey)
            UserDefaults.standard.set(period.rawValue, forKey: Self.claudeSpendPeriodKey)
        }
    }

    func resetSpend(for provider: Provider) {
        setSpend(amount: Self.defaultSpendAmount, period: .monthly, for: provider)
    }

    /// Weekday (1 = Sunday … 7 = Saturday) the weekly cycle renews on. If the
    /// weekly range is active, the change re-queries it immediately.
    func setCycleWeekStart(_ weekday: Int) {
        let normalized = min(max(weekday, 1), 7)
        guard cycleWeekStart != normalized else { return }
        cycleWeekStart = normalized
        UserDefaults.standard.set(normalized, forKey: Self.cycleWeekStartKey)
        if case .currentWeek = dateRange {
            setDateRange(.currentWeek(startWeekday: normalized))
        }
    }

    /// Day of the month the monthly cycle renews on, clamped to short months.
    /// If the monthly range is active, the change re-queries it immediately.
    func setCycleMonthStart(_ day: Int) {
        let normalized = min(max(day, 1), 31)
        guard cycleMonthStart != normalized else { return }
        cycleMonthStart = normalized
        UserDefaults.standard.set(normalized, forKey: Self.cycleMonthStartKey)
        if case .currentMonth = dateRange {
            setDateRange(.currentMonth(startDay: normalized))
        }
    }

    var copy: AppCopy {
        AppCopy(language: appLanguage)
    }

    func setAppLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        appLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.appLanguageKey)
    }

    func setDateRange(_ range: UsageDateRange) {
        guard dateRange != range else { return }
        dateRange = range
        if let data = try? JSONEncoder().encode(range) {
            UserDefaults.standard.set(data, forKey: Self.dateRangeKey)
        }
        scheduleDateQuery()
    }

    /// A cached SQL read only: no transcript scan and no animation timer.
    func refreshDateWindow() {
        guard dateRange.movesWithTime, !isDateQuerying else { return }
        scheduleDateQuery()
    }

    private func scheduleDateQuery() {
        dateQueryRevision &+= 1
        let revision = dateQueryRevision
        dateQueryTask?.cancel()
        isDateQuerying = true
        dateQueryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self, revision == self.dateQueryRevision else { return }
            await self.loadCompactSummary()
            guard !Task.isCancelled, revision == self.dateQueryRevision else { return }
            self.isDateQuerying = false
            self.dateQueryTask = nil
        }
    }

    func setServingCostRatio(_ value: Double, for provider: Provider) {
        let fallback = ServingCostCatalog.defaultMidpointRatio(for: provider)
        let normalized = value.isFinite ? min(max(value, 0), 1) : fallback
        switch provider {
        case .codex:
            guard codexServingCostRatio != normalized else { return }
            codexServingCostRatio = normalized
            UserDefaults.standard.set(normalized, forKey: Self.codexServingCostKey)
        case .claude:
            guard claudeServingCostRatio != normalized else { return }
            claudeServingCostRatio = normalized
            UserDefaults.standard.set(normalized, forKey: Self.claudeServingCostKey)
        }
    }

    func resetServingCostRatios() {
        UserDefaults.standard.removeObject(forKey: Self.codexServingCostKey)
        UserDefaults.standard.removeObject(forKey: Self.claudeServingCostKey)
        codexServingCostRatio = ServingCostCatalog.defaultMidpointRatio(for: .codex)
        claudeServingCostRatio = ServingCostCatalog.defaultMidpointRatio(for: .claude)
    }

    private static func loadSources(discovered: [UsageSource]) -> [UsageSource] {
        let saved = UserDefaults.standard.data(forKey: sourcesKey)
            .flatMap { try? JSONDecoder().decode([UsageSource].self, from: $0) }
        let savedIDs = Set((saved ?? []).map(\.id))
        var seen = Set<String>()
        return ((saved ?? []) + discovered.filter { !savedIDs.contains($0.id) })
            .filter { seen.insert($0.id).inserted }
    }

    private static func loadServingCostRatio(key: String, provider: Provider) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return ServingCostCatalog.defaultMidpointRatio(for: provider)
        }
        let value = stored.doubleValue
        return value.isFinite
            ? min(max(value, 0), 1)
            : ServingCostCatalog.defaultMidpointRatio(for: provider)
    }

    private static func loadSpendAmount(key: String) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return defaultSpendAmount
        }
        let value = stored.doubleValue
        return value.isFinite && value >= 0 ? min(value, 1_000_000) : defaultSpendAmount
    }

    private static func loadSpendPeriod(key: String) -> SpendPeriod {
        UserDefaults.standard.string(forKey: key).flatMap(SpendPeriod.init(rawValue:)) ?? .monthly
    }

    private static func loadBoundedInt(key: String, range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let stored = UserDefaults.standard.object(forKey: key) as? NSNumber else { return fallback }
        let value = stored.intValue
        return range.contains(value) ? value : fallback
    }

    private static func loadAppLanguage() -> AppLanguage {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_LANGUAGE"]
            .flatMap(AppLanguage.init(rawValue:)) {
            return override
        }
#endif
        return UserDefaults.standard.string(forKey: appLanguageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    private static func loadDateRange() -> UsageDateRange {
#if DEBUG
        switch ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_DATE_RANGE"] {
        case "last24": return .lastHours(24)
        case "last7": return .lastDays(7)
        case "last30": return .lastDays(30)
        case "ytd": return .yearToDate
        case "all": return .allTime
        case "day": return .currentDay
        case "week": return .currentWeek(startWeekday: Calendar.current.firstWeekday)
        case "month": return .currentMonth(startDay: 1)
        default: break
        }
#endif
        guard let data = UserDefaults.standard.data(forKey: dateRangeKey),
              let range = try? JSONDecoder().decode(UsageDateRange.self, from: data) else {
            return .allTime
        }
        return range
    }

    private static func resolveBookmark(_ bookmark: Data, source: inout UsageSource) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        source.rootPath = url.path
        if stale, let renewed = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            source.bookmarkData = renewed
        }
        return url
    }

    private func loadFastHeadline() async {
        guard let indexService else { return }
        let sourceSnapshot = sources
        let sourceIDs = enabledSourceIDs
        let revision = configurationRevision
        let result = await indexService.headline(sources: sourceSnapshot, timeLimit: 4)
        guard !Task.isCancelled,
              revision == configurationRevision,
              sourceIDs == enabledSourceIDs,
              result.summary.eventCount > 0 else { return }
        summary = Self.withholdingProvisionalPricing(result.summary)
        displayedSourceIDs = sourceIDs
        displayedDateRange = .allTime
        hasLoadedSummary = true
    }

    private func loadCompactSummary() async {
        guard let indexService else { return }
        let sourceIDs = enabledSourceIDs
        let revision = configurationRevision
        let selectedRange = dateRange
        var loaded = await indexService.compactSummary(UsageIndexQuery(
            range: selectedRange,
            sourceIDs: sourceIDs
        ))
        let earliest = await indexService.earliestEventTimestamp(sourceIDs: sourceIDs)
        guard !Task.isCancelled,
              revision == configurationRevision,
              sourceIDs == enabledSourceIDs,
              selectedRange == dateRange,
              loaded.eventCount > 0 || !selectedRange.isAllTime else { return }
        loaded = Self.withholdingProvisionalPricing(loaded)
        earliestUsageDay = earliest
        publish(loaded, sourceIDs: sourceIDs, dateRange: selectedRange, refreshedAt: lastRefresh ?? Date())
    }

    private func requestRefresh(_ intent: RefreshIntent) {
        guard indexService != nil else { return }
        if activeRefreshTask != nil {
            if pendingRefresh == nil { pendingRefresh = intent }
            else { pendingRefresh?.merge(intent) }
            return
        }
        startRefresh(intent)
    }

    private func startRefresh(_ intent: RefreshIntent) {
        guard let indexService else { return }
        let sourceSnapshot = sources
        let sourceIDs = Set(sourceSnapshot.filter(\.enabled).map(\.id))
        let revision = configurationRevision
        let selectedRange = dateRange
        let selectedDateRevision = dateQueryRevision
        let needsCurrentContext = displayedSourceIDs != sourceIDs
            || displayedDateRange != selectedRange
            || !hasLoadedSummary
        isRefreshing = true

        activeRefreshTask = Task { @MainActor [weak self] in
            let result = await indexService.refresh(UsageIndexRefreshRequest(
                sources: sourceSnapshot,
                changedPaths: intent.changedPaths,
                snapshotOnly: false,
                timeLimit: 25
            ))
            guard !Task.isCancelled, let self else { return }
            let contextStillCurrent = revision == self.configurationRevision && sourceIDs == self.enabledSourceIDs
            // A timed-out pass still publishes the partially indexed rows so a
            // slow machine shows progress instead of a stale total; the footer
            // reports "still indexing" until a pass completes in time.
            if contextStillCurrent,
               result.failedFiles == 0 && (
                needsCurrentContext || selectedRange.movesWithTime || result.changedFiles > 0 || result.removedFiles > 0
                    || result.metadataChanged || result.didReachTimeLimit
            ) {
                var loaded = await indexService.compactSummary(UsageIndexQuery(
                    range: selectedRange,
                    sourceIDs: sourceIDs
                ))
                let earliest = await indexService.earliestEventTimestamp(sourceIDs: sourceIDs)
                guard !Task.isCancelled else { return }
                if revision == self.configurationRevision,
                   selectedDateRevision == self.dateQueryRevision,
                   selectedRange == self.dateRange,
                   sourceIDs == self.enabledSourceIDs {
                    loaded = Self.withholdingProvisionalPricing(loaded)
                    self.earliestUsageDay = earliest
                    self.publish(loaded, sourceIDs: sourceIDs, dateRange: selectedRange, refreshedAt: Date())
                }
            }
            if contextStillCurrent,
               selectedDateRevision != self.dateQueryRevision,
               result.changedFiles > 0 || result.removedFiles > 0 || result.metadataChanged {
                // The user changed dates while the writer was active. Query
                // the newly committed generation for the current range rather
                // than allowing the earlier read snapshot to remain visible.
                await self.loadCompactSummary()
            }
            if revision == self.configurationRevision, sourceIDs == self.enabledSourceIDs {
                self.lastRefresh = Date()
                self.isIndexIncomplete = result.didReachTimeLimit
                self.staleSourceIDs = result.staleSourceIDs.intersection(sourceIDs)
                if result.didReachTimeLimit,
                   self.canRetryTimedOutRefresh {
                    // A fresh cache may finish one provider just before the
                    // deadline. Continue once with the completed source now
                    // cheap to skip; never turn an unreadable root into a loop.
                    self.canRetryTimedOutRefresh = false
                    let retry = RefreshIntent(changedPaths: nil)
                    if self.pendingRefresh == nil { self.pendingRefresh = retry }
                    else { self.pendingRefresh?.merge(retry) }
                } else if !result.didReachTimeLimit {
                    self.canRetryTimedOutRefresh = true
                }
            }
            self.finishRefresh()
        }
    }

    private func publish(
        _ value: UsageSummary,
        sourceIDs: Set<String>,
        dateRange: UsageDateRange,
        refreshedAt: Date
    ) {
        if value != summary {
            // Views opt into transitions only while their window is active.
            // Publishing a global animation transaction would keep a hidden
            // MenuBarExtra rendering after its panel has closed.
            summary = value
        }
        displayedSourceIDs = sourceIDs
        displayedDateRange = dateRange
        hasLoadedSummary = true
        if dateRange.isAllTime {
            WoolSnapshotCache.save(summary: value, sourceIDs: sourceIDs, updatedAt: refreshedAt)
        }
    }

    /// Bounded thread snapshots are useful for an immediate processed-token
    /// headline, but they omit inherited child work and cannot preserve every
    /// request's active model. Legacy day rollups also cannot price precise
    /// windows until replay completes. Never present either as exact pricing.
    private static func withholdingProvisionalPricing(_ value: UsageSummary) -> UsageSummary {
        guard value.isProvisional else { return value }
        var result = value
        result.apiUSD = 0
        result.codexCredits = 0
        for index in result.models.indices {
            result.models[index].apiUSD = 0
            result.models[index].codexCredits = 0
        }
        for index in result.accounts.indices {
            result.accounts[index].apiUSD = 0
            result.accounts[index].apiCostBreakdown = nil
            result.accounts[index].codexCredits = 0
        }
        for index in result.subagents.indices {
            result.subagents[index].apiUSD = 0
            result.subagents[index].codexCredits = 0
        }
        for index in result.days.indices {
            result.days[index].apiUSD = 0
            result.days[index].codexCredits = 0
        }
        return result
    }

    private func finishRefresh() {
        activeRefreshTask = nil
        for sourceID in securityScopesToStop { deactivateSecurityScope(for: sourceID) }
        securityScopesToStop.removeAll()
        guard let next = pendingRefresh else {
            isRefreshing = false
            return
        }
        pendingRefresh = nil
        activeRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.queuedRefreshDelay)
            guard !Task.isCancelled, let self else { return }
            self.activeRefreshTask = nil
            self.startRefresh(next)
        }
    }

    private func configurationDidChange() {
        configurationRevision &+= 1
        canRetryTimedOutRefresh = true
        saveSources()
        updateFileWatcher()
        let sourceIDs = enabledSourceIDs
        if sourceIDs.isEmpty {
            summary = UsageSummary()
            earliestUsageDay = nil
            displayedSourceIDs = sourceIDs
            hasLoadedSummary = true
        } else if dateRange.isAllTime, let cached = WoolSnapshotCache.load(sourceIDs: sourceIDs) {
            summary = cached.summary
            displayedSourceIDs = sourceIDs
            displayedDateRange = .allTime
            hasLoadedSummary = true
        }

        sourceChangeTask?.cancel()
        sourceChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadCompactSummary()
            guard !Task.isCancelled else { return }
            self.requestRefresh(RefreshIntent(changedPaths: nil))
        }
    }

    private var enabledSourceIDs: Set<String> {
        Set(sources.filter(\.enabled).map(\.id))
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    private func activateSecurityScope(for index: Int) -> Bool {
        guard let bookmark = sources[index].bookmarkData else {
            return ProviderRootDiscovery.isReadableDirectory(sources[index].rootPath)
        }
        guard let url = Self.resolveBookmark(bookmark, source: &sources[index]),
              url.startAccessingSecurityScopedResource() else { return false }
        activeSecurityScopedURLs[sources[index].id] = url
        return true
    }

    private func deactivateSecurityScope(for sourceID: String) {
        activeSecurityScopedURLs.removeValue(forKey: sourceID)?.stopAccessingSecurityScopedResource()
    }

    private func updateFileWatcher() {
        let paths = sources.filter(\.enabled).flatMap { source -> [String] in
            let root = URL(fileURLWithPath: source.rootPath, isDirectory: true)
            let candidates = source.provider == .codex
                ? [root.appendingPathComponent("sessions", isDirectory: true),
                   root.appendingPathComponent("archived_sessions", isDirectory: true)]
                : [root.appendingPathComponent("projects", isDirectory: true)]
            return candidates.compactMap { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url.path : nil
            }
        }
        fileWatcher?.update(paths: paths)
    }

    private func providerFilesChanged(paths: [String]) {
        let relevant = paths.filter {
            let extensionName = URL(fileURLWithPath: $0).pathExtension
            return extensionName.isEmpty || extensionName == "jsonl"
        }
        guard !relevant.isEmpty else { return }
        pendingProviderPaths.formUnion(relevant)
        fileChangeRevision &+= 1
        if firstPendingChangeAt == nil { firstPendingChangeAt = .now }
        guard fileChangeTask == nil else { return }

        fileChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var observedRevision = self.fileChangeRevision
            while !Task.isCancelled {
                let first = self.firstPendingChangeAt ?? .now
                let elapsed = first.duration(to: .now)
                if elapsed >= Self.fileMaximumLatency { break }
                try? await Task.sleep(for: min(Self.fileQuietPeriod, Self.fileMaximumLatency - elapsed))
                guard !Task.isCancelled else { return }
                if observedRevision == self.fileChangeRevision { break }
                observedRevision = self.fileChangeRevision
            }
            let pending = self.pendingProviderPaths
            self.pendingProviderPaths.removeAll()
            self.firstPendingChangeAt = nil
            self.fileChangeTask = nil
            guard !pending.isEmpty else { return }
            self.requestRefresh(RefreshIntent(changedPaths: pending))
        }
    }

    private func startSafetyRefreshes() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // FSEvents normally provides prompt, path-scoped updates. Keep
                // this low-frequency reconciliation running as a correctness
                // backstop for dropped events and streams lost after wake.
                try? await Task.sleep(for: Self.safetyRefreshInterval)
                guard !Task.isCancelled, let self else { return }
                self.requestRefresh(RefreshIntent(changedPaths: nil))
            }
        }
    }
}
