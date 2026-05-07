#!/usr/bin/env python3
"""Build a sanitized DuckDB mart from Codex/OpenTelemetry JSON exports.

Raw telemetry attributes can include user email, account ids, command
arguments, outputs, and cwd values. This mart keeps aggregate-safe selected
fields, hashes suppressed values, and records which sensitive keys appeared.
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
from collections import Counter
from datetime import UTC, datetime
from typing import Any


SENSITIVE_KEYS = {
    "arguments",
    "argument",
    "args",
    "output",
    "input",
    "prompt",
    "cwd",
    "user.email",
    "user.account_id",
    "email",
    "account_id",
    "request.body",
    "response.body",
}

FILES_COLUMNS = [
    ("file_id", "UBIGINT"),
    ("relative_path", "VARCHAR"),
    ("local_path", "VARCHAR"),
    ("path_day", "DATE"),
    ("local_bytes", "UBIGINT"),
    ("inventory_bytes", "UBIGINT"),
    ("blob_modified", "TIMESTAMPTZ"),
    ("parse_error", "VARCHAR"),
    ("resource_log_groups", "UINTEGER"),
    ("resource_span_groups", "UINTEGER"),
    ("resource_metric_groups", "UINTEGER"),
    ("log_records", "UBIGINT"),
    ("spans", "UBIGINT"),
    ("metrics", "UBIGINT"),
    ("event_time_start", "TIMESTAMPTZ"),
    ("event_time_end", "TIMESTAMPTZ"),
]

RESOURCE_COLUMNS = [
    ("resource_id", "UBIGINT"),
    ("file_id", "UBIGINT"),
    ("signal_type", "VARCHAR"),
    ("resource_index", "UINTEGER"),
    ("service_name", "VARCHAR"),
    ("service_version", "VARCHAR"),
    ("sdk_language", "VARCHAR"),
    ("sdk_version", "VARCHAR"),
    ("env", "VARCHAR"),
    ("terminal_type", "VARCHAR"),
    ("host_hash", "VARCHAR"),
    ("machine_hash", "VARCHAR"),
    ("attr_count", "UINTEGER"),
    ("attr_keys", "VARCHAR"),
    ("sensitive_attr_keys", "VARCHAR"),
    ("attr_hash", "VARCHAR"),
]

LOG_COLUMNS = [
    ("log_id", "UBIGINT"),
    ("file_id", "UBIGINT"),
    ("resource_id", "UBIGINT"),
    ("scope_name", "VARCHAR"),
    ("scope_version", "VARCHAR"),
    ("log_index", "UBIGINT"),
    ("observed_time", "TIMESTAMPTZ"),
    ("event_time", "TIMESTAMPTZ"),
    ("severity_number", "INTEGER"),
    ("severity_text", "VARCHAR"),
    ("event_name", "VARCHAR"),
    ("event_kind", "VARCHAR"),
    ("conversation_id_hash", "VARCHAR"),
    ("model", "VARCHAR"),
    ("slug", "VARCHAR"),
    ("originator", "VARCHAR"),
    ("auth_mode", "VARCHAR"),
    ("terminal_type", "VARCHAR"),
    ("success", "VARCHAR"),
    ("duration_ms", "DOUBLE"),
    ("tool_name", "VARCHAR"),
    ("mcp_server", "VARCHAR"),
    ("mcp_server_origin", "VARCHAR"),
    ("decision", "VARCHAR"),
    ("source", "VARCHAR"),
    ("input_token_count", "UBIGINT"),
    ("output_token_count", "UBIGINT"),
    ("cached_token_count", "UBIGINT"),
    ("arguments_chars", "UBIGINT"),
    ("arguments_hash", "VARCHAR"),
    ("output_chars", "UBIGINT"),
    ("output_hash", "VARCHAR"),
    ("body_kind", "VARCHAR"),
    ("body_chars", "UBIGINT"),
    ("body_hash", "VARCHAR"),
    ("attr_count", "UINTEGER"),
    ("attr_keys", "VARCHAR"),
    ("sensitive_attr_keys", "VARCHAR"),
    ("attr_hash", "VARCHAR"),
]

SPAN_COLUMNS = [
    ("span_row_id", "UBIGINT"),
    ("file_id", "UBIGINT"),
    ("resource_id", "UBIGINT"),
    ("scope_name", "VARCHAR"),
    ("scope_version", "VARCHAR"),
    ("trace_id_hash", "VARCHAR"),
    ("span_id_hash", "VARCHAR"),
    ("parent_span_id_hash", "VARCHAR"),
    ("span_name", "VARCHAR"),
    ("span_kind", "INTEGER"),
    ("start_time", "TIMESTAMPTZ"),
    ("end_time", "TIMESTAMPTZ"),
    ("duration_ms", "DOUBLE"),
    ("status_code", "INTEGER"),
    ("status_message_hash", "VARCHAR"),
    ("service_name", "VARCHAR"),
    ("service_version", "VARCHAR"),
    ("tool_name", "VARCHAR"),
    ("model", "VARCHAR"),
    ("provider", "VARCHAR"),
    ("rpc_method", "VARCHAR"),
    ("api_path", "VARCHAR"),
    ("code_module", "VARCHAR"),
    ("code_file_path", "VARCHAR"),
    ("code_line_number", "INTEGER"),
    ("target", "VARCHAR"),
    ("cwd_hash", "VARCHAR"),
    ("cwd_environment", "VARCHAR"),
    ("turn_id_hash", "VARCHAR"),
    ("call_id_hash", "VARCHAR"),
    ("attr_count", "UINTEGER"),
    ("attr_keys", "VARCHAR"),
    ("sensitive_attr_keys", "VARCHAR"),
    ("attr_hash", "VARCHAR"),
]

ATTR_KEY_COLUMNS = [
    ("signal_type", "VARCHAR"),
    ("attr_key", "VARCHAR"),
    ("record_count", "UBIGINT"),
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


def path_day(path: str) -> str:
    match = re.search(r"year=(\d{4})/month=(\d{2})/day=(\d{2})", path)
    if not match:
        return ""
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}"


def ns_to_iso(value: Any) -> str:
    if value in (None, "", "0", 0):
        return ""
    try:
        ns = int(value)
    except (TypeError, ValueError):
        return ""
    seconds, nanos = divmod(ns, 1_000_000_000)
    dt = datetime.fromtimestamp(seconds, tz=UTC).replace(microsecond=nanos // 1000)
    return dt.isoformat()


def parse_iso(value: Any) -> str:
    if not value:
        return ""
    text = str(value)
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).isoformat()
    except ValueError:
        return text


def otel_value(value: dict[str, Any] | None) -> Any:
    if not isinstance(value, dict):
        return ""
    if "stringValue" in value:
        return value.get("stringValue") or ""
    if "intValue" in value:
        return value.get("intValue") or ""
    if "doubleValue" in value:
        return value.get("doubleValue") or ""
    if "boolValue" in value:
        return value.get("boolValue")
    if "arrayValue" in value:
        return json.dumps(value.get("arrayValue"), separators=(",", ":"), sort_keys=True)
    if "kvlistValue" in value:
        return json.dumps(value.get("kvlistValue"), separators=(",", ":"), sort_keys=True)
    if "bytesValue" in value:
        return "[bytes]"
    return ""


def attrs_to_dict(attrs: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if not isinstance(attrs, list):
        return out
    for attr in attrs:
        if not isinstance(attr, dict):
            continue
        key = str(attr.get("key") or "")
        if not key:
            continue
        out[key] = otel_value(attr.get("value"))
    return out


def attr_keys(attrs: dict[str, Any]) -> str:
    return "|".join(sorted(attrs))


def sensitive_keys(attrs: dict[str, Any]) -> str:
    return "|".join(key for key in sorted(attrs) if key.lower() in SENSITIVE_KEYS)


def attr_hash(attrs: dict[str, Any]) -> str:
    sanitized = {}
    for key, value in sorted(attrs.items()):
        text = str(value)
        if key.lower() in SENSITIVE_KEYS:
            sanitized[key] = {"sha256": sha256_text(text), "chars": len(text)}
        else:
            sanitized[key] = value
    return sha256_text(json.dumps(sanitized, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def safe_str(attrs: dict[str, Any], key: str) -> str:
    if key.lower() in SENSITIVE_KEYS:
        return ""
    value = attrs.get(key)
    if value is None:
        return ""
    return str(value)


def safe_int(attrs: dict[str, Any], key: str) -> str:
    value = attrs.get(key)
    if value in (None, ""):
        return ""
    try:
        return str(int(str(value)))
    except ValueError:
        return ""


def safe_float(attrs: dict[str, Any], key: str) -> str:
    value = attrs.get(key)
    if value in (None, ""):
        return ""
    try:
        return str(float(str(value)))
    except ValueError:
        return ""


def value_chars_hash(attrs: dict[str, Any], key: str) -> tuple[str, str]:
    value = attrs.get(key)
    if value in (None, ""):
        return "", ""
    text = str(value)
    return str(len(text)), sha256_text(text)


def body_features(body: Any) -> tuple[str, str, str]:
    if body is None:
        return "null", "0", ""
    value = otel_value(body) if isinstance(body, dict) else body
    text = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"), sort_keys=True)
    return type(value).__name__, str(len(text)), sha256_text(text)


def cwd_environment(cwd: str) -> str:
    if not cwd:
        return ""
    if cwd.startswith("/Users/"):
        return "macbook"
    if cwd.startswith("/opt/") or cwd.startswith("/home/"):
        return "server"
    return "other"


def load_inventory(path: pathlib.Path | None) -> dict[str, dict[str, Any]]:
    if not path:
        return {}
    with path.expanduser().open("r", encoding="utf-8") as handle:
        rows = json.load(handle)
    return {str(row.get("name") or ""): row for row in rows if row.get("name")}


def write_header(path: pathlib.Path, columns: list[tuple[str, str]]) -> tuple[Any, csv.DictWriter]:
    handle = path.open("w", newline="", encoding="utf-8")
    writer = csv.DictWriter(handle, fieldnames=[name for name, _ in columns], extrasaction="ignore")
    writer.writeheader()
    return handle, writer


def build_database(db_path: pathlib.Path, csv_dir: pathlib.Path) -> None:
    sql_path = db_path.parent / "build_database.sql"
    sql = "\n".join(
        [
            table_sql("telemetry_files", FILES_COLUMNS, csv_dir / "telemetry_files.csv"),
            table_sql("telemetry_resources", RESOURCE_COLUMNS, csv_dir / "telemetry_resources.csv"),
            table_sql("telemetry_logs", LOG_COLUMNS, csv_dir / "telemetry_logs.csv"),
            table_sql("telemetry_spans", SPAN_COLUMNS, csv_dir / "telemetry_spans.csv"),
            table_sql("telemetry_attr_key_counts", ATTR_KEY_COLUMNS, csv_dir / "telemetry_attr_key_counts.csv"),
            """
