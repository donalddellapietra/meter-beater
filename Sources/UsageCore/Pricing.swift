import Foundation

public struct PricingRate: Codable, Hashable, Sendable {
    public let inputUSDPerMillion: Double
    public let cachedReadUSDPerMillion: Double
    public let cacheWrite5mUSDPerMillion: Double
    public let cacheWrite1hUSDPerMillion: Double
    public let outputUSDPerMillion: Double
    public let codexInputCreditsPerMillion: Double?
    public let codexCachedCreditsPerMillion: Double?
    public let codexOutputCreditsPerMillion: Double?
    public let longContextThresholdTokens: Int64?
    public let longContextInputMultiplier: Double
    public let longContextOutputMultiplier: Double

    public init(
        inputUSDPerMillion: Double,
        cachedReadUSDPerMillion: Double,
        cacheWrite5mUSDPerMillion: Double = 0,
        cacheWrite1hUSDPerMillion: Double = 0,
        outputUSDPerMillion: Double,
        codexInputCreditsPerMillion: Double? = nil,
        codexCachedCreditsPerMillion: Double? = nil,
        codexOutputCreditsPerMillion: Double? = nil,
        longContextThresholdTokens: Int64? = nil,
        longContextInputMultiplier: Double = 1,
        longContextOutputMultiplier: Double = 1
    ) {
        self.inputUSDPerMillion = inputUSDPerMillion
        self.cachedReadUSDPerMillion = cachedReadUSDPerMillion
        self.cacheWrite5mUSDPerMillion = cacheWrite5mUSDPerMillion
        self.cacheWrite1hUSDPerMillion = cacheWrite1hUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
        self.codexInputCreditsPerMillion = codexInputCreditsPerMillion
        self.codexCachedCreditsPerMillion = codexCachedCreditsPerMillion
        self.codexOutputCreditsPerMillion = codexOutputCreditsPerMillion
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
    }
}

/// One authoritative pricing result used by every summary path. Returning the
/// category breakdown and credits together prevents callers from independently
/// re-running or subtly changing the pricing equation.
public struct UsagePriceQuote: Codable, Hashable, Sendable {
    public let apiCost: APIUsageCostBreakdown?
    public let codexCredits: Double?

    public init(apiCost: APIUsageCostBreakdown?, codexCredits: Double?) {
        self.apiCost = apiCost
        self.codexCredits = codexCredits
    }

    public var apiUSD: Double? { apiCost?.totalUSD }
}

public struct ServingCostEstimate: Codable, Hashable, Sendable {
    public var lowerUSD: Double
    public var midpointUSD: Double
    public var upperUSD: Double

    public init(lowerUSD: Double = 0, midpointUSD: Double = 0, upperUSD: Double = 0) {
        self.lowerUSD = lowerUSD
        self.midpointUSD = midpointUSD
        self.upperUSD = upperUSD
    }

    public static func + (lhs: ServingCostEstimate, rhs: ServingCostEstimate) -> ServingCostEstimate {
        ServingCostEstimate(
            lowerUSD: lhs.lowerUSD + rhs.lowerUSD,
            midpointUSD: lhs.midpointUSD + rhs.midpointUSD,
            upperUSD: lhs.upperUSD + rhs.upperUSD
        )
    }
}

/// A directional estimate of direct inference-serving cost, inferred by
/// reversing published model-level API margin estimates. It is not provider
/// accounting and intentionally excludes training, R&D, and subscription
/// revenue. Keep the snapshot and source beside the assumptions.
public enum ServingCostCatalog {
    public static let snapshotDate = "2026-02-27"
    public static let methodologySource = "https://pitchbook.brightspotcdn.com/19/05/d3a0b3a14409927c9c73e5de389f/q1-2026-pitchbook-analyst-note-ranking-the-ai-giants-a-new-framework-for-the-frontier-five-preview.pdf"

    public static func defaultMidpointRatio(for provider: Provider) -> Double {
        defaultBand(for: provider).midpoint
    }

    public static func estimate(
        apiUSD: Double,
        provider: Provider,
        midpointRatio: Double? = nil
    ) -> ServingCostEstimate {
        guard apiUSD.isFinite, apiUSD > 0 else { return ServingCostEstimate() }
        let defaults = defaultBand(for: provider)
        let requested = midpointRatio.flatMap { $0.isFinite ? $0 : nil } ?? defaults.midpoint
        let midpoint = min(max(requested, 0), 1)
        let ratio = (
            lower: max(0, midpoint - (defaults.midpoint - defaults.lower)),
            midpoint: midpoint,
            upper: min(1, midpoint + (defaults.upper - defaults.midpoint))
        )
        return ServingCostEstimate(
            lowerUSD: apiUSD * ratio.lower,
            midpointUSD: apiUSD * ratio.midpoint,
            upperUSD: apiUSD * ratio.upper
        )
    }

