#!/usr/bin/env python3
"""Interactive fpk dashboard for Claude Code JSONL corpora.

This is the TUI counterpart to fpk_count.py and fpk_correlate.py. It scans raw
Claude Code JSONL files, strips harness wrapper tags from human prompts, and
reports f-bombs per 1,000 prompts (fpk) across categories, models, versions,
months, and sessions.

Usage:
    python3 analyses/fpk_tui.py
    python3 analyses/fpk_tui.py --print
    python3 analyses/fpk_tui.py --corpus /non/standard/jsonl/export
"""

from __future__ import annotations

import argparse
import curses
import json
import os
import queue
import re
import sys
import threading
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


WRAPPER_TAGS = [
    "system-reminder",
    "command-name",
    "command-args",
    "command-message",
    "command-output",
    "local-command-stdout",
    "local-command-stderr",
    "user-prompt-submit-hook",
    "bash-input",
    "bash-stdout",
    "bash-stderr",
    "command-stderr",
    "command-stdout",
    "command-content",
]
WRAPPER_BLOCK = re.compile(
    r"<(" + "|".join(WRAPPER_TAGS) + r")>.*?</\1>",
    re.DOTALL | re.IGNORECASE,
)
WRAPPER_LOOSE = re.compile(
    r"<(?:" + "|".join(WRAPPER_TAGS) + r")[^>]*/?>",
    re.IGNORECASE,
)

PATTERNS: dict[str, re.Pattern[str]] = {
    "fuck (and inflections)": re.compile(r"\bf+u+c+k+\w*\b", re.IGNORECASE),
    "motherfuck (full form)": re.compile(r"\bmother\s*f+u+c+k+\w*\b", re.IGNORECASE),
    "censored (f*ck, f**k)": re.compile(r"\bf[\*#@!]{1,3}ck\w*\b", re.IGNORECASE),
    "fck abbreviations": re.compile(
        r"\b(?:fck|fckn|fckin|fcking|fkin|fking|fkn)\w*\b",
        re.IGNORECASE,
    ),
    "wtf / stfu / mf / mofo": re.compile(
        r"\b(?:wtf|stfu|mfer|mfers|mofo|fubar|gtfo)\b",
        re.IGNORECASE,
    ),
}

SPINNER = ["|", "/", "-", "\\"]
TABS = ["overview", "categories", "models", "versions", "months", "sessions", "samples"]
PLACEHOLDER_CORPUS_VALUES = {
    "/path/to/jsonl/dir",
    "path/to/jsonl/dir",
    "/path/to/corpus",
    "path/to/corpus",
    "/path/to/claude/projects",
    "path/to/claude/projects",
}


@dataclass
class Bucket:
    fbombs: int = 0
    prompts: int = 0

    @property
    def fpk(self) -> float:
        return rate(self.fbombs, self.prompts)


@dataclass
class Progress:
    files_done: int = 0
    files_total: int = 0
    fbombs: int = 0
    prompts: int = 0
    current: str = ""
    done: bool = False


@dataclass
class ScanResult:
    corpus: Path
    files_scanned: int = 0
    human_prompts: int = 0
    chars_scanned: int = 0
    sessions_with_fbombs: set[str] = field(default_factory=set)
    by_category: Counter[str] = field(default_factory=Counter)
    by_month: Counter[str] = field(default_factory=Counter)
    by_model: dict[str, Bucket] = field(default_factory=lambda: defaultdict(Bucket))
    by_version_bucket: dict[str, Bucket] = field(default_factory=lambda: defaultdict(Bucket))
    by_version: dict[str, Bucket] = field(default_factory=lambda: defaultdict(Bucket))
    by_session: dict[str, Bucket] = field(default_factory=lambda: defaultdict(Bucket))
    samples: dict[str, list[str]] = field(default_factory=lambda: {k: [] for k in PATTERNS})
    errors: list[str] = field(default_factory=list)

    @property
    def total_fbombs(self) -> int:
        return sum(self.by_category.values())

    @property
    def overall_fpk(self) -> float:
        return rate(self.total_fbombs, self.human_prompts)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Open a TUI for fpk analysis over Claude Code JSONL logs")
    parser.add_argument(
        "--corpus",
        help="Directory containing JSONL files, recursively. Defaults to the standard Claude Code log root.",
    )
    parser.add_argument(
        "--since",
        help="Only include prompts at or after this ISO date/time, for example 2026-01-01",
    )
    parser.add_argument(
        "--min-prompts",
        type=int,
        default=10,
        help="Minimum prompt count for model/version rows in the TUI. Default: 10",
    )
    parser.add_argument(
        "--print",
        action="store_true",
        help="Print a static report instead of opening curses. Useful for CI and non-TTY shells.",
    )
    return parser.parse_args(argv)


