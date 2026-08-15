import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"
}

public enum AttributionConfidence: String, Codable, CaseIterable, Hashable, Sendable {
    case sessionVerified = "session-verified"
    case parentSession = "parent-session"
    case currentAuthOnly = "current-auth-only"
    case currentConfigOnly = "current-config-only"
    case sourceOnly = "source-only"
    case ambiguousSidechain = "ambiguous-sidechain"
    case ambiguousAccount = "ambiguous-account"

    public var displayName: String {
        switch self {
        case .sessionVerified: return "Session verified"
        case .parentSession: return "Inherited from parent"
        case .currentAuthOnly: return "Current auth only"
        case .currentConfigOnly: return "Current config only"
        case .sourceOnly: return "Source only"
        case .ambiguousSidechain: return "Unresolved sidechain"
        case .ambiguousAccount: return "Ambiguous account"
        }
    }
}

public enum AttributionBasis: String, Codable, CaseIterable, Hashable, Sendable {
    case claudeTelemetry = "claude-telemetry"
    case claudeSupportSession = "claude-support-session"
    case codexCurrentAuth = "codex-current-auth"
    case claudeCurrentConfig = "claude-current-config"
    case claudeAccountConflict = "claude-account-conflict"
    case parentSession = "parent-session"
    case none

    public var displayName: String {
        switch self {
        case .claudeTelemetry: return "Claude telemetry"
        case .claudeSupportSession: return "Claude session metadata"
        case .codexCurrentAuth: return "Current Codex auth"
        case .claudeCurrentConfig: return "Current Claude config"
        case .claudeAccountConflict: return "Conflicting Claude account metadata"
        case .parentSession: return "Parent session"
        case .none: return "None"
        }
    }
}

public struct UsageSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public let provider: Provider
    public var rootPath: String
    public var enabled: Bool
    public var bookmarkData: Data?
    public var monthlySubscriptionUSD: Double?

    public init(id: String? = nil, displayName: String, provider: Provider, rootPath: String, enabled: Bool = true, bookmarkData: Data? = nil, monthlySubscriptionUSD: Double? = nil) {
        self.id = id ?? Self.stableID(provider: provider, rootPath: rootPath)
        self.displayName = displayName
        self.provider = provider
        self.rootPath = rootPath
        self.enabled = enabled
        self.bookmarkData = bookmarkData
        self.monthlySubscriptionUSD = monthlySubscriptionUSD
    }

    public static func stableID(provider: Provider, rootPath: String) -> String {
        "\(provider.rawValue.lowercased()):\(URL(fileURLWithPath: rootPath).standardizedFileURL.path)"
    }
}

/// Usage normalized for cross-provider reporting.
/// Codex reports input_tokens including cached input, so the Codex adapter stores
/// the non-cached portion in inputTokens and cached input separately. Claude's
/// input_tokens excludes cache reads/writes, so its adapter stores it directly.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var cacheWrite5mInputTokens: Int64
    public var cacheWrite1hInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWrite5mInputTokens: Int64 = 0,
        cacheWrite1hInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWrite5mInputTokens = cacheWrite5mInputTokens
        self.cacheWrite1hInputTokens = cacheWrite1hInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public var contextInputTokens: Int64 {
        inputTokens + cachedInputTokens + cacheWrite5mInputTokens + cacheWrite1hInputTokens
    }

    public var totalTokens: Int64 {
        contextInputTokens + outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWrite5mInputTokens: lhs.cacheWrite5mInputTokens + rhs.cacheWrite5mInputTokens,
            cacheWrite1hInputTokens: lhs.cacheWrite1hInputTokens + rhs.cacheWrite1hInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens
        )
    }
}

/// Request-level token subsets that affect public API pricing without changing
/// the raw usage totals shown to the user. A long-context request is billed at
/// the model's base rates plus the incremental premium represented here.
///
/// Keeping this separate from `TokenUsage` prevents pricing-only categories
/// from being counted as tokens a second time, and lets daily SQLite rollups
/// preserve exact request-level premiums.
public struct APIPricingContext: Codable, Hashable, Sendable {
    public var longContextUsage: TokenUsage

    public init(longContextUsage: TokenUsage = TokenUsage()) {
        self.longContextUsage = longContextUsage
    }

    public static func + (lhs: APIPricingContext, rhs: APIPricingContext) -> APIPricingContext {
        APIPricingContext(longContextUsage: lhs.longContextUsage + rhs.longContextUsage)
    }
}

/// Public API rate-card value split into the three categories exposed by the
/// compact menu UI. Cached input combines cache reads and cache creation, but
/// each counter is priced at its own model-specific rate before aggregation.
public struct APIUsageCostBreakdown: Codable, Hashable, Sendable {
    public var uncachedInputUSD: Double
    public var cachedInputUSD: Double
    public var outputUSD: Double

