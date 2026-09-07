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

## Time-window semantics (1.1.4)

Rolling ranges end at the query timestamp and include the start but exclude the
end. Last 24 hours spans exactly 86,400 seconds; Last 7/30 days spans 7/30 times
that duration, including across daylight-saving changes. Calendar periods start
at local midnight or the configured week/month boundary; live queries stop at
now. Custom ranges include both selected local calendar dates.

Cache generation 8 replaces legacy Codex day aggregates with timestamp-preserving
records. Existing totals remain available while the normal bounded refresh
atomically replaces each affected file. Time-filtered pricing is provisional
until coarse rows have been reconciled; unrelated event-mode files stay cached.
Opening a moving range and each visible-panel minute re-query SQLite without
rescanning transcripts. The existing five-minute safety refresh also updates
time windows when no files changed. Hidden panels do not run the minute timer.

Verification includes 75 Swift tests covering both provider adapters, half-open
timestamp boundaries, DST, expiration without writes, and one-time cache replay.

## 2026-09-05 pricing snapshot

The catalog now explicitly recognizes GPT-6 Astra, Claude Fable 5.1, and Claude Mythos 5.1. Fable/Mythos 5.1 cache reads cost $0.25 per million tokens, while version 5 retains its $1 rate. Only exact model IDs and dated snapshots inherit a known rate; an unrecognized newer version or variant cannot silently fall back to an older model.

GPT-5.6 Terra and Luna use their reduced API prices from July 30, 2026. Sol uses its reduced API and Codex-credit prices from August 21, 2026. Earlier usage retains the earlier rates. Provider announcements specify calendar dates but no effective clock time, so the implementation consistently uses UTC midnight. No automatic end date is assumed for Sol's promotion. Anthropic cancelled Sonnet 5's scheduled September 1 increase; its $2 input / $10 output rates remain in effect.

Every summary path splits aggregates at these pricing boundaries, including when a local day spans UTC midnight. Cache accounting generation 7 retains existing data and schedules only Astra transcripts and GPT-5.6 rollups near those boundaries for replay. This repairs missing Astra long-context classification and previously merged historical periods without rebuilding unaffected files. Saved first-frame dollar snapshots are invalidated when the pricing snapshot changes.

Verification passed all 63 Swift fixtures and warning-free Apple Silicon and Intel release builds. Rate-boundary tests also passed in UTC, in addition to the development Mac's local time zone. A disposable Codex replay read 51 files (4.00 GB) in 6.05 seconds with no unpriced records or scan warnings; compact and detailed summaries matched exactly across three repeated queries. The source counters reported seven ambiguous resets, so those historical totals remain provisional. The Claude transcript directory was unavailable; Claude rates were verified against fixtures, not a local corpus replay. No provider transcript or installed-app cache was modified by the audit.

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
