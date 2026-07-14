from __future__ import annotations

from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "session.jsonl"


def test_ingest_preserves_scan_order_and_excludes_tool_result_carriers():
    connection = duckdb.connect(":memory:")
    connection.execute((ROOT / "schema" / "01_tables.sql").read_text())
    fixture = str(FIXTURE).replace("'", "''")
    connection.execute(f"SET VARIABLE jsonl_glob = '{fixture}'")
    connection.execute((ROOT / "ingest" / "jsonl_to_duckdb.sql").read_text())

    assert connection.execute("SELECT count(*) FROM jsonl_rows").fetchone() == (4,)
    assert connection.execute("SELECT count(*) FROM content_blocks").fetchone() == (5,)
    assert connection.execute("SELECT count(*) FROM human_messages").fetchone() == (1,)
    assert connection.execute("SELECT count(*) FROM assistant_turns").fetchone() == (2,)
    assert connection.execute("SELECT count(*) FROM tool_events").fetchone() == (1,)

    row_indexes = connection.execute(
        "SELECT row_index_in_session FROM jsonl_rows ORDER BY row_id"
    ).fetchall()
    assert row_indexes == [(0,), (1,), (2,), (3,)]

    human = connection.execute("SELECT prompt_preview, prompt_chars FROM human_messages").fetchone()
    assert human == ("Please run the tests.", 21)

    assistant = connection.execute(
        """
        SELECT text_preview, text_chars, completion_claim, verification_claim
        FROM assistant_turns
        WHERE row_index_in_session = 3
        """
    ).fetchone()
    assert assistant == ("Done. Tests passed.", 19, True, True)

    metrics = connection.execute(
        "SELECT source_files, human_messages, assistant_turns FROM session_metrics"
    ).fetchone()
    assert metrics == (1, 1, 2)
