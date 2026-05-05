#!/usr/bin/env python3
"""fpk_count.py — count f-bomb variations in human user prompts across the
Claude Code JSONL corpus, by category and by month.

A "human user row" is a row of type=user whose content blocks are NOT all
tool_result. The script strips system-injected wrapper tags (system-reminder,
command-name, hook output, etc.) before scanning so we count what the user
actually typed, not harness machinery.

Usage:
    python analyses/fpk_count.py
    python analyses/fpk_count.py --corpus /path/to/jsonl/dir

Defaults to ~/.claude/projects/ (the standard Claude Code log location).

Pair with analyses/fpk_correlate.py for per-model and per-CC-version rates.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


WRAPPER_TAGS = [
    "system-reminder", "command-name", "command-args", "command-message",
    "command-output", "local-command-stdout", "local-command-stderr",
    "user-prompt-submit-hook", "bash-input", "bash-stdout", "bash-stderr",
    "command-stderr", "command-stdout", "command-content",
]
WRAPPER_BLOCK = re.compile(
    r"<(" + "|".join(WRAPPER_TAGS) + r")>.*?</\1>",
    re.DOTALL | re.IGNORECASE,
)
WRAPPER_LOOSE = re.compile(
    r"<(?:" + "|".join(WRAPPER_TAGS) + r")[^>]*/?>",
    re.IGNORECASE,
)

PATTERNS = {
    "fuck (and inflections)":  re.compile(r"\bf+u+c+k+\w*\b", re.IGNORECASE),
    "motherfuck (full form)":  re.compile(r"\bmother\s*f+u+c+k+\w*\b", re.IGNORECASE),
    "censored (f*ck, f**k)":   re.compile(r"\bf[\*#@!]{1,3}ck\w*\b", re.IGNORECASE),
    "fck abbreviations":       re.compile(r"\b(?:fck|fckn|fckin|fcking|fkin|fking|fkn)\w*\b", re.IGNORECASE),
    "wtf / stfu / mf / mofo":  re.compile(r"\b(?:wtf|stfu|mfer|mfers|mofo|fubar|gtfo)\b", re.IGNORECASE),
}


def human_user_text(row):
    if row.get("type") != "user":
        return
    msg = row.get("message")
    if not isinstance(msg, dict):
        return
    content = msg.get("content")
    if isinstance(content, str):
        yield content
        return
    if not isinstance(content, list):
        return
    if content and all(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            t = block.get("text")
            if isinstance(t, str):
                yield t


def strip_wrappers(text):
    text = WRAPPER_BLOCK.sub(" ", text)
    text = WRAPPER_LOOSE.sub(" ", text)
    return text


def main():
    p = argparse.ArgumentParser(description="Count f-bombs in Claude Code JSONL prompts")
    p.add_argument(
        "--corpus",
        default=os.path.expanduser("~/.claude/projects"),
        help="Directory containing JSONL files (recursive). Default: ~/.claude/projects/",
    )
    args = p.parse_args()
    corpus = Path(args.corpus).expanduser()
    if not corpus.exists():
        print(f"Corpus not found: {corpus}", file=sys.stderr)
        sys.exit(1)

    counts = Counter()
    by_month = defaultdict(int)
    samples = {k: [] for k in PATTERNS}
    files_total = sum(1 for _ in corpus.rglob("*.jsonl"))
    files_done = 0
    user_fragments = 0
    chars_scanned = 0
    sessions_with_fbombs = set()

    print(f"Scanning {files_total:,} JSONL files in {corpus} ...", file=sys.stderr)
    for fp in corpus.rglob("*.jsonl"):
        files_done += 1
        if files_done % 500 == 0:
            print(f"  {files_done:,}/{files_total:,} files; running total = {sum(counts.values()):,}", file=sys.stderr)
        try:
            with fp.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        row = json.loads(line)
                    except Exception:
                        continue
                    session_id = row.get("sessionId") or row.get("session_id")
                    ts = row.get("timestamp") or ""
                    month = ts[:7] if isinstance(ts, str) and len(ts) >= 7 else "unknown"
                    for raw in human_user_text(row):
                        cleaned = strip_wrappers(raw)
                        if not cleaned.strip():
                            continue
                        user_fragments += 1
                        chars_scanned += len(cleaned)
                        for label, pat in PATTERNS.items():
                            matches = pat.findall(cleaned)
                            if not matches:
                                continue
                            counts[label] += len(matches)
                            by_month[month] += len(matches)
                            if session_id:
                                sessions_with_fbombs.add(session_id)
                            if len(samples[label]) < 5:
                                m = pat.search(cleaned)
                                if m:
                                    s = max(0, m.start() - 40)
                                    e = min(len(cleaned), m.end() + 40)
                                    snippet = cleaned[s:e].replace("\n", " ").replace("\t", " ")
                                    samples[label].append(snippet)
        except Exception as ex:
            print(f"  ERROR {fp}: {ex}", file=sys.stderr)

    total = sum(counts.values())
    print(f"\n=== Scope ===")
    print(f"Files scanned:                {files_done:,}")
    print(f"Human user text fragments:    {user_fragments:,}")
    print(f"Characters of user text:      {chars_scanned:,}")
    print(f"Sessions with at least one:   {len(sessions_with_fbombs):,}")
    print(f"\n=== F-word counts by category ===")
    for label in PATTERNS:
        print(f"  {label:32s}  {counts[label]:>6,}")
    print(f"  {'-'*32}  {'-'*6}")
    print(f"  {'TOTAL':32s}  {total:>6,}")
    print(f"\n=== By month ===")
    for month in sorted(by_month):
        print(f"  {month}: {by_month[month]:>5,}")
    print(f"\n=== Sample contexts (first match per category) ===")
    for label, ss in samples.items():
        if ss:
            print(f"\n  [{label}]")
            for s in ss[:3]:
                print(f"    ...{s}...")


if __name__ == "__main__":
    main()
