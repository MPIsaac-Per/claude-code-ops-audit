# Contributing

## Development setup

Requirements: Python 3.11+, [uv](https://docs.astral.sh/uv/), and DuckDB 1.5+ for command-line analysis.

```bash
git clone https://github.com/MPIsaac-Per/claude-code-ops-audit.git
cd claude-code-ops-audit
uv sync --locked --all-extras --dev
```

Run the same checks as CI:

```bash
uv run ruff check .
uv run ruff format --check .
uv run mypy audit/classify.py
uv run pytest --cov=audit --cov-report=term-missing
uv run pip-audit
```

## Change requirements

- Use synthetic fixtures for ingestion and query tests.
- State research assumptions and known limitations beside the query or method.
- Add tests when changing ingest semantics, joins, classifier output, or privacy controls.
- Do not commit raw logs, corpora, labeled samples, private paths, credentials, or generated databases.
- Note in the pull request when a change can alter previously reported metrics.

Open an issue before adding a new log-source adapter or changing the event-mart schema. Small corrections can go directly to a pull request.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
