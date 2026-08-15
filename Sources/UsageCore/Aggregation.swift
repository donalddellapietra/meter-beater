import Foundation

public enum UsageAggregator {
    public static func accountKey(provider: Provider, accountID: String, sourceID: String, currentAuthAccountID: String? = nil, attributionConfidence: AttributionConfidence = .sourceOnly, attributionBasis: AttributionBasis = .none) -> String {
        "\(provider.rawValue):\(sourceID):\(accountID):current-auth=\(currentAuthAccountID ?? "none"):\(attributionConfidence.rawValue):\(attributionBasis.rawValue)"
    }

    public static func summarize(_ events: [UsageEvent], calendar: Calendar = .current) -> UsageSummary {
        var summary = UsageSummary()
        var models: [String: ModelUsageBreakdown] = [:]
        var accounts: [String: AccountUsageBreakdown] = [:]
        var subagents: [String: SubagentUsageBreakdown] = [:]
        var days: [String: DailyUsageBreakdown] = [:]
        var sessions = Set<String>()

        for event in events {
            let recordCount = event.recordCount
            sessions.insert("\(event.provider.rawValue):\(event.sourceID):\(event.sessionID)")

            let quote = UsageAccounting.quote(
                usage: event.usage,
                pricingContext: event.pricingContext,
                provider: event.provider,
                model: event.model,
                at: event.timestamp
            )
            UsageAccounting.recordTotals(
                usage: event.usage,
                recordCount: recordCount,
                subagentRecordCount: event.isSubagent ? recordCount : 0,
                attributionConfidence: event.attributionConfidence,
                quote: quote,
                in: &summary
            )

            var model = models[event.model] ?? ModelUsageBreakdown(id: event.model)
            UsageAccounting.record(usage: event.usage, recordCount: recordCount, quote: quote, in: &model)
            models[event.model] = model

            let accountKey = accountKey(provider: event.provider, accountID: event.accountID, sourceID: event.sourceID, currentAuthAccountID: event.currentAuthAccountID, attributionConfidence: event.attributionConfidence, attributionBasis: event.attributionBasis)
            var account = accounts[accountKey] ?? AccountUsageBreakdown(id: accountKey, provider: event.provider, sourceID: event.sourceID, accountID: event.accountID, currentAuthAccountID: event.currentAuthAccountID, attributionConfidence: event.attributionConfidence, attributionBasis: event.attributionBasis)
            UsageAccounting.record(usage: event.usage, recordCount: recordCount, quote: quote, in: &account)
            accounts[accountKey] = account

            if event.isSubagent {
                let parentSession = event.parentSessionID ?? "none"
                let subagentKey = "\(event.provider.rawValue):\(event.sourceID):\(event.sessionID):parent=\(parentSession)"
                var subagent = subagents[subagentKey] ?? SubagentUsageBreakdown(id: subagentKey, provider: event.provider, sourceID: event.sourceID, sessionID: event.sessionID, parentSessionID: event.parentSessionID)
                UsageAccounting.record(usage: event.usage, recordCount: recordCount, quote: quote, in: &subagent)
                subagents[subagentKey] = subagent
            }

            let day = calendar.dateComponents([.year, .month, .day], from: event.timestamp)
            let dayKey = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            var daily = days[dayKey] ?? DailyUsageBreakdown(day: dayKey)
            UsageAccounting.record(usage: event.usage, quote: quote, in: &daily)
            days[dayKey] = daily
        }

        summary.sessionCount = sessions.count
        summary.models = models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        summary.accounts = accounts.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        summary.subagents = subagents.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        summary.days = days.values.sorted { $0.day < $1.day }
        return summary
    }
}