def default_corpus_candidates() -> list[Path]:
    candidates = []
    for env_name in ("FPK_CORPUS", "CLAUDE_CODE_PROJECTS", "CLAUDE_PROJECTS"):
        value = os.environ.get(env_name)
        if value:
            candidates.append(Path(value).expanduser())
    candidates.append(Path("~/.claude/projects").expanduser())
    return candidates


def resolve_corpus(raw: str | None) -> Path | None:
    if raw:
        requested = Path(raw).expanduser()
        if requested.exists():
            return requested
        if raw.strip() not in PLACEHOLDER_CORPUS_VALUES:
            return requested

    for candidate in default_corpus_candidates():
        if candidate.exists():
            return candidate
    return None


def parse_since(raw: str | None) -> datetime | None:
    if not raw:
        return None
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
    except ValueError as exc:
        raise SystemExit(f"invalid --since value: {raw}") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def parse_timestamp(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def rate(count: int, prompts: int) -> float:
    return (count / prompts * 1000.0) if prompts else 0.0


def strip_wrappers(text: str) -> str:
    text = WRAPPER_BLOCK.sub(" ", text)
    text = WRAPPER_LOOSE.sub(" ", text)
    return text


def is_human_user(row: dict[str, Any]) -> bool:
    if row.get("type") != "user":
        return False
    msg = row.get("message")
    if not isinstance(msg, dict):
        return False
    content = msg.get("content")
    if isinstance(content, str):
        return True
    if not isinstance(content, list):
        return False
    if content and all(isinstance(block, dict) and block.get("type") == "tool_result" for block in content):
        return False
    return True


def get_user_text(row: dict[str, Any]) -> str:
    msg = row.get("message")
    if not isinstance(msg, dict):
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            text = block.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts)


def normalize_model(model: Any) -> str:
    if not isinstance(model, str) or not model:
        return "unknown"
    base = model.split("/")[-1]
    base = re.sub(r"-\d{8}$", "", base)
    return base


def version_bucket(version: Any) -> str:
    if not isinstance(version, str) or not version:
        return "unknown"
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        return version
    major, minor, patch = (int(part) for part in match.groups())
    if major == 2 and minor == 0:
        return "2.0.x"
    if major == 2 and minor == 1:
        if patch < 30:
            return "2.1.0-29 (early)"
        if patch < 70:
            return "2.1.30-69 (mid)"
        if patch < 100:
            return "2.1.70-99 (late)"
        return "2.1.100+ (current)"
    return f"{major}.{minor}.x"


def count_categories(text: str) -> Counter[str]:
    counts: Counter[str] = Counter()
    for label, pattern in PATTERNS.items():
        matches = pattern.findall(text)
        if matches:
            counts[label] = len(matches)
    return counts


def add_sample(samples: dict[str, list[str]], label: str, pattern: re.Pattern[str], text: str) -> None:
    if len(samples[label]) >= 5:
        return
    match = pattern.search(text)
    if not match:
        return
    start = max(0, match.start() - 48)
    end = min(len(text), match.end() + 48)
    snippet = text[start:end].replace("\n", " ").replace("\t", " ")
    samples[label].append(snippet)


def row_session_id(row: dict[str, Any], fallback: str) -> str:
    session_id = row.get("sessionId") or row.get("session_id") or fallback
    return str(session_id)


def session_label(session_id: str) -> str:
    cleaned = session_id.strip() or "unknown"
    if "/" in cleaned:
        cleaned = cleaned.rsplit("/", 1)[-1]
    return cleaned[:18]


def include_row(row: dict[str, Any], since: datetime | None) -> bool:
    if since is None:
        return True
    ts = parse_timestamp(row.get("timestamp"))
    return ts is None or ts >= since


def assistant_models_for(rows: list[dict[str, Any]]) -> list[tuple[int, str]]:
    models = []
    for index, row in enumerate(rows):
        if row.get("type") != "assistant":
            continue
        msg = row.get("message")
        model = normalize_model(msg.get("model") if isinstance(msg, dict) else None)
        models.append((index, model))
    return models