    private static func defaultBand(for provider: Provider) -> (lower: Double, midpoint: Double, upper: Double) {
        switch provider {
        case .codex:
            // OpenAI flagship model margins of roughly 50–60% imply direct
            // serving costs around 40–50% of public API revenue.
            return (0.40, 0.45, 0.50)
        case .claude:
            // Anthropic Opus/Sonnet margins of roughly 40–55% imply the wider
            // 45–60% direct serving-cost band.
            return (0.45, 0.525, 0.60)
        }
    }
}

public enum PricingCatalog {
    public static let snapshotDate = "2026-08-03"
    public static let officialSources = [
        "https://developers.openai.com/api/docs/models/compare",
        "https://help.openai.com/en/articles/20001106-codex-rate-card",
        "https://platform.claude.com/docs/en/about-claude/pricing"
    ]
    static let sonnet5RateChange = DateParsing.parse("2026-09-01T00:00:00Z") ?? Date.distantFuture

    public static func rate(for model: String, provider: Provider, at date: Date = Date()) -> PricingRate? {
        let m = canonicalModel(model)
        // OpenAI explicitly marks this Codex research preview as unpriced;
        // borrowing the GPT-5.3-Codex rate would turn an unknown value into a
        // misleadingly precise estimate.
        if provider == .codex && m == "gpt-5.3-codex-spark" { return nil }
        switch provider {
        case .codex:
            return codexRates[m]
        case .claude:
            if m == "claude-sonnet-5" {
                let cutoff = DateParsing.parse("2026-09-01T00:00:00Z") ?? date
                return date < cutoff
                    ? PricingRate(inputUSDPerMillion: 2, cachedReadUSDPerMillion: 0.2, cacheWrite5mUSDPerMillion: 2.5, cacheWrite1hUSDPerMillion: 4, outputUSDPerMillion: 10)
                    : PricingRate(inputUSDPerMillion: 3, cachedReadUSDPerMillion: 0.3, cacheWrite5mUSDPerMillion: 3.75, cacheWrite1hUSDPerMillion: 6, outputUSDPerMillion: 15)
            }
            return claudeRates[m]
        }
    }

    public static func longContextThreshold(for model: String, provider: Provider) -> Int64? {
        rate(for: model, provider: provider)?.longContextThresholdTokens
    }

    public static func quote(
        _ usage: TokenUsage,
        pricingContext: APIPricingContext = APIPricingContext(),
        provider: Provider,
        model: String,
        at date: Date
    ) -> UsagePriceQuote {
        guard let rate = rate(for: model, provider: provider, at: date) else {
            return UsagePriceQuote(apiCost: nil, codexCredits: nil)
        }
        let million = 1_000_000.0
        let apiCost = apiCostBreakdown(usage, pricingContext: pricingContext, rate: rate)
        let credits: Double?
        if let input = rate.codexInputCreditsPerMillion,
           let cached = rate.codexCachedCreditsPerMillion,
           let output = rate.codexOutputCreditsPerMillion {
            credits = Double(usage.inputTokens) * input / million
                + Double(usage.cachedInputTokens) * cached / million
                + Double(usage.outputTokens) * output / million
        } else {
            credits = nil
        }
        return UsagePriceQuote(apiCost: apiCost, codexCredits: credits)
    }

    public static func estimate(_ usage: TokenUsage, provider: Provider, model: String, at date: Date) -> (apiUSD: Double?, codexCredits: Double?) {
        let quote = quote(usage, provider: provider, model: model, at: date)
        return (quote.apiUSD, quote.codexCredits)
    }

    public static func apiCostBreakdown(
        _ usage: TokenUsage,
        provider: Provider,
        model: String,
        at date: Date
    ) -> APIUsageCostBreakdown? {
        guard let rate = rate(for: model, provider: provider, at: date) else { return nil }
        return apiCostBreakdown(usage, pricingContext: APIPricingContext(), rate: rate)
    }

