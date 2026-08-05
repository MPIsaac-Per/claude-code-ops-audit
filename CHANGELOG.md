# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for releases.

## [Unreleased]

## [0.1.1] - 2026-08-05

### Added

- Regression tests for the tool_use → tool_result join, timestamp-collision
  row ordering across files, and the completion-candidates view.
- `plausible_completion_candidates` emits `preview_is_full`, which the audit
  rubric and classifier prompt already referenced; classifications previously
  received null for it.
- `session_metrics.tool_calls_per_human_message` and `edit_to_read_ratio` are
  populated instead of left NULL.

### Fixed

- fpk scripts skip valid-JSON lines that are not objects instead of crashing
  (`fpk_correlate`) or silently truncating a file's counts (`fpk_count`).
- `fpk_tui --print` works on Python builds without `curses`, and month
  bucketing guards malformed timestamps.
- Zero-valued `intValue`/`doubleValue` OTel attributes export as `0` instead
  of an empty field.
- `safe_int`/`safe_float` in the telemetry mart respect the sensitive-key
  suppression list.
- The conversation archive catalog handles indexes with no hive-partitioned
  blob names and distinguishes an empty `--latest-index` from an omitted one.
- `session_endings` classifies a closing turn that both claims and verifies
  as a verified ending instead of an unverified tool + completion ending.
- Field Manual queries 5 and 6 keep sessions with no assistant turns and
  guard zero denominators.
- README lists all shipped analyses; schema comments match what the ingest
  populates.

### Changed

- Telemetry `cwd` classification labels `/Users/` paths `macos` (was
  `macbook`) and recognizes Windows paths.

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