CREATE OR REPLACE VIEW telemetry_coverage_summary AS
SELECT
    COUNT(*) AS files,
    SUM(local_bytes) AS local_bytes,
    SUM(log_records) AS log_records,
    SUM(spans) AS spans,
    SUM(metrics) AS metrics,
    MIN(path_day) AS path_day_start,
    MAX(path_day) AS path_day_end,
    MIN(event_time_start) AS event_time_start,
    MAX(event_time_end) AS event_time_end,
    SUM(CASE WHEN parse_error IS NOT NULL THEN 1 ELSE 0 END) AS parse_error_files
FROM telemetry_files;

CREATE OR REPLACE VIEW telemetry_event_day_summary AS
SELECT event_day, SUM(log_records) AS log_records, SUM(spans) AS spans
FROM (
    SELECT CAST(event_time AS DATE) AS event_day, COUNT(*) AS log_records, 0::UBIGINT AS spans
    FROM telemetry_logs
    WHERE event_time IS NOT NULL
    GROUP BY 1
    UNION ALL
    SELECT CAST(start_time AS DATE) AS event_day, 0::UBIGINT AS log_records, COUNT(*) AS spans
    FROM telemetry_spans
    WHERE start_time IS NOT NULL
    GROUP BY 1
)
GROUP BY event_day;

