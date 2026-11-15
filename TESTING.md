# Testing

## Local static checks

The Windows workspace can run:

```powershell
python work/validate_swift_sources.py
python work/verify_sqlite_schema.py
python work/verify_swift_migration.py
```

These checks do not replace Swift type checking.

## Free macOS CI

`.github/workflows/swift-core-tests.yml` runs the real XCTest suite on a
standard GitHub-hosted macOS runner. Standard runners are free for public
repositories. No signing identity or Apple Developer account is required for
the core package tests.

Required repository state:

- This directory is the repository root, or the workflow path is adjusted.
- The repository is public for the guaranteed zero-cost runner route.
- No API keys, customer data, pairing records, or private logs are committed.

Command:

```text
swift test --parallel
```

The test suite covers business rules, PII redaction, task states, logistics
validation, encrypted SQLite persistence, deduplication, priority claims,
restart recovery, scheduling, manual takeover gates, accessibility parsing,
the DeepSeek App driver, iCTRL protocol-v1 encryption, response authentication,
foreground-bundle rejection, and the concrete iCTRL-to-DeepSeek bridge.