    public init(
        uncachedInputUSD: Double = 0,
        cachedInputUSD: Double = 0,
        outputUSD: Double = 0
    ) {
        self.uncachedInputUSD = uncachedInputUSD
        self.cachedInputUSD = cachedInputUSD
        self.outputUSD = outputUSD
    }

    public var totalUSD: Double {
        uncachedInputUSD + cachedInputUSD + outputUSD
    }

    public static func + (lhs: APIUsageCostBreakdown, rhs: APIUsageCostBreakdown) -> APIUsageCostBreakdown {
        APIUsageCostBreakdown(
            uncachedInputUSD: lhs.uncachedInputUSD + rhs.uncachedInputUSD,
            cachedInputUSD: lhs.cachedInputUSD + rhs.cachedInputUSD,
            outputUSD: lhs.outputUSD + rhs.outputUSD
        )
    }
}

public struct UsageEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// Provider-owned response identity. Claude preserves this message ID when
    /// a resumed session copies prior transcript history, allowing those
    /// copies to be counted once without relying on file paths or timestamps.
    public let providerEventID: String?
    public let provider: Provider
    public let sourceID: String
    public let accountID: String
    /// Codex's currently observed auth account. This is never historical proof
    /// for transcript events and is intentionally separate from accountID.
    public let currentAuthAccountID: String?
    public let attributionConfidence: AttributionConfidence
    public let attributionBasis: AttributionBasis
    public let sessionID: String
    public let parentSessionID: String?
    public let timestamp: Date
    public let model: String
    public let sourcePath: String
    public let byteOffset: Int64
    public let isSubagent: Bool
    /// Number of source records represented by this row. Normal transcript
    /// events use one; large archives may use compact day/session rollups.
    public let eventCount: Int
    public let usage: TokenUsage
    public let pricingContext: APIPricingContext

    /// Logical source-record count represented by this event row. Normal
    /// transcript events are one; compact archive rollups can represent many.
    public var recordCount: Int { eventCount }

    public init(
        id: String,
        providerEventID: String? = nil,
        provider: Provider,
        sourceID: String,
        accountID: String,
        currentAuthAccountID: String? = nil,
        attributionConfidence: AttributionConfidence = .sourceOnly,
        attributionBasis: AttributionBasis = .none,
        sessionID: String,
        parentSessionID: String? = nil,
        timestamp: Date,
        model: String,
        sourcePath: String,
        byteOffset: Int64 = 0,
        isSubagent: Bool = false,
        eventCount: Int = 1,
        usage: TokenUsage,
        pricingContext: APIPricingContext = APIPricingContext()
    ) {
        self.id = id
        self.providerEventID = providerEventID
        self.provider = provider
        self.sourceID = sourceID
        self.accountID = accountID
        self.currentAuthAccountID = currentAuthAccountID
        self.attributionConfidence = attributionConfidence
        self.attributionBasis = attributionBasis
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.timestamp = timestamp
        self.model = model
        self.sourcePath = sourcePath
        self.byteOffset = byteOffset
        self.isSubagent = isSubagent
        self.eventCount = max(1, eventCount)
        self.usage = usage
        self.pricingContext = pricingContext
    }
}

public struct ModelUsageBreakdown: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var usage: TokenUsage
    public var eventCount: Int
    public var apiUSD: Double
    public var codexCredits: Double

    public init(id: String, usage: TokenUsage = TokenUsage(), eventCount: Int = 0, apiUSD: Double = 0, codexCredits: Double = 0) {
        self.id = id
        self.usage = usage
        self.eventCount = eventCount
        self.apiUSD = apiUSD
        self.codexCredits = codexCredits
    }
}

public struct AccountUsageBreakdown: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var provider: Provider
    public var sourceID: String
    public var accountID: String
    public var currentAuthAccountID: String?
    public var attributionConfidence: AttributionConfidence
    public var attributionBasis: AttributionBasis
    public var usage: TokenUsage
    public var eventCount: Int
    public var apiUSD: Double
    public var apiCostBreakdown: APIUsageCostBreakdown?
    public var codexCredits: Double

    public init(id: String, provider: Provider, sourceID: String = "", accountID: String = "unattributed", currentAuthAccountID: String? = nil, attributionConfidence: AttributionConfidence = .sourceOnly, attributionBasis: AttributionBasis = .none, usage: TokenUsage = TokenUsage(), eventCount: Int = 0, apiUSD: Double = 0, apiCostBreakdown: APIUsageCostBreakdown? = nil, codexCredits: Double = 0) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.accountID = accountID
        self.currentAuthAccountID = currentAuthAccountID
        self.attributionConfidence = attributionConfidence
        self.attributionBasis = attributionBasis
        self.usage = usage
        self.eventCount = eventCount
        self.apiUSD = apiUSD
        self.apiCostBreakdown = apiCostBreakdown
        self.codexCredits = codexCredits
    }
}

