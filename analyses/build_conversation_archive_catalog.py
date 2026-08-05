#!/usr/bin/env python3
"""Build a conversation archive catalog from Azure blob inventory JSON.

This script does not parse transcript content. It catalogs every conversation
blob snapshot as provenance and marks the latest snapshot per session so
analysis can avoid double-counting rolling JSONL uploads.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from typing import Any

CATALOG_COLUMNS = [
    ("blob_id", "UBIGINT"),
    ("source_blob", "VARCHAR"),
    ("source_uri", "VARCHAR"),
    ("session_id", "VARCHAR"),
    ("path_session_id", "VARCHAR"),
    ("path_day", "DATE"),
    ("path_month", "VARCHAR"),
    ("indexed_bytes", "UBIGINT"),
    ("last_modified", "TIMESTAMPTZ"),
    ("creation_time", "TIMESTAMPTZ"),
    ("content_type", "VARCHAR"),
    ("snapshot_rank_desc", "UINTEGER"),
    ("snapshot_count_for_session", "UINTEGER"),
    ("is_latest_by_rank", "BOOLEAN"),
    ("is_latest_index_member", "BOOLEAN"),
    ("metadata_host_hash", "VARCHAR"),
    ("metadata_original_path_hash", "VARCHAR"),
    ("downloaded", "BOOLEAN"),
    ("local_path", "VARCHAR"),
    ("local_bytes", "UBIGINT"),
]

SESSION_COLUMNS = [
    ("session_id", "VARCHAR"),
    ("snapshot_count", "UINTEGER"),
    ("total_snapshot_bytes", "UBIGINT"),
    ("first_path_day", "DATE"),
    ("last_path_day", "DATE"),
    ("first_blob_modified", "TIMESTAMPTZ"),
    ("last_blob_modified", "TIMESTAMPTZ"),
    ("latest_blob", "VARCHAR"),
    ("latest_blob_bytes", "UBIGINT"),
    ("latest_blob_modified", "TIMESTAMPTZ"),
    ("latest_in_supplied_index", "BOOLEAN"),
]

DAY_COLUMNS = [
    ("path_day", "DATE"),
    ("blob_count", "UBIGINT"),
    ("latest_blob_count", "UBIGINT"),
    ("nonlatest_blob_count", "UBIGINT"),
    ("distinct_sessions", "UBIGINT"),
    ("indexed_bytes", "UBIGINT"),
    ("latest_indexed_bytes", "UBIGINT"),
]


def sha256_text(value: str) -> str:
    if not value:
        return ""
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def table_sql(name: str, columns: list[tuple[str, str]], csv_path: pathlib.Path) -> str:
    defs = ",\n    ".join(f"{col} {typ}" for col, typ in columns)
    return f"""
DROP TABLE IF EXISTS {name};
CREATE TABLE {name} (
    {defs}
);
COPY {name}
FROM {sql_string(str(csv_path))}
(HEADER, DELIMITER ',', QUOTE '"', ESCAPE '"', NULL '');
"""


def load_json(path: pathlib.Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def iso(value: str | None) -> str:
    if not value:
        return ""
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).isoformat()
    except ValueError:
        return value


def path_day(name: str) -> str:
    match = re.search(r"year=(\d{4})/month=(\d{2})/day=(\d{2})", name)
    if not match:
        return ""
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"


def path_session(name: str) -> str:
    match = re.search(r"day=\d{2}/([^/]+)\.jsonl$", name)
    return match.group(1) if match else ""


def session_id(blob: dict[str, Any]) -> str:
    metadata = blob.get("metadata") or {}
    return str(
        metadata.get("sessionId")
        or metadata.get("session_id")
        or path_session(blob.get("name", ""))
    )


def bool_csv(value: bool) -> str:
    return "true" if value else "false"


def maybe_local(download_root: pathlib.Path | None, name: str) -> tuple[str, bool, str]:
    if not download_root:
        return "", False, ""
    local_path = download_root / name
    if not local_path.exists():
        return str(local_path), False, ""
    return str(local_path), True, str(local_path.stat().st_size)


def write_csv(
    path: pathlib.Path, columns: list[tuple[str, str]], rows: list[dict[str, Any]]
) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=[name for name, _ in columns], extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(rows)


def build_database(db_path: pathlib.Path, csv_dir: pathlib.Path) -> None:
    sql_path = db_path.parent / "build_database.sql"
    sql = "\n".join(
        [
            table_sql(
                "conversation_blob_catalog",
                CATALOG_COLUMNS,
                csv_dir / "conversation_blob_catalog.csv",
            ),
            table_sql(
                "conversation_session_snapshots",
                SESSION_COLUMNS,
                csv_dir / "conversation_session_snapshots.csv",
            ),
            table_sql(
                "conversation_day_summary", DAY_COLUMNS, csv_dir / "conversation_day_summary.csv"
            ),
            """
