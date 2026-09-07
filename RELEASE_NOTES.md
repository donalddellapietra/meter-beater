# Meter Beater 1.1.4

- Separate date filters into Rolling and Calendar modes. Rolling offers Last
  24 hours, Last 7 days, and Last 30 days; Calendar offers Today, This week,
  This month, and This year. All time and Custom range remain separate.
- Use exact elapsed-time boundaries for rolling windows, including across
  daylight-saving changes. Show starting timestamps for rolling ranges and
  inclusive dates for calendar periods.
- Refresh moving windows as older events expire, even without new usage.
  Visible panels re-query the local cache each minute; hidden panels do not
  run this timer or decorative effects. Filters do not rescan transcripts.
- Preserve event timestamps in compact Codex storage. Older daily aggregates
  are rebuilt once, in bounded batches; cached totals remain intact until
  each file is replaced. Time-filtered pricing stays provisional during replay.
- Preserve custom weekly/monthly renewal settings and label non-calendar
  periods as cycles. Keep exact boundary handling consistent for both providers.

Universal macOS build for Apple silicon and Intel; macOS 15 or later.
The release is Developer ID signed and notarized by Apple.

---

# Meter Beater 1.1.3

- Recognize GPT-6 Astra and Claude Fable/Mythos 5.1 with their published API,
  cache, long-context, and applicable Codex-credit rates.
- Apply the GPT-5.6 Sol, Terra, and Luna price reductions from their effective
  dates, preserving earlier prices for earlier usage.
- Remove Sonnet 5's cancelled September price increase.
- Keep unknown versions explicitly unpriced instead of matching an older model
  by prefix. Retain verified dated snapshots and older Codex API model rates.
- Refresh affected cached accounting automatically without rebuilding unrelated
  transcripts, and discard saved dollar snapshots made with older pricing.

---

# Meter Beater 1.1.2

This patch makes automatic usage updates self-healing without waking the hidden
panel's visual effects.

## Fixes

- A low-frequency five-minute reconciliation now remains enabled even when the
  filesystem watcher starts successfully, covering streams lost after sleep.
- Opening a panel whose data is more than one minute old requests an immediate
  update.
- Dropped filesystem events and watched-root changes request a complete bounded
  check instead of allowing the displayed totals to remain stale.

The safety task sleeps between checks, unchanged files are not reparsed, and
panel animations still run only while the panel is visible.

---

# Meter Beater 1.1.1

This patch keeps Meter Beater asleep when its menu-bar panel is closed.

## Fixes

- Decorative effects and indeterminate progress animations now run only while
  the menu-bar panel is actually visible and active.
- Closing the panel stops its SwiftUI display link instead of allowing the
  serving-cost flame or empty-state indicator to render continuously in the
  background.
- Background usage refreshes update the menu-bar value without starting hidden
  numeric transitions or a model-wide animation transaction.
- Opening the panel still runs the meter roll, sheep waggle, wool puff, live
  refresh spinner, and other existing effects as before.

Accounting, pricing, provider access, and cache formats are unchanged.

---

# Meter Beater 1.1.0

Frontier Subsidy is now **Meter Beater** — in Simplified Chinese, **羊毛计** (a
wool-o-meter: 羊毛 from 薅羊毛, 计 as in 温度计). Same read-only accounting,
sillier outfit.

## Highlights

- The complete app, accounting engine, tests, release scripts, and marketing
  renderer are now open source under the MIT License.
- Provider access is narrower: manually selected folders use explicitly
  read-only security-scoped bookmarks, and Codex scans no longer open or
  fingerprint `~/.codex/auth.json`.
- New name everywhere: bundle, Finder localizations (`Meter Beater` / `羊毛计` /
  `羊毛計`), panel header, packaging, and release artifacts.
- New app icon: a sheep whose fleece is the meter — a seven-segment `$88`
  readout set right into the wool (88 as in 发发).