CREATE OR REPLACE VIEW telemetry_sensitive_suppression_summary AS
SELECT 'logs' AS signal_type, sensitive_attr_keys, COUNT(*) AS records
FROM telemetry_logs
WHERE sensitive_attr_keys IS NOT NULL
GROUP BY 1, 2
UNION ALL
SELECT 'spans' AS signal_type, sensitive_attr_keys, COUNT(*) AS records
FROM telemetry_spans
WHERE sensitive_attr_keys IS NOT NULL
GROUP BY 1, 2
UNION ALL
SELECT 'resources' AS signal_type, sensitive_attr_keys, COUNT(*) AS records
FROM telemetry_resources
WHERE sensitive_attr_keys IS NOT NULL
GROUP BY 1, 2;
""",
        ]
    )
    sql_path.write_text(sql, encoding="utf-8")
    subprocess.run(["duckdb", str(db_path), f".read {sql_path}"], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--telemetry-root", required=True, type=pathlib.Path)
    parser.add_argument("--inventory", type=pathlib.Path, help="Optional Azure blob inventory JSON")
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--db", type=pathlib.Path)
    parser.add_argument("--progress-every", type=int, default=1000)
    args = parser.parse_args()

    root = args.telemetry_root.expanduser()
    out_dir = args.out.expanduser()
    csv_dir = out_dir / "csv"
    csv_dir.mkdir(parents=True, exist_ok=True)
    db_path = args.db.expanduser() if args.db else out_dir / "telemetry_mart.duckdb"
    inventory = load_inventory(args.inventory)

    files = sorted(root.rglob("*.otlp"))
    file_handle, file_writer = write_header(csv_dir / "telemetry_files.csv", FILES_COLUMNS)
    resource_handle, resource_writer = write_header(csv_dir / "telemetry_resources.csv", RESOURCE_COLUMNS)
    log_handle, log_writer = write_header(csv_dir / "telemetry_logs.csv", LOG_COLUMNS)
    span_handle, span_writer = write_header(csv_dir / "telemetry_spans.csv", SPAN_COLUMNS)

    attr_counts: Counter[tuple[str, str]] = Counter()
    totals = Counter()
    resource_id = 0
    log_id = 0
    span_row_id = 0

    try:
        for file_id, path in enumerate(files, start=1):
            if args.progress_every and file_id % args.progress_every == 0:
                print(f"parsed {file_id:,}/{len(files):,} telemetry files", file=sys.stderr)
            rel = str(path.relative_to(root))
            source_blob = rel if rel.startswith("telemetry/") else f"telemetry/{rel}"
            inv = inventory.get(source_blob, {})
            file_counts = Counter()
            file_event_times: list[str] = []
            parse_error = ""
            try:
                payload = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except Exception as exc:  # noqa: BLE001
                payload = {}
                parse_error = repr(exc)

            for signal_type, group_key, scope_key, record_key in [
                ("logs", "resourceLogs", "scopeLogs", "logRecords"),
                ("spans", "resourceSpans", "scopeSpans", "spans"),
                ("metrics", "resourceMetrics", "scopeMetrics", "metrics"),
            ]:
                groups = payload.get(group_key) or []
                file_counts[f"resource_{signal_type}_groups"] += len(groups)
                for group_index, group in enumerate(groups):
                    resource_id += 1
                    resource_attrs = attrs_to_dict((group.get("resource") or {}).get("attributes"))
                    for key in resource_attrs:
                        attr_counts[(f"{signal_type}_resource", key)] += 1
                    service_name = str(resource_attrs.get("service.name") or "")
                    service_version = str(resource_attrs.get("service.version") or "")
                    resource_writer.writerow(
                        {
                            "resource_id": resource_id,
                            "file_id": file_id,
                            "signal_type": signal_type,
                            "resource_index": group_index,
                            "service_name": service_name,
                            "service_version": service_version,
                            "sdk_language": safe_str(resource_attrs, "telemetry.sdk.language"),
                            "sdk_version": safe_str(resource_attrs, "telemetry.sdk.version"),
                            "env": safe_str(resource_attrs, "env"),
                            "terminal_type": safe_str(resource_attrs, "terminal.type"),
                            "host_hash": sha256_text(str(resource_attrs.get("host.name") or "")),
                            "machine_hash": sha256_text(str(resource_attrs.get("machine.name") or "")),
                            "attr_count": len(resource_attrs),
                            "attr_keys": attr_keys(resource_attrs),
                            "sensitive_attr_keys": sensitive_keys(resource_attrs),
                            "attr_hash": attr_hash(resource_attrs),
                        }
                    )

                    scopes = group.get(scope_key) or []
                    for scope_group in scopes:
                        scope = scope_group.get("scope") or {}
                        scope_name = str(scope.get("name") or "")
                        scope_version = str(scope.get("version") or "")
                        records = scope_group.get(record_key) or []
                        if signal_type == "metrics":
                            file_counts["metrics"] += len(records)
                            totals["metrics"] += len(records)
                            continue
                        for record_index, record in enumerate(records):
                            attrs = attrs_to_dict(record.get("attributes"))
                            for key in attrs:
                                attr_counts[(signal_type, key)] += 1
                            keys = attr_keys(attrs)
                            sensitive = sensitive_keys(attrs)
                            digest = attr_hash(attrs)
                            if signal_type == "logs":
                                log_id += 1
                                observed_time = ns_to_iso(record.get("observedTimeUnixNano"))
                                event_time = parse_iso(attrs.get("event.timestamp")) or ns_to_iso(record.get("timeUnixNano")) or observed_time
                                if event_time:
                                    file_event_times.append(event_time)
                                arg_chars, arg_hash = value_chars_hash(attrs, "arguments")
                                out_chars, out_hash = value_chars_hash(attrs, "output")
                                body_kind, body_chars, body_hash = body_features(record.get("body"))
                                log_writer.writerow(
                                    {
                                        "log_id": log_id,
                                        "file_id": file_id,
                                        "resource_id": resource_id,
                                        "scope_name": scope_name,
                                        "scope_version": scope_version,
                                        "log_index": record_index,
                                        "observed_time": observed_time,
                                        "event_time": event_time,
                                        "severity_number": record.get("severityNumber") or "",
                                        "severity_text": record.get("severityText") or "",
                                        "event_name": safe_str(attrs, "event.name"),
                                        "event_kind": safe_str(attrs, "event.kind"),
                                        "conversation_id_hash": sha256_text(str(attrs.get("conversation.id") or "")),
                                        "model": safe_str(attrs, "model"),
                                        "slug": safe_str(attrs, "slug"),
                                        "originator": safe_str(attrs, "originator"),
                                        "auth_mode": safe_str(attrs, "auth_mode"),
                                        "terminal_type": safe_str(attrs, "terminal.type"),
                                        "success": safe_str(attrs, "success"),
                                        "duration_ms": safe_float(attrs, "duration_ms"),
                                        "tool_name": safe_str(attrs, "tool_name"),
                                        "mcp_server": safe_str(attrs, "mcp_server"),
                                        "mcp_server_origin": safe_str(attrs, "mcp_server_origin"),
                                        "decision": safe_str(attrs, "decision"),
                                        "source": safe_str(attrs, "source"),
                                        "input_token_count": safe_int(attrs, "input_token_count"),
                                        "output_token_count": safe_int(attrs, "output_token_count"),
                                        "cached_token_count": safe_int(attrs, "cached_token_count"),
                                        "arguments_chars": arg_chars,
                                        "arguments_hash": arg_hash,
                                        "output_chars": out_chars,
                                        "output_hash": out_hash,
                                        "body_kind": body_kind,
                                        "body_chars": body_chars,
                                        "body_hash": body_hash,
                                        "attr_count": len(attrs),
                                        "attr_keys": keys,
                                        "sensitive_attr_keys": sensitive,
                                        "attr_hash": digest,
                                    }
                                )
                                file_counts["log_records"] += 1
                                totals["log_records"] += 1
                            elif signal_type == "spans":
                                span_row_id += 1
                                start_time = ns_to_iso(record.get("startTimeUnixNano"))
                                end_time = ns_to_iso(record.get("endTimeUnixNano"))
                                if start_time:
                                    file_event_times.append(start_time)
                                start_ns = int(record.get("startTimeUnixNano") or 0)
                                end_ns = int(record.get("endTimeUnixNano") or 0)
                                duration_ms = (end_ns - start_ns) / 1_000_000 if start_ns and end_ns else ""
                                status = record.get("status") or {}
                                cwd = str(attrs.get("cwd") or "")
                                span_writer.writerow(
                                    {
                                        "span_row_id": span_row_id,
                                        "file_id": file_id,
                                        "resource_id": resource_id,
                                        "scope_name": scope_name,
                                        "scope_version": scope_version,
                                        "trace_id_hash": sha256_text(str(record.get("traceId") or "")),
                                        "span_id_hash": sha256_text(str(record.get("spanId") or "")),
                                        "parent_span_id_hash": sha256_text(str(record.get("parentSpanId") or "")),
                                        "span_name": record.get("name") or "",
                                        "span_kind": record.get("kind") or "",
                                        "start_time": start_time,
                                        "end_time": end_time,
                                        "duration_ms": duration_ms,
                                        "status_code": status.get("code") or "",
                                        "status_message_hash": sha256_text(str(status.get("message") or "")),
                                        "service_name": service_name,
                                        "service_version": service_version,
                                        "tool_name": safe_str(attrs, "tool_name"),
                                        "model": safe_str(attrs, "model"),
                                        "provider": safe_str(attrs, "provider"),
                                        "rpc_method": safe_str(attrs, "rpc.method"),
                                        "api_path": safe_str(attrs, "api.path"),
                                        "code_module": safe_str(attrs, "code.module.name"),
                                        "code_file_path": safe_str(attrs, "code.file.path"),
                                        "code_line_number": safe_int(attrs, "code.line.number"),
                                        "target": safe_str(attrs, "target"),
                                        "cwd_hash": sha256_text(cwd),
                                        "cwd_environment": cwd_environment(cwd),
                                        "turn_id_hash": sha256_text(str(attrs.get("turn_id") or "")),
                                        "call_id_hash": sha256_text(str(attrs.get("call_id") or "")),
                                        "attr_count": len(attrs),
                                        "attr_keys": keys,
                                        "sensitive_attr_keys": sensitive,
                                        "attr_hash": digest,
                                    }
                                )
                                file_counts["spans"] += 1
                                totals["spans"] += 1

            file_writer.writerow(
                {
                    "file_id": file_id,
                    "relative_path": rel,
                    "local_path": str(path),
                    "path_day": path_day(rel),
                    "local_bytes": path.stat().st_size,
                    "inventory_bytes": inv.get("bytes") or "",
                    "blob_modified": parse_iso(inv.get("lastModified")),
                    "parse_error": parse_error,
                    "resource_log_groups": file_counts["resource_logs_groups"],
                    "resource_span_groups": file_counts["resource_spans_groups"],
                    "resource_metric_groups": file_counts["resource_metrics_groups"],
                    "log_records": file_counts["log_records"],
                    "spans": file_counts["spans"],
                    "metrics": file_counts["metrics"],
                    "event_time_start": min(file_event_times) if file_event_times else "",
                    "event_time_end": max(file_event_times) if file_event_times else "",
                }
            )
    finally:
        for handle in [file_handle, resource_handle, log_handle, span_handle]:
            handle.close()

    with (csv_dir / "telemetry_attr_key_counts.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[name for name, _ in ATTR_KEY_COLUMNS], extrasaction="ignore")
        writer.writeheader()
        for (signal_type, key), count in sorted(attr_counts.items()):
            writer.writerow({"signal_type": signal_type, "attr_key": key, "record_count": count})

    build_database(db_path, csv_dir)
    manifest = {
        "telemetry_root": str(root),
        "inventory": str(args.inventory.expanduser()) if args.inventory else "",
        "out_dir": str(out_dir),
        "db_path": str(db_path),
        "files": len(files),
        "log_records": totals["log_records"],
        "spans": totals["spans"],
        "metrics": totals["metrics"],
        "sensitive_keys_suppressed": sorted(SENSITIVE_KEYS),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