CREATE OR REPLACE VIEW latest_conversation_blobs AS
SELECT *
FROM conversation_blob_catalog
WHERE is_latest_index_member OR is_latest_by_rank;

CREATE OR REPLACE VIEW nonlatest_conversation_snapshots AS
SELECT *
FROM conversation_blob_catalog
WHERE NOT (is_latest_index_member OR is_latest_by_rank);

CREATE OR REPLACE VIEW archive_coverage_summary AS
SELECT
    COUNT(*) AS blobs,
    COUNT(DISTINCT session_id) AS sessions,
    SUM(indexed_bytes) AS indexed_bytes,
    SUM(CASE WHEN is_latest_by_rank THEN 1 ELSE 0 END) AS rank_latest_blobs,
    SUM(CASE WHEN is_latest_index_member THEN 1 ELSE 0 END) AS supplied_latest_blobs,
    SUM(CASE WHEN is_latest_by_rank THEN indexed_bytes ELSE 0 END) AS rank_latest_bytes,
    SUM(CASE WHEN NOT is_latest_by_rank THEN indexed_bytes ELSE 0 END) AS nonlatest_snapshot_bytes,
    MIN(path_day) AS path_day_start,
    MAX(path_day) AS path_day_end,
    MIN(last_modified) AS blob_modified_start,
    MAX(last_modified) AS blob_modified_end
