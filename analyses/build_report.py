#!/usr/bin/env python3
"""Build a self-describing Markdown report from the DuckDB mart.

Shells out to the duckdb CLI (the same brew-installed binary the README
requires) for every query, so this script has no third-party dependencies.
Each analyses/*.sql file's leading comment block is lifted into prose, then
followed by that file's query output rendered as Markdown tables.

Usage:
    python3 analyses/build_report.py
    python3 analyses/build_report.py --db /path/to/other.duckdb --out report.md
    python3 analyses/build_report.py --skip codex_telemetry_filtered.sql slow_one.sql
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

ANALYSES_DIR = Path(__file__).resolve().parent
REPO_ROOT = ANALYSES_DIR.parent

DEFAULT_DB = Path("~/data/claude_code.duckdb")
DEFAULT_OUT = Path(".runs/analysis_report.md")
DEFAULT_SKIP: tuple[str, ...] = ("codex_telemetry_filtered.sql",)

CORPUS_SUMMARY_SQL = (
    'SELECT count(*) AS sessions, sum("rows") AS jsonl_rows, '
    "sum(tool_events) AS tool_events, min(first_timestamp)::DATE AS first_day, "
    "max(last_timestamp)::DATE AS last_day FROM session_metrics;"
)

TOP_MODELS_SQL = (
    'SELECT message_model AS model, count(*) AS "rows" FROM jsonl_rows '
    "WHERE message_model IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 10;"
)

CAVEATS = """\
- **The keyword heuristics are crude.** The completion-claim and verification-claim flags catch
  plenty of false positives. Treat raw heuristic counts as candidates, not conclusions.
- **Tool family bucketing is opinionated.** See `ingest/jsonl_to_duckdb.sql` for the family map;
  edit it to match your own tool surface.
- **Single-operator findings don't generalize.** What you find on your own logs is specific to
  your workflow. The methodology generalizes; the numbers don't.
- **Sample size matters per cell.** Per-version comparisons need 1,000+ turns per version for
  reliable signal, so bucket sparse versions into eras.

See `docs/METHODOLOGY.md` for the full walkthrough and caveats.
"""


def run_query(db: Path, sql: str) -> str:
    """Run a single SQL statement against db, returning Markdown table output."""
    result = subprocess.run(
        ["duckdb", "-readonly", "-markdown", str(db), "-c", sql],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "duckdb exited non-zero")
    return result.stdout


def run_file(db: Path, sql_path: Path) -> str:
    """Run every query in sql_path against db, returning Markdown table output."""
    stdin_payload = ".mode markdown\n" + sql_path.read_text(encoding="utf-8")
    result = subprocess.run(
        ["duckdb", "-readonly", str(db)],
        input=stdin_payload,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "duckdb exited non-zero")
    return result.stdout


def header_prose(sql_path: Path) -> str:
    """Lift a .sql file's leading `--` comment block into prose.

    Strips the `--` prefix and one following space, drops pure `====` rule
    lines, and preserves blank comment lines as paragraph breaks.
    """
    prose_lines: list[str] = []
    for line in sql_path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("--"):
            break
        rest = line[2:]
        if rest.startswith(" "):
            rest = rest[1:]
        if rest.strip() and set(rest.strip()) == {"="}:
            continue
        prose_lines.append(rest)
    return "\n".join(prose_lines).strip("\n")


def methodology_version() -> str:
    """Best-effort `git describe --tags --always`; empty string on any failure."""
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--always"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def build_info_line(db: Path) -> str:
    generated = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    version = methodology_version()
    parts = [f"Generated {generated}"]
    if version:
        parts.append(f"methodology {version}")
    parts.append(f"mart `{db}`")
    return " · ".join(parts)


def analysis_files(skip: set[str]) -> list[Path]:
    return sorted(p for p in ANALYSES_DIR.glob("*.sql") if p.name not in skip)


def build_report(db: Path, skip: set[str]) -> tuple[str, bool]:
    ok = True
    lines: list[str] = [
        "# Claude Code ops audit report",
        "",
        build_info_line(db),
        "",
        "## Corpus summary",
        "",
        run_query(db, CORPUS_SUMMARY_SQL).strip(),
        "",
        run_query(db, TOP_MODELS_SQL).strip(),
        "",
        "## Caveats",
        "",
        CAVEATS.strip(),
        "",
    ]

    for sql_path in analysis_files(skip):
        lines.append(f"## {sql_path.name}")
        lines.append("")
        lines.append(header_prose(sql_path))
        lines.append("")
        try:
            lines.append(run_file(db, sql_path).strip())
        except RuntimeError as exc:
            ok = False
            lines.append("**ERROR**")
            lines.append("")
            lines.append("```")
            lines.append(str(exc))
            lines.append("```")
        lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n", ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="Path to the DuckDB mart")
    parser.add_argument(
        "--out", type=Path, default=DEFAULT_OUT, help="Path to write the Markdown report"
    )
    parser.add_argument(
        "--skip",
        nargs="*",
        metavar="NAME",
        default=None,
        help=f"analyses/*.sql filenames to skip (default: {', '.join(DEFAULT_SKIP)})",
    )
    args = parser.parse_args()

    if shutil.which("duckdb") is None:
        print(
            "Error: the duckdb CLI is not on PATH. Install it with `brew install duckdb`.",
            file=sys.stderr,
        )
        return 1

    db = args.db.expanduser()
    if not db.exists():
        print(f"Error: database file not found: {db}", file=sys.stderr)
        return 1

    skip = set(args.skip) if args.skip is not None else set(DEFAULT_SKIP)

    out = args.out.expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)

    try:
        report, ok = build_report(db, skip)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    out.write_text(report, encoding="utf-8")
    print(out)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
