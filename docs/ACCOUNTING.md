# Accounting contract

This document defines the number displayed by Meter Beater. The code that implements it lives in `UsageCore`; the app, SQLite summaries, exports, and benchmark all call the same `UsageAccounting` boundary.

## Meaning of the headline

The headline is a **standard public API rate-card equivalent** for locally reported Codex and Claude Code token counters. It is not a provider invoice, subscription charge, credit-balance reading, or audited serving cost.

For each provider request, the normalized token ledger is:

```text
processed tokens = uncached input + cached input + cache writes + output
```

Reasoning tokens are retained as a diagnostic subset of output. They are never added to processed tokens or charged a second time.

The public API equivalent is priced per request/model/rate period before aggregation:

```text
API value =
  uncached input × input rate
  + cached input × cached-read rate
  + cache writes × provider cache-write rate
  + output × output rate
  + documented request-level premiums
```

OpenAI reports cached input as a subset of input, so the Codex adapter stores `input - cached input` as uncached input. Anthropic reports ordinary input, cache reads, and cache creation separately, so the Claude adapter preserves those categories directly.

## Codex counter reconstruction

Codex transcripts contain cumulative `total_token_usage` snapshots and usually a request-level `last_token_usage` object.

- A component-wise high-water mark fences duplicate and out-of-order cumulative snapshots.
- `last_token_usage` is accepted only within newly proven cumulative progress, so repeated telemetry cannot charge the same request twice.
- A recovered decrease is classified as out-of-order telemetry. A file that ends below its prior high-water remains unresolved and makes the result provisional.
- Physical forks copy parent history. The scanner locates the first task owned by the child, excludes the copied prefix, and requires request-level usage for the first child turn. A fork with no owned task contributes zero without warning; an ambiguous boundary fails closed.
- The active `turn_context.model` is attached to each request. A thread's latest metadata model is not used to reprice its earlier turns.

## Request-level pricing rules

- GPT-5.4, GPT-5.5, GPT-5.6, and GPT-6 Astra requests above 272,000 input tokens receive the documented 2× input and 1.5× output public-API multipliers for the full request. The premium is applied only when explicit request counters prove that the threshold was crossed; cumulative-only fallback rows do not guess.
- GPT-5.6 and GPT-6 Astra cache creation is priced at 1.25× uncached input for API-equivalent dollars.
- Codex credits use OpenAI's separate token-based credit rate card. API long-context premiums are not copied into credits, and Codex cache writes consume no credits unless the credit card later documents otherwise.
- Fast mode, tool-call fees, data-residency premiums, Batch/Flex discounts, and other modifiers are not inferred because local transcript counters do not reliably establish them.
- Unknown models and GPT-5.3-Codex-Spark remain unpriced rather than borrowing another model's rate.

## 2026-09-05 pricing snapshot

The catalog explicitly recognizes GPT-6 Astra, Claude Fable 5.1, and Claude Mythos 5.1. Fable/Mythos 5.1 cache reads cost $0.25 per million tokens, while version 5 retains its $1 rate. Only exact model IDs and dated snapshots inherit a known rate; unknown versions and variants remain unpriced.

GPT-5.6 Terra and Luna use their reduced API prices from July 30, 2026. Sol uses its reduced API and Codex-credit prices from August 21, 2026. Earlier usage retains the earlier rates. Provider announcements specify dates without an effective clock time, so the implementation uses UTC midnight. No automatic end date is assumed for Sol's promotion. Sonnet 5's cancelled September increase is not applied.

All summaries split aggregates at pricing boundaries. Cache accounting generation 7 retains existing data and schedules only affected Astra transcripts and GPT-5.6 rollups for replay. Saved first-frame dollar snapshots are invalidated when the pricing snapshot changes. The release is covered by 63 Swift tests, including historical rates, unknown model IDs, and targeted cache migrations.

## 2026-08-03 local corpus audit

The corrected implementation was replayed into a disposable SQLite database from provider roots, not from the app's previous cache:

- 2,102 transcript files and 9.80 GB read;
- 356,370 logical usage records;
- 58,505,362,101 processed tokens;
- $28,441.05 Codex public-API equivalent;
- $21,657.37 Claude Code public-API equivalent;
- $50,098.42 combined;
- 5 unpriced records, all GPT-5.3-Codex-Spark research preview.

The final release audit completed in 18.85 seconds on the development Mac. An immediate live-tail refresh completed in 1.04 seconds, preserved the per-model totals, and added only the new Sol records. A 30-day compact query completed in 0.34–0.35 seconds after warmup and matched the full summary exactly. The first-frame token headline completed in 0.26 seconds.

A final release-candidate resource audit caught a separate lifetime defect: dispatch workers retained 5,270 autoreleased `Data` windows (about 4.0 GB) while traversing inherited histories. Per-file and per-window autorelease pools now bound that lifetime, and the native scanner releases each 32 MiB logical mapping window before moving on. On the subsequently larger 9.818 GB corpus, a fresh exact refresh completed in 19.26 seconds (19.73 seconds including the compact summary). Maximum RSS fell from 4,490,936,320 to 670,646,272 bytes, and the reported peak physical footprint fell to 345,229,760 bytes. The accounting diagnostics remained stable at 9,077 duplicate snapshots, 2,729 stale snapshots, 941 inherited baselines, zero unresolved resets, and zero warnings.

The only fluctuating cumulative-counter file recovered exactly to its component-wise high-water; four apparent inherited-boundary warnings were copy-only forks whose last task predates the fork creation time. Regression tests cover both cases. The audit also caught and fixed two model-attribution defects before release: incremental cursors did not persist the active turn model, and metadata enrichment could overwrite parsed historical models with the thread's latest model.

The Codex result landing near the user's initial $25–30K intuition is incidental. It is supported by a raw replay, per-turn model attribution, counter invariants, and current first-party rate cards—not by fitting the implementation to that range.

## Sources and versioning

The active rate snapshot is dated in `PricingCatalog.snapshotDate`. Current primary sources:

- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [GPT-5.6 price-change announcements](https://openai.com/index/gpt-5-6/)
- [OpenAI Codex rate card](https://help.openai.com/en/articles/20001106-codex-rate-card)
- [Anthropic Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing)

Any pricing or counter-semantic change requires a cache accounting-generation bump, fixture updates, and a disposable full-corpus reconciliation before release.