FROM conversation_blob_catalog;
""",
        ]
    )
    sql_path.write_text(sql, encoding="utf-8")
    subprocess.run(["duckdb", str(db_path), f".read {sql_path}"], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--index", required=True, type=pathlib.Path, help="Full conversation blob inventory JSON"
    )
    parser.add_argument(
        "--latest-index", type=pathlib.Path, help="Latest-by-session inventory JSON"
    )
    parser.add_argument("--downloads", type=pathlib.Path, help="Optional local download root")
    parser.add_argument("--out", required=True, type=pathlib.Path, help="Output directory")
    parser.add_argument("--db", type=pathlib.Path, help="DuckDB output path")
    parser.add_argument(
        "--account", default="", help="Optional Azure storage account for source_uri"
    )
    parser.add_argument("--container", default="", help="Optional Azure container for source_uri")
    args = parser.parse_args()

    blobs = load_json(args.index.expanduser())
    latest_names: set[str] | None = None
    if args.latest_index:
        latest_names = {str(item.get("name")) for item in load_json(args.latest_index.expanduser())}

    out_dir = args.out.expanduser()
    csv_dir = out_dir / "csv"
    csv_dir.mkdir(parents=True, exist_ok=True)
    db_path = args.db.expanduser() if args.db else out_dir / "conversation_archive_catalog.duckdb"
    downloads = args.downloads.expanduser() if args.downloads else None

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for blob in blobs:
        if not str(blob.get("name", "")).endswith(".jsonl"):
            continue
        grouped[session_id(blob)].append(blob)

    catalog_rows: list[dict[str, Any]] = []
    session_rows: list[dict[str, Any]] = []
    day_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    blob_id = 0
    mismatched_latest = 0

    for sid, snapshots in sorted(grouped.items()):
        snapshots.sort(
            key=lambda b: (iso(b.get("lastModified")), int(b.get("bytes") or 0), b.get("name", "")),
            reverse=True,
        )
        snapshot_count = len(snapshots)
        latest = snapshots[0]
        latest_name = str(latest.get("name") or "")
        latest_in_index = latest_name in latest_names if latest_names is not None else True
        if latest_names is not None and not latest_in_index:
            mismatched_latest += 1

        path_days = [path_day(str(blob.get("name") or "")) for blob in snapshots]
        modified = [iso(blob.get("lastModified")) for blob in snapshots]
        session_rows.append(
            {
                "session_id": sid,
                "snapshot_count": snapshot_count,
                "total_snapshot_bytes": sum(int(blob.get("bytes") or 0) for blob in snapshots),
                "first_path_day": min((day for day in path_days if day), default=""),
                "last_path_day": max((day for day in path_days if day), default=""),
                "first_blob_modified": min((ts for ts in modified if ts), default=""),
                "last_blob_modified": max((ts for ts in modified if ts), default=""),
                "latest_blob": latest_name,
                "latest_blob_bytes": int(latest.get("bytes") or 0),
                "latest_blob_modified": iso(latest.get("lastModified")),
                "latest_in_supplied_index": bool_csv(latest_in_index),
            }
        )

        for rank, blob in enumerate(snapshots, start=1):
            blob_id += 1
            name = str(blob.get("name") or "")
            metadata = blob.get("metadata") or {}
            local_path, downloaded, local_bytes = maybe_local(downloads, name)
            uri = ""
            if args.account and args.container:
                uri = f"az://{args.account}/{args.container}/{name}"
            row = {
                "blob_id": blob_id,
                "source_blob": name,
                "source_uri": uri,
                "session_id": sid,
                "path_session_id": path_session(name),
                "path_day": path_day(name),
                "path_month": path_day(name)[:7],
                "indexed_bytes": int(blob.get("bytes") or 0),
                "last_modified": iso(blob.get("lastModified")),
                "creation_time": iso(blob.get("creationTime")),
                "content_type": str(blob.get("contentType") or ""),
                "snapshot_rank_desc": rank,
                "snapshot_count_for_session": snapshot_count,
                "is_latest_by_rank": bool_csv(rank == 1),
                "is_latest_index_member": bool_csv(
                    name in latest_names if latest_names is not None else rank == 1
                ),
                "metadata_host_hash": sha256_text(str(metadata.get("host") or "")),
                "metadata_original_path_hash": sha256_text(str(metadata.get("originalPath") or "")),
                "downloaded": bool_csv(downloaded),
                "local_path": local_path,
                "local_bytes": local_bytes,
            }
            catalog_rows.append(row)
            day_groups[row["path_day"]].append(row)

    day_rows: list[dict[str, Any]] = []
    for day, rows in sorted(day_groups.items()):
        latest_rows = [row for row in rows if row["is_latest_by_rank"] == "true"]
        day_rows.append(
            {
                "path_day": day,
                "blob_count": len(rows),
                "latest_blob_count": len(latest_rows),
                "nonlatest_blob_count": len(rows) - len(latest_rows),
                "distinct_sessions": len({row["session_id"] for row in rows}),
                "indexed_bytes": sum(int(row["indexed_bytes"] or 0) for row in rows),
                "latest_indexed_bytes": sum(int(row["indexed_bytes"] or 0) for row in latest_rows),
            }
        )

    write_csv(csv_dir / "conversation_blob_catalog.csv", CATALOG_COLUMNS, catalog_rows)
    write_csv(csv_dir / "conversation_session_snapshots.csv", SESSION_COLUMNS, session_rows)
    write_csv(csv_dir / "conversation_day_summary.csv", DAY_COLUMNS, day_rows)
    build_database(db_path, csv_dir)

    manifest = {
        "index": str(args.index.expanduser()),
        "latest_index": str(args.latest_index.expanduser()) if args.latest_index else "",
        "downloads": str(downloads) if downloads else "",
        "out_dir": str(out_dir),
        "db_path": str(db_path),
        "blobs": len(catalog_rows),
        "sessions": len(session_rows),
        "supplied_latest_blobs": sum(
            1 for row in catalog_rows if row["is_latest_index_member"] == "true"
        ),
        "rank_latest_blobs": sum(1 for row in catalog_rows if row["is_latest_by_rank"] == "true"),
        "nonlatest_snapshots": sum(
            1 for row in catalog_rows if row["is_latest_by_rank"] == "false"
        ),
        "indexed_bytes": sum(int(row["indexed_bytes"] or 0) for row in catalog_rows),
        "rank_latest_bytes": sum(
            int(row["indexed_bytes"] or 0)
            for row in catalog_rows
            if row["is_latest_by_rank"] == "true"
        ),
        "nonlatest_snapshot_bytes": sum(
            int(row["indexed_bytes"] or 0)
            for row in catalog_rows
            if row["is_latest_by_rank"] == "false"
        ),
        "path_day_start": min(
            (row["path_day"] for row in catalog_rows if row["path_day"]), default=""
        ),
        "path_day_end": max(
            (row["path_day"] for row in catalog_rows if row["path_day"]), default=""
        ),
        "blob_modified_start": min(
            (row["last_modified"] for row in catalog_rows if row["last_modified"]), default=""
        ),
        "blob_modified_end": max(
            (row["last_modified"] for row in catalog_rows if row["last_modified"]), default=""
        ),
        "sessions_where_rank_latest_not_in_supplied_index": mismatched_latest,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