def attributed_model(index: int, assistant_models: list[tuple[int, str]]) -> str:
    for assistant_index, model in assistant_models:
        if assistant_index > index:
            return model
    previous = "no_assistant_in_session"
    for assistant_index, model in assistant_models:
        if assistant_index < index:
            previous = model
    return previous


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def scan_corpus(
    corpus: Path,
    since: datetime | None = None,
    progress: Callable[[Progress], None] | None = None,
) -> ScanResult:
    corpus = corpus.expanduser()
    if not corpus.exists():
        raise FileNotFoundError(f"Corpus not found: {corpus}")
    files = sorted(corpus.rglob("*.jsonl"))
    result = ScanResult(corpus=corpus)

    for file_index, path in enumerate(files, start=1):
        if progress:
            progress(
                Progress(
                    files_done=file_index - 1,
                    files_total=len(files),
                    fbombs=result.total_fbombs,
                    prompts=result.human_prompts,
                    current=path.name,
                )
            )
        try:
            rows = load_jsonl(path)
        except Exception as exc:
            result.errors.append(f"{path}: {exc}")
            continue

        by_session: dict[str, list[dict[str, Any]]] = defaultdict(list)
        fallback = path.stem
        for row in rows:
            by_session[row_session_id(row, fallback)].append(row)

        for session_id, session_rows in by_session.items():
            assistant_models = assistant_models_for(session_rows)
            for index, row in enumerate(session_rows):
                if not is_human_user(row) or not include_row(row, since):
                    continue
                raw = get_user_text(row)
                cleaned = strip_wrappers(raw)
                if not cleaned.strip():
                    continue

                model = attributed_model(index, assistant_models)
                version = row.get("version") or "unknown"
                bucket = version_bucket(version)
                month = str(row.get("timestamp") or "unknown")[:7]
                category_counts = count_categories(cleaned)
                count = sum(category_counts.values())

                result.human_prompts += 1
                result.chars_scanned += len(cleaned)
                result.by_model[model].prompts += 1
                result.by_version[str(version)].prompts += 1
                result.by_version_bucket[bucket].prompts += 1
                result.by_session[session_id].prompts += 1

                if count:
                    result.sessions_with_fbombs.add(session_id)
                    result.by_session[session_id].fbombs += count
                    result.by_model[model].fbombs += count
                    result.by_version[str(version)].fbombs += count
                    result.by_version_bucket[bucket].fbombs += count
                    result.by_month[month] += count
                    result.by_category.update(category_counts)
                    for label, pattern in PATTERNS.items():
                        if category_counts.get(label):
                            add_sample(result.samples, label, pattern, cleaned)

        result.files_scanned += 1

    if progress:
        progress(
            Progress(
                files_done=len(files),
                files_total=len(files),
                fbombs=result.total_fbombs,
                prompts=result.human_prompts,
                done=True,
            )
        )
    return result


def sorted_buckets(
    buckets: dict[str, Bucket],
    min_prompts: int = 0,
    limit: int | None = None,
) -> list[tuple[str, Bucket]]:
    rows = [
        (key, bucket)
        for key, bucket in buckets.items()
        if bucket.prompts >= min_prompts or bucket.fbombs > 0
    ]
    rows.sort(key=lambda item: (-item[1].fpk, -item[1].fbombs, -item[1].prompts, item[0]))
    return rows[:limit] if limit is not None else rows


def print_report(result: ScanResult, min_prompts: int) -> None:
    print("fpk rageboard")
    print("=============")
    print(f"corpus:              {result.corpus}")
    print(f"files scanned:       {result.files_scanned:,}")
    print(f"human prompts:       {result.human_prompts:,}")
    print(f"total f-bombs:       {result.total_fbombs:,}")
    print(f"overall fpk:         {result.overall_fpk:.2f}")
    print(f"sessions with hits:  {len(result.sessions_with_fbombs):,}")
    print("")
    print("by category")
    for label, count in result.by_category.most_common():
        print(f"  {label:30s} {count:7,}")
    print("")
    print("by model")
    for model, bucket in sorted_buckets(result.by_model, min_prompts=min_prompts, limit=12):
        print(f"  {model:36s} {bucket.fbombs:7,} / {bucket.prompts:8,} prompts  {bucket.fpk:8.2f} fpk")
    print("")
    print("by version bucket")
    for version, bucket in sorted_buckets(result.by_version_bucket, min_prompts=0):
        print(f"  {version:24s} {bucket.fbombs:7,} / {bucket.prompts:8,} prompts  {bucket.fpk:8.2f} fpk")
    if result.errors:
        print("")
        print(f"errors skipped: {len(result.errors):,}")


