# Security policy

## Supported versions

Security fixes target the latest published Meter Beater release and the
default branch.

## Reporting a vulnerability

Please use [GitHub's private vulnerability reporting](https://github.com/donalddellapietra/meter-beater/security/advisories/new).
Do not open a public issue for a vulnerability.

Include the affected version, macOS version, impact, reproduction steps, and
any suggested mitigation. Never attach real Codex or Claude transcripts,
`auth.json`, provider databases, tokens, credentials, or account identifiers.
A minimal synthetic fixture is preferred.

Security-sensitive areas include provider filesystem access, security-scoped
bookmarks, transcript parsing, SQLite handling, generated release artifacts,
code signing, and notarization.
