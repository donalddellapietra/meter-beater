import Foundation

/// Central accounting boundary shared by transcript summaries and SQLite
/// aggregates. Provider adapters normalize raw counters; this type is the only
/// place that turns normalized usage into priced totals.
public enum UsageAccounting {
    public static func quote(
        usage: TokenUsage,
        pricingContext: APIPricingContext = APIPricingContext(),
        provider: Provider,
        model: String,
        at date: Date
    ) -> UsagePriceQuote {
        PricingCatalog.quote(
            usage,
            pricingContext: pricingContext,
            provider: provider,
            model: model,
            at: date
        )
    }

    static func recordTotals(
        usage: TokenUsage,
        recordCount: Int,
        subagentRecordCount: Int = 0,
        attributionConfidence: AttributionConfidence? = nil,
        quote: UsagePriceQuote,
        in summary: inout UsageSummary
    ) {
        summary.usage = summary.usage + usage
        summary.eventCount += recordCount
        summary.subagentEventCount += subagentRecordCount
        if let attributionConfidence {
            summary.attributionCounts[attributionConfidence.rawValue, default: 0] += recordCount
        }
        if let apiUSD = quote.apiUSD {
            summary.apiUSD += apiUSD
        } else {
            summary.unpricedEventCount += recordCount
        }
        summary.codexCredits += quote.codexCredits ?? 0
    }

    static func record(
        usage: TokenUsage,
        recordCount: Int,
        quote: UsagePriceQuote,
        in breakdown: inout ModelUsageBreakdown
    ) {
        breakdown.usage = breakdown.usage + usage
        breakdown.eventCount += recordCount
        breakdown.apiUSD += quote.apiUSD ?? 0
        breakdown.codexCredits += quote.codexCredits ?? 0
    }

    static func record(
        usage: TokenUsage,
        recordCount: Int,
        quote: UsagePriceQuote,
        in breakdown: inout AccountUsageBreakdown
    ) {
        breakdown.usage = breakdown.usage + usage
        breakdown.eventCount += recordCount
        breakdown.apiUSD += quote.apiUSD ?? 0
        if let apiCost = quote.apiCost {
            breakdown.apiCostBreakdown = (breakdown.apiCostBreakdown ?? APIUsageCostBreakdown()) + apiCost
        }
        breakdown.codexCredits += quote.codexCredits ?? 0
    }

    static func record(
        usage: TokenUsage,
        recordCount: Int,
        quote: UsagePriceQuote,
        in breakdown: inout SubagentUsageBreakdown
    ) {
        breakdown.usage = breakdown.usage + usage
        breakdown.eventCount += recordCount
        breakdown.apiUSD += quote.apiUSD ?? 0
        breakdown.codexCredits += quote.codexCredits ?? 0
    }

    static func record(
        usage: TokenUsage,
        quote: UsagePriceQuote,
        in breakdown: inout DailyUsageBreakdown
    ) {
        breakdown.usage = breakdown.usage + usage
        breakdown.apiUSD += quote.apiUSD ?? 0
        breakdown.codexCredits += quote.codexCredits ?? 0
    }
}
