# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for releases.

## [Unreleased]

## [0.1.0] - 2026-07-14

### Added

- Synthetic DuckDB ingestion fixture and classifier test suite.
- Automated lint, type-check, test, dependency audit, CodeQL, dependency review, and OpenSSF Scorecard workflows.
- Standard contribution, support, security, conduct, citation, and release documentation.

### Fixed

- Human-message metrics exclude user-role rows that contain only tool results.
- Assistant text uses the content block's `text` field.
- Tool results retain their `tool_use_id` so they join to the originating call.
- Content-block row indexes derive from one corpus scan and remain stable when timestamps collide.
- Classifier output is schema-validated and written atomically.
