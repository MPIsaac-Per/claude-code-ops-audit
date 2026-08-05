from __future__ import annotations

from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "session.jsonl"
COLLISION_GLOB = ROOT / "tests" / "fixtures" / "collision_*.jsonl"


def ingest(glob: str) -> duckdb.DuckDBPyConnection:
    connection = duckdb.connect(":memory:")
    connection.execute((ROOT / "schema" / "01_tables.sql").read_text())
    escaped = glob.replace("'", "''")
    connection.execute(f"SET VARIABLE jsonl_glob = '{escaped}'")
    connection.execute((ROOT / "ingest" / "jsonl_to_duckdb.sql").read_text())
    return connection


def test_ingest_preserves_scan_order_and_excludes_tool_result_carriers():
    connection = ingest(str(FIXTURE))

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
        """
        SELECT source_files, human_messages, assistant_turns,
               tool_calls_per_human_message, edit_to_read_ratio
        FROM session_metrics
        """
    ).fetchone()
    assert metrics == (1, 1, 2, 1.0, None)


def test_tool_result_joins_back_to_originating_call():
    connection = ingest(str(FIXTURE))

    event = connection.execute(
        """
        SELECT tool_name, result_is_error, result_preview, result_block_id IS NOT NULL
        FROM tool_events
        """
    ).fetchone()
    assert event == ("Bash", False, "1 passed in 0.1s", True)


def test_row_indexes_stay_stable_when_timestamps_collide_across_files():
    connection = ingest(str(COLLISION_GLOB))

    assert connection.execute("SELECT count(*) FROM jsonl_rows").fetchone() == (5,)

    index_by_uuid = dict(
        connection.execute("SELECT uuid, row_index_in_session FROM jsonl_rows").fetchall()
    )
    assert index_by_uuid == {"ca-1": 0, "ca-2": 1, "cb-1": 2, "cb-2": 3, "cb-3": 4}


def test_tool_event_distances_to_human_messages():
    connection = ingest(str(FIXTURE))

    distances = connection.execute(
        """
        SELECT distance_from_previous_human_message, distance_to_next_human_message,
               tools_since_previous_human, tools_until_next_human
        FROM tool_events
        """
    ).fetchone()
    # The fixture's one tool event sits one row after the only human message,
    # with no human message after it.
    assert distances == (1, None, 1, None)


def test_completion_candidates_report_preview_is_full():
    connection = ingest(str(COLLISION_GLOB))
    connection.execute((ROOT / "schema" / "02_views.sql").read_text())

    candidate = connection.execute(
        "SELECT text_preview, preview_is_full FROM plausible_completion_candidates"
    ).fetchone()
    assert candidate == ("Done.", True)