public struct SubagentUsageBreakdown: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var provider: Provider
    public var sourceID: String
    public var sessionID: String
    public var parentSessionID: String?
    public var usage: TokenUsage
    public var eventCount: Int
    public var apiUSD: Double
    public var codexCredits: Double

    public init(id: String, provider: Provider, sourceID: String, sessionID: String, parentSessionID: String? = nil, usage: TokenUsage = TokenUsage(), eventCount: Int = 0, apiUSD: Double = 0, codexCredits: Double = 0) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.usage = usage
        self.eventCount = eventCount
        self.apiUSD = apiUSD
        self.codexCredits = codexCredits
    }
}

public struct DailyUsageBreakdown: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var day: String
    public var usage: TokenUsage
    public var apiUSD: Double
    public var codexCredits: Double

    public init(day: String, usage: TokenUsage = TokenUsage(), apiUSD: Double = 0, codexCredits: Double = 0) {
        self.id = day
        self.day = day
        self.usage = usage
        self.apiUSD = apiUSD
        self.codexCredits = codexCredits
    }
}

/// Diagnostics emitted by provider adapters when a transcript cannot be
/// interpreted as a perfectly ordered stream of cumulative counters.
public struct AccountingDiagnostics: Codable, Hashable, Sendable {
    public var duplicateSnapshots: Int = 0
    public var staleSnapshots: Int = 0
    public var inheritedBaselines: Int = 0
    public var ambiguousResets: Int = 0

    public init(duplicateSnapshots: Int = 0, staleSnapshots: Int = 0, inheritedBaselines: Int = 0, ambiguousResets: Int = 0) {
        self.duplicateSnapshots = duplicateSnapshots
        self.staleSnapshots = staleSnapshots
        self.inheritedBaselines = inheritedBaselines
        self.ambiguousResets = ambiguousResets
    }

    public var issueCount: Int {
        duplicateSnapshots + staleSnapshots + inheritedBaselines + ambiguousResets
    }

    public var hasUnresolvedIssues: Bool {
        // Successfully excluded inherited fork baselines are evidence that the
        // ownership fence ran; they are not themselves unresolved accounting.
        ambiguousResets > 0
    }

    public static func + (lhs: AccountingDiagnostics, rhs: AccountingDiagnostics) -> AccountingDiagnostics {
        AccountingDiagnostics(
            duplicateSnapshots: lhs.duplicateSnapshots + rhs.duplicateSnapshots,
            staleSnapshots: lhs.staleSnapshots + rhs.staleSnapshots,
            inheritedBaselines: lhs.inheritedBaselines + rhs.inheritedBaselines,
            ambiguousResets: lhs.ambiguousResets + rhs.ambiguousResets
        )
    }
}

public struct UsageSummary: Codable, Hashable, Sendable {
    public var usage: TokenUsage = TokenUsage()
    public var eventCount: Int = 0
    public var sessionCount: Int = 0
    public var subagentEventCount: Int = 0
    public var apiUSD: Double = 0
    public var codexCredits: Double = 0
    public var unpricedEventCount: Int = 0
    public var attributionCounts: [String: Int] = [:]
    public var models: [ModelUsageBreakdown] = []
    public var accounts: [AccountUsageBreakdown] = []
    public var subagents: [SubagentUsageBreakdown] = []
    public var days: [DailyUsageBreakdown] = []
    public var warnings: [String] = []
    public var accounting: AccountingDiagnostics? = nil
    public var isProvisional: Bool = false

    public init() {}
}

/// A portable aggregate report emitted by the desktop app. It intentionally
/// contains source labels but never absolute paths, security-scoped bookmark
/// bytes, or provider transcript content.
public struct UsageExportSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let provider: Provider
    public let enabled: Bool
    public let monthlySubscriptionUSD: Double?

    public init(id: String, source: UsageSource) {
        self.id = id
        displayName = source.displayName
        provider = source.provider
        enabled = source.enabled
        monthlySubscriptionUSD = source.monthlySubscriptionUSD
    }
}

