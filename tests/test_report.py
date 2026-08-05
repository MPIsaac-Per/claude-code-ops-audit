from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILD_REPORT = ROOT / "analyses" / "build_report.py"
CORPUS_GLOB = "tests/fixtures/collision_*.jsonl"
SKIPPED_ANALYSIS = "codex_telemetry_filtered.sql"

pytestmark = pytest.mark.skipif(shutil.which("duckdb") is None, reason="duckdb CLI not installed")


def build_mart(db_path: Path) -> None:
    """Mirror the Makefile's `mart` recipe: schema -> ingest -> views."""
    stdin_payload = (
        "\n".join(
            [
                f"SET VARIABLE jsonl_glob = '{CORPUS_GLOB}';",
                ".read schema/01_tables.sql",
                ".read ingest/jsonl_to_duckdb.sql",
                ".read schema/02_views.sql",
            ]
        )
        + "\n"
    )
    result = subprocess.run(
        ["duckdb", str(db_path)],
        input=stdin_payload,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_build_report_writes_full_markdown_report(tmp_path):
    db_path = tmp_path / "mart.duckdb"
    build_mart(db_path)

    out_path = tmp_path / "report.md"
    result = subprocess.run(
        [
            sys.executable,
            str(BUILD_REPORT),
            "--db",
            str(db_path),
            "--out",
            str(out_path),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    report = out_path.read_text(encoding="utf-8")
    assert "## Corpus summary" in report
    assert "## Caveats" in report

    analysis_names = sorted(
        p.name for p in (ROOT / "analyses").glob("*.sql") if p.name != SKIPPED_ANALYSIS
    )
    assert analysis_names, "expected at least one non-skipped analysis file"
    for name in analysis_names:
        assert f"## {name}" in report

    assert any(line.startswith("|") for line in report.splitlines())