- The whole panel now wears the icon's design: a pasture-green wash, flat
  wool-cream cards for the value, serving-cost, and provider sections, a
  sheep-face header badge, and the headline in a green-on-black LCD meter.
- Every panel open runs the meter: the value rolls up from $0 like an odometer,
  the sheep waggles, and a puff of shorn wool drifts off. Provider totals sit
  in matching green LCD chips and the serving-cost estimate in an amber one;
  all of them roll when values change.
- A wool-tier rank now sits beside the token pill: API-equivalent value divided
  by your assumed subscription spend ($200/month per provider by default,
  editable by clicking the spend shown under each provider name). Ten tiers
  run from AI Philanthropist (under 0.5×) through Free-Range Wallet, Coupon
  Clipper, and Wool Baron up to National Wool Reserve (160× and up), in both
  languages, and clicking the badge pops a Minecraft-style "Achievement Get!"
  toast with a flavor line for your rank.
- The date control gains rolling cycles: Today, This week, and This month
  follow the current period instead of pinning to fixed dates, and the week
  and month cycles renew on a configurable start day (weekday, or day of the
  month for billing-cycle alignment). All time stays the default, and the
  custom-range calendar now sits behind one extra click. Cycle windows count
  elapsed days, so the multiplier compares usage-so-far against spend-so-far.
- While a refresh runs, the footer arrow spins and the status reads
  "Shearing…" (薅羊毛中…); idle is "Grazing" (吃草中).
- Crossing another $100 of fleeced API-equivalent value sets off a brief wool
  confetti burst in the panel.
- The serving-cost flame breathes gently, and the empty state counts sheep.

Accounting, pricing, the bundle identifier, and cache locations are unchanged,
so existing installs upgrade in place with no migration. A refresh resets
legacy Codex current-auth attribution to source-only metadata; displayed
provider totals are unaffected.

---

# Frontier Subsidy 1.0.0

Frontier Subsidy is a private, read-only macOS menu-bar app that turns local
Codex and Claude Code usage into a public-API-rate-card equivalent. In Simplified
Chinese it appears as **薅大厂**.

## Highlights

- A compact native menu-bar panel replaces the previous dashboard.
- The token headline appears from a bounded first-frame scan in under five seconds;
  the exact compact ledger finishes independently without blocking the interface.
- OpenAI Codex and Anthropic Claude Code have separate API-equivalent totals and
  exact cost breakdowns for uncached input, cached input, and output.
- Today, 7-day, 30-day, year-to-date, all-time, and compact custom date ranges query
  the aggregate cache without rescanning transcripts.
- English and Simplified Chinese follow the Mac language by default and can be
  overridden in Settings.
- Serving-cost assumptions are editable per provider and remain clearly separate
  from the exact public-API-equivalent calculation.
- Provider roots are read only; transcript text never leaves the Mac or enters the
  app's aggregate snapshot.

## Accounting and performance

The v1.0.0 release audit reconciled 2,102 local transcript files (9.795 GB) in
18.85 seconds. It counted 356,370 billable events and 58,505,362,101 processed
tokens, producing a $50,098.42 combined public-API-rate-card equivalent:
$28,441.05 for Codex and $21,657.37 for Claude Code. Five preview-model events
remain deliberately unpriced instead of borrowing another model's rate.

The first-frame headline completed in 0.26 seconds. An immediate live-tail refresh
completed in 1.04 seconds, and an indexed 30-day query completed in 0.34–0.35
seconds while matching the full summary exactly.

The final resource audit also eliminated a background-scan memory spike caused by
autoreleased inherited-history windows. On a later 9.818 GB replay, the exact
refresh completed in 19.26 seconds and maximum RSS fell from 4.49 GB to 0.67 GB;
peak physical footprint was 0.35 GB.

## Requirements

- macOS 15 or later
- Apple silicon or Intel Mac (universal binary)
- Local Codex and/or Claude Code transcript access

The displayed dollar value is an API rate-card equivalent, not a provider invoice.
