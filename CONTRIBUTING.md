# Contributing to Meter Beater

Contributions are welcome. Meter Beater handles private local data, so changes
to filesystem access, transcript parsing, accounting, pricing, or release
packaging receive extra scrutiny.

## Development setup

You need macOS 15 or later, Xcode with Swift 6 support, and Git.

```sh
git clone https://github.com/donalddellapietra/meter-beater.git
cd meter-beater
swift test -Xswiftc -warnings-as-errors
swift run AIUsageTracker
```

Create a local universal app and ZIP with:

```sh
scripts/package-app.sh
```

That command uses an ad-hoc signature. Developer ID signing and notarization
are maintainer-only release steps documented in `docs/RELEASING.md`.

## Before opening a pull request

- Keep the change focused and explain its user impact.
- Add regression fixtures for parser or accounting changes.
- Update `docs/ACCOUNTING.md` when an accounting invariant changes.
- Run `swift test -Xswiftc -warnings-as-errors` and `git diff --check`.
- Do not commit provider transcripts, credentials, account identifiers,
  SQLite databases, generated screenshots, or files from `dist/`.
- Do not weaken read-only access or add network behavior without an explicit,
  prominently documented product decision.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
