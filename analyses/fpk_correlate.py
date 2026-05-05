#!/usr/bin/env python3
"""fpk_correlate.py — correlate f-bomb usage with the Claude model and Claude
Code version that was about to receive the prompt.

Attribution rule:
- For each human user row, count f-bombs in its (wrapper-stripped) text.
- Attribute those f-bombs to:
    (a) the row's own `version` field (the CC version running when typed)
    (b) the model on the NEXT assistant row in the same session (the model
        that was about to catch the wrath). If no subsequent assistant row,
        fall back to the previous assistant's model in that session.

Rates are normalized: f-bombs per 1,000 human user prompts attributed to that
bucket, so a model with few prompts isn't unfairly penalized or favored.

Usage:
    python analyses/fpk_correlate.py
    python analyses/fpk_correlate.py --corpus /path/to/jsonl/dir

Defaults to ~/.claude/projects/ (the standard Claude Code log location).

Pair with analyses/fpk_count.py for category and monthly breakdowns.
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
WRAPPER_BLOCK = re.compile(r"<(" + "|".join(WRAPPER_TAGS) + r")>.*?</\1>", re.DOTALL | re.IGNORECASE)
WRAPPER_LOOSE = re.compile(r"<(?:" + "|".join(WRAPPER_TAGS) + r")[^>]*/?>", re.IGNORECASE)

PATTERNS = [
    re.compile(r"\bf+u+c+k+\w*\b", re.IGNORECASE),
    re.compile(r"\bmother\s*f+u+c+k+\w*\b", re.IGNORECASE),
    re.compile(r"\bf[\*#@!]{1,3}ck\w*\b", re.IGNORECASE),
    re.compile(r"\b(?:fck|fckn|fckin|fcking|fkin|fking|fkn)\w*\b", re.IGNORECASE),
    re.compile(r"\b(?:wtf|stfu|mfer|mfers|mofo|fubar|gtfo)\b", re.IGNORECASE),
]


def is_human_user(row):
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
    if content and all(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return False
    return True


def get_user_text(row):
    msg = row.get("message")
    if not isinstance(msg, dict):
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                t = b.get("text")
                if isinstance(t, str):
                    parts.append(t)
        return "\n".join(parts)
    return ""


def strip_wrappers(text):
    text = WRAPPER_BLOCK.sub(" ", text)
    text = WRAPPER_LOOSE.sub(" ", text)
    return text


def count_fbombs(text):
    return sum(len(p.findall(text)) for p in PATTERNS)


def normalize_model(m):
    if not m:
        return "unknown"
    base = m.split("/")[-1]
    base = re.sub(r"-\d{8}$", "", base)
    return base


def version_bucket(v):
    if not v:
        return "unknown"
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", v)
    if not m:
        return v
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
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


def main():
    p = argparse.ArgumentParser(description="Correlate f-bombs with Claude model and CC version")
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

    fbombs_by_model = Counter()
    prompts_by_model = Counter()
    fbombs_by_version = Counter()
    prompts_by_version = Counter()
    fbombs_by_version_bucket = Counter()
    prompts_by_version_bucket = Counter()

    files = sorted(corpus.rglob("*.jsonl"))
    print(f"Scanning {len(files):,} files ...", file=sys.stderr)
    for i, fp in enumerate(files):
        if i and i % 500 == 0:
            print(f"  {i:,}/{len(files):,}  fbombs so far: {sum(fbombs_by_model.values()):,}", file=sys.stderr)
        try:
            with fp.open("r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except Exception as ex:
            print(f"  ERR open {fp}: {ex}", file=sys.stderr)
            continue

        rows = []
        for line in lines:
            try:
                rows.append(json.loads(line))
            except Exception:
                continue

        by_session = defaultdict(list)
        order = defaultdict(int)
        for r in rows:
            sid = r.get("sessionId") or r.get("session_id") or "_no_session"
            r["__order"] = order[sid]
            order[sid] += 1
            by_session[sid].append(r)

        for sid, srows in by_session.items():
            assistant_models = [(idx, normalize_model(r.get("message", {}).get("model")) if isinstance(r.get("message"), dict) else "unknown")
                                for idx, r in enumerate(srows) if r.get("type") == "assistant"]
            for idx, r in enumerate(srows):
                if r.get("type") != "user":
                    continue
                if not is_human_user(r):
                    continue
                version = r.get("version") or "unknown"
                vbucket = version_bucket(version)
                next_model = None
                for aidx, am in assistant_models:
                    if aidx > idx:
                        next_model = am
                        break
                if next_model is None:
                    for aidx, am in assistant_models:
                        if aidx < idx:
                            next_model = am
                if next_model is None:
                    next_model = "no_assistant_in_session"

                prompts_by_model[next_model] += 1
                prompts_by_version[version] += 1
                prompts_by_version_bucket[vbucket] += 1

                text = strip_wrappers(get_user_text(r))
                n = count_fbombs(text)
                if n:
                    fbombs_by_model[next_model] += n
                    fbombs_by_version[version] += n
                    fbombs_by_version_bucket[vbucket] += n

    def print_table(title, fbombs, prompts, key_label="key", min_prompts=10):
        print(f"\n=== {title} ===")
        print(f"  {key_label:36s}  {'fbombs':>7s}  {'prompts':>8s}  {'rate /1k':>10s}")
        keys = sorted(prompts.keys(), key=lambda k: (-fbombs.get(k, 0), -prompts[k]))
        for k in keys:
            n_pr = prompts[k]
            n_fb = fbombs.get(k, 0)
            if n_pr < min_prompts and n_fb == 0:
                continue
            rate = (n_fb / n_pr * 1000) if n_pr else 0
            print(f"  {k:36s}  {n_fb:>7,}  {n_pr:>8,}  {rate:>10.2f}")

    print_table("F-bombs by model (next assistant in session)", fbombs_by_model, prompts_by_model, "model")
    print_table("F-bombs by Claude Code version bucket", fbombs_by_version_bucket, prompts_by_version_bucket, "version bucket", min_prompts=0)
    print_table("F-bombs by exact CC version (top by fbombs)", fbombs_by_version, prompts_by_version, "version", min_prompts=200)

    print(f"\n=== Totals ===")
    print(f"  Total f-bombs: {sum(fbombs_by_model.values()):,}")
    print(f"  Total human prompts: {sum(prompts_by_model.values()):,}")
    overall_rate = sum(fbombs_by_model.values()) / sum(prompts_by_model.values()) * 1000 if prompts_by_model else 0
    print(f"  Overall rate: {overall_rate:.2f} f-bombs per 1,000 prompts")


if __name__ == "__main__":
    main()