public struct UsageExportSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let start: Date
    public let endExclusive: Date
    public let timezone: String
    public let sources: [UsageExportSource]
    public let summary: UsageSummary
    public let pricingSnapshotDate: String
    public let pricingSources: [String]
    public let monthlySubscriptionUSD: Double
    public let proratedSubscriptionUSD: Double
    public let apiValueMultiple: Double?

    public init(
        generatedAt: Date = Date(),
        start: Date,
        endExclusive: Date,
        timezone: String,
        sources: [UsageSource],
        summary: UsageSummary,
        monthlySubscriptionUSD: Double,
        proratedSubscriptionUSD: Double,
        apiValueMultiple: Double?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.start = start
        self.endExclusive = endExclusive
        self.timezone = timezone
        let sourceIDs = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, "source-\($0.offset + 1)") })
        self.sources = sources.enumerated().map { UsageExportSource(id: sourceIDs[$0.element.id]!, source: $0.element) }
        self.summary = Self.sanitizedSummary(summary, sourceIDs: sourceIDs)
        pricingSnapshotDate = PricingCatalog.snapshotDate
        pricingSources = PricingCatalog.officialSources
        self.monthlySubscriptionUSD = monthlySubscriptionUSD
        self.proratedSubscriptionUSD = proratedSubscriptionUSD
        self.apiValueMultiple = apiValueMultiple
    }

    private static func sanitizedSummary(_ original: UsageSummary, sourceIDs: [String: String]) -> UsageSummary {
        var sanitized = original
        var accountIdentityIDs: [String: String] = [:]
        var currentAuthIDs: [String: String] = [:]
        func anonymized(_ value: String, prefix: String, map: inout [String: String]) -> String {
            if value == "unattributed" || value == "ambiguous" { return value }
            if let existing = map[value] { return existing }
            let replacement = "\(prefix)-\(map.count + 1)"
            map[value] = replacement
            return replacement
        }
        sanitized.accounts = original.accounts.enumerated().map { index, account in
            AccountUsageBreakdown(
                id: "account-\(index + 1)",
                provider: account.provider,
                sourceID: sourceIDs[account.sourceID] ?? "unknown-source",
                accountID: anonymized(account.accountID, prefix: "account", map: &accountIdentityIDs),
                currentAuthAccountID: account.currentAuthAccountID.map { anonymized($0, prefix: "current-auth", map: &currentAuthIDs) },
                attributionConfidence: account.attributionConfidence,
                attributionBasis: account.attributionBasis,
                usage: account.usage,
                eventCount: account.eventCount,
                apiUSD: account.apiUSD,
                apiCostBreakdown: account.apiCostBreakdown,
                codexCredits: account.codexCredits
            )
        }
        // Aggregate warnings may contain provider paths; the portable report
        // does not need to reproduce those diagnostics.
        sanitized.warnings = []
        return sanitized
    }
}

public enum DateParsing {
    private static let fractionalISO8601 = SendableISO8601DateFormatter(options: [.withInternetDateTime, .withFractionalSeconds])
    private static let plainISO8601 = SendableISO8601DateFormatter(options: [.withInternetDateTime])

    public static func parse(_ value: String) -> Date? {
        fastUTC(value) ?? fractionalISO8601.date(from: value) ?? plainISO8601.date(from: value)
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        fastUTC(bytes)
    }

    /// Provider timestamps are overwhelmingly UTC ISO-8601 strings. Avoiding
    /// ISO8601DateFormatter here matters: a full history can contain millions
    /// of records and the formatter is comparatively expensive under the
    /// parallel importer.
    private static func fastUTC(_ value: String) -> Date? {
        guard let result = value.utf8.withContiguousStorageIfAvailable({ fastUTC($0) }) else { return nil }
        return result
    }

    private static func fastUTC(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        guard bytes.count >= 20,
              bytes[4] == 0x2D, bytes[7] == 0x2D,
              bytes[10] == 0x54, bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int64? {
            guard start + count <= bytes.count else { return nil }
            var value: Int64 = 0
            for index in start..<(start + count) {
                guard bytes[index] >= 0x30, bytes[index] <= 0x39 else { return nil }
                value = value * 10 + Int64(bytes[index] - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2), let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31, hour < 24, minute < 60, second < 60 else { return nil }
        let timezoneIndex: Int
        var fraction: Double = 0
        if bytes[19] == 0x5A {
            timezoneIndex = 19
        } else if bytes[19] == 0x2E {
            var index = 20
            var fractionValue: Int64 = 0
            var divisor: Double = 1
            var digitsRead = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39, digitsRead < 9 {
                fractionValue = fractionValue * 10 + Int64(bytes[index] - 0x30)
                divisor *= 10
                digitsRead += 1
                index += 1
            }
            guard digitsRead > 0, index < bytes.count, bytes[index] == 0x5A else { return nil }
            fraction = Double(fractionValue) / divisor
            timezoneIndex = index
        } else {
            return nil
        }
        guard timezoneIndex == bytes.count - 1 else { return nil }

        // Gregorian days from civil date, relative to 1970-01-01.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthOfYear = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthOfYear + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468
        let timestamp = Double(days * 86400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: timestamp)
    }
}

private final class SendableISO8601DateFormatter: @unchecked Sendable {
    private let formatter: ISO8601DateFormatter

    init(options: ISO8601DateFormatter.Options) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
    }

    func date(from value: String) -> Date? { formatter.date(from: value) }
}