    private static func apiCostBreakdown(_ usage: TokenUsage, pricingContext: APIPricingContext, rate: PricingRate) -> APIUsageCostBreakdown {
        let million = 1_000_000.0
        var result = APIUsageCostBreakdown(
            uncachedInputUSD: Double(usage.inputTokens) * rate.inputUSDPerMillion / million,
            cachedInputUSD: (
                Double(usage.cachedInputTokens) * rate.cachedReadUSDPerMillion
                    + Double(usage.cacheWrite5mInputTokens) * rate.cacheWrite5mUSDPerMillion
                    + Double(usage.cacheWrite1hInputTokens) * rate.cacheWrite1hUSDPerMillion
            ) / million,
            outputUSD: Double(usage.outputTokens) * rate.outputUSDPerMillion / million
        )
        guard rate.longContextThresholdTokens != nil else { return result }
        let long = pricingContext.longContextUsage
        let inputPremium = max(0, rate.longContextInputMultiplier - 1)
        let outputPremium = max(0, rate.longContextOutputMultiplier - 1)
        result.uncachedInputUSD += Double(min(max(0, long.inputTokens), usage.inputTokens))
            * rate.inputUSDPerMillion * inputPremium / million
        result.cachedInputUSD += (
            Double(min(max(0, long.cachedInputTokens), usage.cachedInputTokens)) * rate.cachedReadUSDPerMillion
                + Double(min(max(0, long.cacheWrite5mInputTokens), usage.cacheWrite5mInputTokens)) * rate.cacheWrite5mUSDPerMillion
                + Double(min(max(0, long.cacheWrite1hInputTokens), usage.cacheWrite1hInputTokens)) * rate.cacheWrite1hUSDPerMillion
        ) * inputPremium / million
        result.outputUSD += Double(min(max(0, long.outputTokens), usage.outputTokens))
            * rate.outputUSDPerMillion * outputPremium / million
        return result
    }

    private static func canonicalModel(_ model: String) -> String {
        let lower = model.lowercased().split(separator: "[").first.map(String.init) ?? model.lowercased()
        if codexRates[lower] != nil || claudeRates[lower] != nil || lower == "claude-sonnet-5" { return lower }
        if lower.hasPrefix("gpt-5.3-codex-spark") { return "gpt-5.3-codex-spark" }
        if lower == "codex-auto-review" { return "gpt-5.3-codex" }
        let prefixes = [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4-mini", "gpt-5.4", "gpt-5.5", "gpt-5.3-codex", "gpt-5.2", "gpt-5.1-codex-mini", "gpt-5",
            "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-opus-4-1", "claude-opus-4", "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4", "claude-haiku-4-5", "claude-haiku-3-5"
        ]
        return prefixes.first(where: { lower.hasPrefix($0) }) ?? lower
    }

