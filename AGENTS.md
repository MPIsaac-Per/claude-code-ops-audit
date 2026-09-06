# Claude Code ops audit

## Working agreement

Complete the requested work through verification. Make reasonable local decisions and ask only when a missing answer changes the outcome; continue independent work while waiting. Preserve user edits and carry outstanding requests across interruptions.

Use the tools and model actually available in this session. Skills supply task guidance within the user's scope and existing authorization. Keep simple work local. When delegation is authorized and useful, give workers bounded ownership, keep at most three active across the whole task, and inspect and integrate their results.

Run checks relevant to the change plus required repository gates. Broaden testing only for new changes, failures, or unresolved risk. Report the result, evidence, and actual limits in concise plain prose. Commits, pushes, publishing, messages, credential changes, and destructive actions need authorization covering the action; do not request it again when already given. Do not add agent or model attribution.

## Repository context

This is public methodology and analysis tooling, with no user corpus included. `schema/` and `ingest/` define the event mart, `analyses/` contains queries and helpers, and `audit/` contains the classifier. Read `docs/PERSISTENCE.md` before working with audit outputs.

Use synthetic fixtures for development. Keep raw logs, databases, labeled text, personal paths, and client/employer material out of the repository. Historical model comparisons are research data, not instructions to select those models. Running a paid classifier or ingesting a private corpus requires task authorization; ordinary checks use fixtures.

## Verification

Use `uv sync --locked --all-extras --dev` when dependencies are needed. Run relevant `uv run pytest` cases. Code gates are `uv run ruff check .`, `uv run ruff format --check .`, `uv run mypy audit/classify.py`, and `uv run pytest --cov=audit --cov-report=term-missing`. For instruction edits, check references and scope without running a live audit.