class TuiState:
    def __init__(self, corpus: Path, since: datetime | None, min_prompts: int) -> None:
        self.corpus = corpus
        self.since = since
        self.min_prompts = min_prompts
        self.tab = 0
        self.scroll = 0
        self.progress = Progress()
        self.result: ScanResult | None = None
        self.error: str | None = None
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.worker: threading.Thread | None = None
        self.spinner_index = 0

    @property
    def scanning(self) -> bool:
        return self.worker is not None and self.worker.is_alive()

    def start_scan(self) -> None:
        if self.scanning:
            return
        self.result = None
        self.error = None
        self.progress = Progress()
        self.scroll = 0
        while not self.events.empty():
            try:
                self.events.get_nowait()
            except queue.Empty:
                break

        def emit(progress: Progress) -> None:
            self.events.put(("progress", progress))

        def run() -> None:
            try:
                result = scan_corpus(self.corpus, self.since, emit)
                self.events.put(("result", result))
            except Exception as exc:
                self.events.put(("error", str(exc)))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def consume_events(self) -> None:
        while True:
            try:
                kind, payload = self.events.get_nowait()
            except queue.Empty:
                return
            if kind == "progress" and isinstance(payload, Progress):
                self.progress = payload
            elif kind == "result" and isinstance(payload, ScanResult):
                self.result = payload
                self.progress.done = True
            elif kind == "error":
                self.error = str(payload)
                self.progress.done = True


def safe_add(screen: curses.window, y: int, x: int, text: object, attr: int = 0) -> None:
    height, width = screen.getmaxyx()
    if y < 0 or y >= height or x >= width:
        return
    value = str(text)
    room = max(0, width - x - 1)
    if room <= 0:
        return
    try:
        screen.addstr(y, x, value[:room], attr)
    except curses.error:
        pass


def color(pair: int, fallback: int = 0) -> int:
    try:
        return curses.color_pair(pair)
    except curses.error:
        return fallback


def init_colors() -> None:
    if not curses.has_colors():
        return
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_RED, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_GREEN, -1)
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_CYAN)


def draw_box(screen: curses.window, y: int, x: int, h: int, w: int, title: str = "") -> None:
    if h < 2 or w < 4:
        return
    safe_add(screen, y, x, "+" + "-" * (w - 2) + "+", color(1))
    for row in range(y + 1, y + h - 1):
        safe_add(screen, row, x, "|", color(1))
        safe_add(screen, row, x + w - 1, "|", color(1))
    safe_add(screen, y + h - 1, x, "+" + "-" * (w - 2) + "+", color(1))
    if title:
        safe_add(screen, y, x + 2, f" {title} ", color(3) | curses.A_BOLD)


def draw_header(screen: curses.window, state: TuiState) -> int:
    width = screen.getmaxyx()[1]
    title = " fpk rageboard "
    safe_add(screen, 0, 0, title.ljust(width - 1), color(5) | curses.A_BOLD)
    since = f" since {state.since.isoformat()}" if state.since else ""
    safe_add(screen, 1, 0, f" {state.corpus}{since}", color(1))
    return 3


def draw_footer(screen: curses.window, state: TuiState) -> None:
    height, width = screen.getmaxyx()
    commands = " tab/1-7 switch  up/down scroll  r rescan  q quit "
    if state.scanning:
        commands += " scanning..."
    safe_add(screen, height - 1, 0, commands.ljust(width - 1), color(5))


def draw_scan(screen: curses.window, state: TuiState, start_y: int) -> None:
    state.spinner_index = (state.spinner_index + 1) % len(SPINNER)
    symbol = SPINNER[state.spinner_index]
    progress = state.progress
    safe_add(screen, start_y, 2, f"{symbol} tallying the damage", color(3) | curses.A_BOLD)
    safe_add(
        screen,
        start_y + 2,
        4,
        f"files: {progress.files_done:,}/{progress.files_total:,}  "
        f"prompts: {progress.prompts:,}  f-bombs: {progress.fbombs:,}",
    )
    if progress.current:
        safe_add(screen, start_y + 3, 4, f"current: {progress.current}")
    if progress.files_total:
        width = max(10, screen.getmaxyx()[1] - 10)
        done = int(width * progress.files_done / max(progress.files_total, 1))
        safe_add(screen, start_y + 5, 4, "[" + "#" * done + "." * (width - done) + "]", color(4))