    private static let codexRates: [String: PricingRate] = [
        "gpt-5.6-sol": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 6.25, outputUSDPerMillion: 30, codexInputCreditsPerMillion: 125, codexCachedCreditsPerMillion: 12.5, codexOutputCreditsPerMillion: 750, longContextThresholdTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        // Codex credits are a separate subscription rate card, not API dollars
        // multiplied by a universal conversion. Terra and Luna intentionally
        // carry more subsidized credit rates than their API-equivalent prices.
        "gpt-5.6-terra": PricingRate(inputUSDPerMillion: 2.5, cachedReadUSDPerMillion: 0.25, cacheWrite5mUSDPerMillion: 3.125, cacheWrite1hUSDPerMillion: 3.125, outputUSDPerMillion: 15, codexInputCreditsPerMillion: 50, codexCachedCreditsPerMillion: 5, codexOutputCreditsPerMillion: 300, longContextThresholdTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.6-luna": PricingRate(inputUSDPerMillion: 1, cachedReadUSDPerMillion: 0.1, cacheWrite5mUSDPerMillion: 1.25, cacheWrite1hUSDPerMillion: 1.25, outputUSDPerMillion: 6, codexInputCreditsPerMillion: 5, codexCachedCreditsPerMillion: 0.5, codexOutputCreditsPerMillion: 30, longContextThresholdTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.5": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, outputUSDPerMillion: 30, codexInputCreditsPerMillion: 125, codexCachedCreditsPerMillion: 12.5, codexOutputCreditsPerMillion: 750, longContextThresholdTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.4": PricingRate(inputUSDPerMillion: 2.5, cachedReadUSDPerMillion: 0.25, outputUSDPerMillion: 15, codexInputCreditsPerMillion: 62.5, codexCachedCreditsPerMillion: 6.25, codexOutputCreditsPerMillion: 375, longContextThresholdTokens: 272_000, longContextInputMultiplier: 2, longContextOutputMultiplier: 1.5),
        "gpt-5.4-mini": PricingRate(inputUSDPerMillion: 0.75, cachedReadUSDPerMillion: 0.075, outputUSDPerMillion: 4.5, codexInputCreditsPerMillion: 18.75, codexCachedCreditsPerMillion: 1.875, codexOutputCreditsPerMillion: 113),
        "gpt-5.3-codex": PricingRate(inputUSDPerMillion: 1.75, cachedReadUSDPerMillion: 0.175, outputUSDPerMillion: 14, codexInputCreditsPerMillion: 43.75, codexCachedCreditsPerMillion: 4.375, codexOutputCreditsPerMillion: 350),
        "gpt-5.2": PricingRate(inputUSDPerMillion: 1.75, cachedReadUSDPerMillion: 0.175, outputUSDPerMillion: 14, codexInputCreditsPerMillion: 43.75, codexCachedCreditsPerMillion: 4.375, codexOutputCreditsPerMillion: 350),
        "gpt-5.1-codex-mini": PricingRate(inputUSDPerMillion: 0.25, cachedReadUSDPerMillion: 0.025, outputUSDPerMillion: 2),
        "gpt-5": PricingRate(inputUSDPerMillion: 1.25, cachedReadUSDPerMillion: 0.125, outputUSDPerMillion: 10)
    ]

    private static let claudeRates: [String: PricingRate] = [
        "claude-fable-5": PricingRate(inputUSDPerMillion: 10, cachedReadUSDPerMillion: 1, cacheWrite5mUSDPerMillion: 12.5, cacheWrite1hUSDPerMillion: 20, outputUSDPerMillion: 50),
        "claude-mythos-5": PricingRate(inputUSDPerMillion: 10, cachedReadUSDPerMillion: 1, cacheWrite5mUSDPerMillion: 12.5, cacheWrite1hUSDPerMillion: 20, outputUSDPerMillion: 50),
        "claude-opus-5": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 10, outputUSDPerMillion: 25),
        "claude-opus-4-8": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 10, outputUSDPerMillion: 25),
        "claude-opus-4-7": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 10, outputUSDPerMillion: 25),
        "claude-opus-4-6": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 10, outputUSDPerMillion: 25),
        "claude-opus-4-5": PricingRate(inputUSDPerMillion: 5, cachedReadUSDPerMillion: 0.5, cacheWrite5mUSDPerMillion: 6.25, cacheWrite1hUSDPerMillion: 10, outputUSDPerMillion: 25),
        "claude-sonnet-4-6": PricingRate(inputUSDPerMillion: 3, cachedReadUSDPerMillion: 0.3, cacheWrite5mUSDPerMillion: 3.75, cacheWrite1hUSDPerMillion: 6, outputUSDPerMillion: 15),
        "claude-sonnet-4-5": PricingRate(inputUSDPerMillion: 3, cachedReadUSDPerMillion: 0.3, cacheWrite5mUSDPerMillion: 3.75, cacheWrite1hUSDPerMillion: 6, outputUSDPerMillion: 15),
        "claude-sonnet-4": PricingRate(inputUSDPerMillion: 3, cachedReadUSDPerMillion: 0.3, cacheWrite5mUSDPerMillion: 3.75, cacheWrite1hUSDPerMillion: 6, outputUSDPerMillion: 15),
        "claude-haiku-4-5": PricingRate(inputUSDPerMillion: 1, cachedReadUSDPerMillion: 0.1, cacheWrite5mUSDPerMillion: 1.25, cacheWrite1hUSDPerMillion: 2, outputUSDPerMillion: 5),
        "claude-haiku-4-5-20251001": PricingRate(inputUSDPerMillion: 1, cachedReadUSDPerMillion: 0.1, cacheWrite5mUSDPerMillion: 1.25, cacheWrite1hUSDPerMillion: 2, outputUSDPerMillion: 5),
        "claude-opus-4-1": PricingRate(inputUSDPerMillion: 15, cachedReadUSDPerMillion: 1.5, cacheWrite5mUSDPerMillion: 18.75, cacheWrite1hUSDPerMillion: 30, outputUSDPerMillion: 75),
        "claude-opus-4": PricingRate(inputUSDPerMillion: 15, cachedReadUSDPerMillion: 1.5, cacheWrite5mUSDPerMillion: 18.75, cacheWrite1hUSDPerMillion: 30, outputUSDPerMillion: 75),
        "claude-haiku-3-5": PricingRate(inputUSDPerMillion: 0.8, cachedReadUSDPerMillion: 0.08, cacheWrite5mUSDPerMillion: 1, cacheWrite1hUSDPerMillion: 1.6, outputUSDPerMillion: 4)
    ]
}
