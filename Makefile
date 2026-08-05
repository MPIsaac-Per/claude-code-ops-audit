# ==============================================================================
# claude-code-ops-audit — Makefile entry point
# ==============================================================================
# Thin wrapper around the raw duckdb / uv commands documented in README.md and
# CONTRIBUTING.md. Nothing here is required; it just saves re-typing the
# heredoc and the per-file analysis loop. Run `make help` for the target list.
# ==============================================================================

.DEFAULT_GOAL := help

# Mart location and source JSONL glob. Override on the command line, e.g.:
#   make mart DB=/tmp/x.duckdb CORPUS='/path/to/logs/**/*.jsonl'
DB ?= $(HOME)/data/claude_code.duckdb
CORPUS ?= $(HOME)/.claude/projects/**/*.jsonl

.PHONY: help mart analyses report check

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

mart: ## Build the DuckDB mart from CORPUS into DB (schema -> ingest -> views)
	mkdir -p "$(dir $(DB))"
	printf '%s\n' \
		"SET VARIABLE jsonl_glob = '$(CORPUS)';" \
		".read schema/01_tables.sql" \
		".read ingest/jsonl_to_duckdb.sql" \
		".read schema/02_views.sql" \
		| duckdb "$(DB)"

# codex_telemetry_filtered.sql runs against the separate telemetry mart built
# by analyses/build_telemetry_mart.py, not the DB above, so both loops below
# skip it. Run it manually once you have a telemetry mart (see README).
analyses: ## Run every analyses/*.sql against DB (skips codex_telemetry_filtered.sql)
	for f in analyses/*.sql; do \
		case "$$f" in \
			*codex_telemetry_filtered.sql) continue ;; \
		esac; \
		echo "=== $$f ==="; \
		duckdb "$(DB)" < "$$f" || exit 1; \
	done

report: ## Run the analyses and write a Markdown report to .runs/analysis_report.md
	mkdir -p .runs
	: > .runs/analysis_report.md
	for f in analyses/*.sql; do \
		case "$$f" in \
			*codex_telemetry_filtered.sql) continue ;; \
		esac; \
		echo "## $$f" >> .runs/analysis_report.md; \
		echo '```' >> .runs/analysis_report.md; \
		duckdb "$(DB)" < "$$f" >> .runs/analysis_report.md || exit 1; \
		echo '```' >> .runs/analysis_report.md; \
		echo >> .runs/analysis_report.md; \
	done
	echo "Report written to .runs/analysis_report.md"

check: ## Run the CI-equivalent dev suite (see CONTRIBUTING.md)
	uv run ruff check .
	uv run ruff format --check .
	uv run mypy audit/classify.py
	uv run pytest --cov=audit --cov-report=term-missing
	uv run pip-audit
