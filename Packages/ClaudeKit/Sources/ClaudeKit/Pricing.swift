import Foundation

/// USD per million tokens for one model (and, for tiered models, one prompt-length band).
public struct ModelPricing: Sendable, Hashable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cacheReadPerMTok: Double
    /// 5-minute cache writes (1.25x input).
    public var cacheWrite5mPerMTok: Double
    /// 1-hour cache writes (2x input).
    public var cacheWrite1hPerMTok: Double

    public init(
        input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil
    ) {
        inputPerMTok = input
        outputPerMTok = output
        cacheReadPerMTok = cacheRead
        cacheWrite5mPerMTok = cacheWrite5m ?? input * 1.25
        cacheWrite1hPerMTok = cacheWrite1h ?? input * 2
    }
}

/// A price band that applies while the prompt has at most `maxPromptTokens` tokens (nil: no limit).
public struct PriceTier: Sendable, Hashable {
    public var maxPromptTokens: Int?
    public var pricing: ModelPricing

    public init(maxPromptTokens: Int? = nil, pricing: ModelPricing) {
        self.maxPromptTokens = maxPromptTokens
        self.pricing = pricing
    }
}

/// Claude API list prices (first-party API, standard tier). Update when Anthropic changes prices.
public struct PricingTable: Sendable, Hashable {
    /// Tiers per model, in ascending `maxPromptTokens` order with an unlimited last tier.
    public var tiers: [ClaudeModel: [PriceTier]]
    /// Web search: $10 per 1,000 searches. Web fetch has no per-request charge.
    public var webSearchPerRequest: Double

    public init(tiers: [ClaudeModel: [PriceTier]], webSearchPerRequest: Double = 0.01) {
        self.tiers = tiers
        self.webSearchPerRequest = webSearchPerRequest
    }

    /// Prices as of 2026-10.
    public static let standard = PricingTable(tiers: [
        // $4 / $20; cache reads $0.20; 5-minute writes $5, 1-hour writes $8.
        .opus55: [PriceTier(pricing: ModelPricing(input: 4, output: 20, cacheRead: 0.20))],
        // $2 / $10; cache reads $0.20; writes $2.50 / $4.
        .sonnet55: [PriceTier(pricing: ModelPricing(input: 2, output: 10, cacheRead: 0.20))],
        // $0.10 / $0.50 up to 100K-token prompts, then $0.50 / $2.50; cache reads 0.1x input.
        .haiku55: [
            PriceTier(maxPromptTokens: 100_000, pricing: ModelPricing(input: 0.10, output: 0.50, cacheRead: 0.01)),
            PriceTier(pricing: ModelPricing(input: 0.50, output: 2.50, cacheRead: 0.05)),
        ],
        // Possible refusal-fallback targets for Opus 5.5.
        .opus5: [PriceTier(pricing: ModelPricing(input: 5, output: 25, cacheRead: 0.50))],
        .opus48: [PriceTier(pricing: ModelPricing(input: 5, output: 25, cacheRead: 0.50))],
    ])

    /// The prices for `model` at a prompt of `promptTokens` tokens; nil for an unknown model.
    public func pricing(for model: ClaudeModel, promptTokens: Int) -> ModelPricing? {
        guard let modelTiers = tiers[model], !modelTiers.isEmpty else { return nil }
        for tier in modelTiers {
            guard let limit = tier.maxPromptTokens else { return tier.pricing }
            if promptTokens <= limit { return tier.pricing }
        }
        return modelTiers.last?.pricing
    }

    /// Cost in USD of one response's usage on `model`; nil for an unknown model.
    public func cost(of usage: Usage, model: ClaudeModel) -> Double? {
        guard let pricing = pricing(for: model, promptTokens: usage.promptTokens) else { return nil }
        let oneHourWrites = usage.cacheCreation1hInputTokens ?? 0
        let fiveMinuteWrites = max(0, usage.cacheCreationInputTokens - oneHourWrites)
        let tokenCost =
            Double(usage.inputTokens) * pricing.inputPerMTok
            + Double(usage.outputTokens) * pricing.outputPerMTok
            + Double(usage.cacheReadInputTokens) * pricing.cacheReadPerMTok
            + Double(fiveMinuteWrites) * pricing.cacheWrite5mPerMTok
            + Double(oneHourWrites) * pricing.cacheWrite1hPerMTok
        return tokenCost / 1_000_000 + Double(usage.webSearchRequests) * webSearchPerRequest
    }
}