def draw_tabs(screen: curses.window, state: TuiState, y: int) -> int:
    x = 1
    for index, tab in enumerate(TABS):
        label = f" {index + 1} {tab} "
        attr = color(5) | curses.A_BOLD if index == state.tab else color(1)
        safe_add(screen, y, x, label, attr)
        x += len(label) + 1
    return y + 2


def draw_metric(screen: curses.window, y: int, x: int, w: int, label: str, value: str, attr: int = 0) -> None:
    draw_box(screen, y, x, 5, w, label)
    safe_add(screen, y + 2, x + 2, value, attr | curses.A_BOLD)


def draw_overview(screen: curses.window, result: ScanResult, y: int) -> None:
    _, width = screen.getmaxyx()
    metrics = [
        ("f-bombs", f"{result.total_fbombs:,}", color(2)),
        ("prompts", f"{result.human_prompts:,}", 0),
        ("fpk", f"{result.overall_fpk:.2f}", color(3)),
        ("sessions hit", f"{len(result.sessions_with_fbombs):,}", 0),
    ]
    if width >= 82:
        card_w = max(18, min(28, (width - 8) // 4))
        for index, (label, value, attr) in enumerate(metrics):
            draw_metric(screen, y, 1 + index * (card_w + 1), card_w, label, value, attr)
        row = y + 7
    else:
        card_w = max(18, min(width - 3, 36))
        for index, (label, value, attr) in enumerate(metrics):
            draw_metric(screen, y + index * 5, 1, card_w, label, value, attr)
        row = y + 22

    safe_add(screen, row, 2, "hot zones", color(3) | curses.A_BOLD)
    row += 2
    top_models = sorted_buckets(result.by_model, min_prompts=10, limit=5)
    for name, bucket in top_models:
        safe_add(screen, row, 4, f"{name[:34]:34s} {bucket.fpk:7.2f} fpk  ({bucket.fbombs:,}/{bucket.prompts:,})")
        row += 1

    row += 1
    safe_add(screen, row, 2, "category mix", color(3) | curses.A_BOLD)
    row += 2
    total = max(result.total_fbombs, 1)
    bar_w = max(10, width - 36)
    for label, count in result.by_category.most_common(6):
        filled = int(bar_w * count / total)
        safe_add(screen, row, 4, label[:24].ljust(24))
        safe_add(screen, row, 30, "#" * filled + "." * (bar_w - filled), color(2 if count else 4))
        safe_add(screen, row, 32 + bar_w, f"{count:,}")
        row += 1

    if result.errors:
        safe_add(screen, row + 1, 2, f"skipped {len(result.errors):,} unreadable files", color(3))


def table_rows_for(result: ScanResult, tab: str, min_prompts: int) -> tuple[list[str], list[list[str]]]:
    if tab == "categories":
        rows = [[label, f"{count:,}", f"{count / max(result.total_fbombs, 1) * 100:5.1f}%"] for label, count in result.by_category.most_common()]
        return ["category", "f-bombs", "share"], rows
    if tab == "models":
        rows = [
            [name, f"{bucket.fbombs:,}", f"{bucket.prompts:,}", f"{bucket.fpk:.2f}"]
            for name, bucket in sorted_buckets(result.by_model, min_prompts=min_prompts)
        ]
        return ["model", "f-bombs", "prompts", "fpk"], rows
    if tab == "versions":
        rows = [
            [name, f"{bucket.fbombs:,}", f"{bucket.prompts:,}", f"{bucket.fpk:.2f}"]
            for name, bucket in sorted_buckets(result.by_version_bucket, min_prompts=0)
        ]
        exact = [
            [name, f"{bucket.fbombs:,}", f"{bucket.prompts:,}", f"{bucket.fpk:.2f}"]
            for name, bucket in sorted_buckets(result.by_version, min_prompts=min_prompts, limit=20)
        ]
        if exact:
            rows += [["", "", "", ""], ["exact versions", "", "", ""]] + exact
        return ["version", "f-bombs", "prompts", "fpk"], rows
    if tab == "months":
        rows = [[month, f"{count:,}"] for month, count in sorted(result.by_month.items())]
        return ["month", "f-bombs"], rows
    if tab == "sessions":
        rows = [
            [session_label(name), f"{bucket.fbombs:,}", f"{bucket.prompts:,}", f"{bucket.fpk:.2f}"]
            for name, bucket in sorted_buckets(result.by_session, min_prompts=0, limit=100)
            if bucket.fbombs > 0
        ]
        return ["session", "f-bombs", "prompts", "fpk"], rows
    if tab == "samples":
        rows = []
        for label, snippets in result.samples.items():
            if not snippets:
                continue
            rows.append([label, ""])
            for sample in snippets:
                rows.append(["", f"...{sample}..."])
            rows.append(["", ""])
        return ["category", "sample context"], rows
    return [], []


def draw_table(screen: curses.window, result: ScanResult, state: TuiState, y: int) -> None:
    height, width = screen.getmaxyx()
    tab = TABS[state.tab]
    headers, rows = table_rows_for(result, tab, state.min_prompts)
    if not headers:
        return
    visible_h = max(1, height - y - 2)
    max_rows = max(0, visible_h - 2)
    state.scroll = max(0, min(state.scroll, max(0, len(rows) - max_rows)))

    if tab == "samples":
        widths = [26, max(20, width - 32)]
    elif len(headers) == 2:
        widths = [max(20, width - 18), 12]
    else:
        widths = [max(24, width - 38), 10, 10, 8]

    x = 2
    for header, col_w in zip(headers, widths):
        safe_add(screen, y, x, header[:col_w].ljust(col_w), color(3) | curses.A_BOLD)
        x += col_w + 1
    safe_add(screen, y + 1, 2, "-" * min(width - 4, sum(widths) + len(widths) - 1), color(1))

    for visible_index, row in enumerate(rows[state.scroll : state.scroll + max_rows]):
        x = 2
        attr = curses.A_BOLD if row and row[0] and all(not cell for cell in row[1:]) else 0
        for cell, col_w in zip(row, widths):
            safe_add(screen, y + 2 + visible_index, x, cell[:col_w].ljust(col_w), attr)
            x += col_w + 1


def draw_ready(screen: curses.window, state: TuiState, start_y: int) -> None:
    result = state.result
    if result is None:
        return
    y = draw_tabs(screen, state, start_y)
    if TABS[state.tab] == "overview":
        draw_overview(screen, result, y)
    else:
        draw_table(screen, result, state, y)


def tui_main(screen: curses.window, state: TuiState) -> None:
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    screen.nodelay(True)
    screen.timeout(100)
    init_colors()
    state.start_scan()

    while True:
        state.consume_events()
        screen.erase()
        start_y = draw_header(screen, state)
        if state.error:
            safe_add(screen, start_y + 1, 2, state.error, color(2) | curses.A_BOLD)
        elif state.result is None:
            draw_scan(screen, state, start_y)
        else:
            draw_ready(screen, state, start_y)
        draw_footer(screen, state)
        screen.refresh()

        try:
            key = screen.getch()
        except KeyboardInterrupt:
            return

        if key in (ord("q"), ord("Q")):
            return
        if key in (ord("r"), ord("R")):
            state.start_scan()
        elif key == ord("\t"):
            state.tab = (state.tab + 1) % len(TABS)
            state.scroll = 0
        elif ord("1") <= key <= ord(str(len(TABS))):
            state.tab = key - ord("1")
            state.scroll = 0
        elif key in (curses.KEY_DOWN, ord("j")):
            state.scroll += 1
        elif key in (curses.KEY_UP, ord("k")):
            state.scroll = max(0, state.scroll - 1)
        elif key in (curses.KEY_NPAGE, ord(" ")):
            state.scroll += 10
        elif key == curses.KEY_PPAGE:
            state.scroll = max(0, state.scroll - 10)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    corpus = resolve_corpus(args.corpus)
    since = parse_since(args.since)

    if corpus is None or not corpus.exists():
        if args.corpus and args.corpus.strip() not in PLACEHOLDER_CORPUS_VALUES:
            print(f"Corpus not found: {Path(args.corpus).expanduser()}", file=sys.stderr)
        else:
            print("Claude Code JSONL root not found.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Expected the standard path:", file=sys.stderr)
        print("  ~/.claude/projects", file=sys.stderr)
        print("", file=sys.stderr)
        print("Or set FPK_CORPUS / pass --corpus for a non-standard export.", file=sys.stderr)
        return 2

    if args.print or not sys.stdout.isatty():
        result = scan_corpus(corpus, since)
        print_report(result, args.min_prompts)
        return 0

    state = TuiState(corpus, since, args.min_prompts)
    curses.wrapper(tui_main, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
