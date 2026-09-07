<p align="right"><b>English</b> · <a href="README.zh-Hans.md">简体中文</a></p>

<p align="center"><img src="assets/icon.png" width="128" alt="Meter Beater icon"></p>

<h1 align="center">Meter Beater</h1>

<p align="center">A macOS menu bar app that prices your Codex and Claude Code usage at public API rates.<br><b>You do not need this app.</b> Nobody does.</p>

<p align="center">
  <a href="https://github.com/donalddellapietra/meter-beater/actions/workflows/verify.yml"><img alt="Build status" src="https://github.com/donalddellapietra/meter-beater/actions/workflows/verify.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2e8b44"></a>
  <img alt="macOS 15 or later" src="https://img.shields.io/badge/macOS-15%2B-33302c">
</p>

![Meter Beater](assets/shot-en-hero.png)

## What it does

- Opens your local Codex (`~/.codex`) and Claude Code (`~/.claude`) data read-only.
- Prices every token at public API rates and shows the running total in your menu bar. **It is not a bill** — it's what your usage *would have* cost.
- Estimates what serving you likely cost the labs, inferred from their own published margins.
- Assigns you one of ten wool tiers, judged on value extracted per subscription dollar. Click your tier for a Minecraft-style achievement. The low tiers are not compliments.
- Light and dark, English and Simplified Chinese.

## "Doesn't Claude Code already do this?"

Meter Beater combines locally recorded usage from both tools into one menu-bar total, priced at public API rates. No account connection or API key is required. It is a cross-provider dollar comparison, not a reading of either subscription's remaining allowance.

## Install

1. Download **v1.1.4** from [meter-beater.app.space](https://meter-beater.app.space/) or [Releases](../../releases/latest).
2. Unzip and drag **Meter Beater.app** into Applications.
3. Open it and look for the ✂️ in your menu bar — if there's no sheep, your menu bar is overcrowded and macOS quietly hid it, so evict an icon you love less.

To quit, open the panel and use the `⋯` menu. Like every menu bar app, the icon can't be ⌘-dragged off the bar — that's macOS, not the sheep.

Requires macOS 15 or later. Universal binary (Apple silicon + Intel), signed and notarized by Apple.

Verify a download:

```sh
shasum -a 256 -c SHA256SUMS
```

## Build from source

The complete app, accounting engine, tests, benchmark, release scripts, and
marketing renderer live in this repository under the MIT License. You need
macOS 15 or later and Xcode or Command Line Tools with Swift 6 support.

```sh
scripts/test.sh
swift run AIUsageTracker
scripts/package-app.sh
```

The package script creates an ad-hoc-signed universal app and ZIP for local
testing. Official downloads use Developer ID signing and Apple notarization;
see [`docs/RELEASING.md`](docs/RELEASING.md).

The accounting and pricing contract is documented in
[`docs/ACCOUNTING.md`](docs/ACCOUNTING.md).

Version 1.1.4 separates Rolling and Calendar date filters, adds an exact Last
24 hours window, and expires older usage without rescanning transcripts.
Astra, Fable 5.1, and Mythos 5.1 pricing is included. Background refresh remains
enabled while decorative effects sleep whenever the menu-bar panel is closed.
See [release notes](RELEASE_NOTES.md).

## Privacy

It has seen your 3 a.m. sessions. It will not testify.

The longer version: there is no network code in this app. No accounts, emitted
telemetry, or analytics. It reads local provider data in place, does arithmetic
on your Mac, and writes only its own aggregate cache. Nothing leaves the
machine, because there is nowhere for it to go.

Codex access is limited to transcript directories and read-only thread/model
metadata in `state_*.sqlite`; Meter Beater never opens `~/.codex/auth.json`.
Claude account attribution uses local Claude telemetry and session metadata.
Provider roots are never modified, and manually selected folders receive an
explicitly read-only security-scoped bookmark.

## Contributing and security

Contributions are welcome; start with [`CONTRIBUTING.md`](CONTRIBUTING.md).
Please report vulnerabilities privately as described in
[`SECURITY.md`](SECURITY.md), and never attach real transcripts or credentials
to an issue.

## License

Meter Beater is open source under the [MIT License](LICENSE).

## Fine print

The displayed dollar value is a public API rate-card equivalent, not an invoice, a subscription charge, or an audited cost. Serving-cost figures are directional estimates derived from published analyst margin research. Meter Beater is an independent project and is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic.
