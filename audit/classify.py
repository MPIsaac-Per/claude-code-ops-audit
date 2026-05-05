"""
classify.py — parallel verification-debt classification of plausible
completion candidates using the Anthropic API.

Usage:
    # 1. Generate candidates from the mart
    duckdb your.duckdb -c "
        COPY (SELECT * FROM plausible_completion_candidates ORDER BY hash(session_id || row_index_in_session::TEXT) LIMIT 1000)
        TO 'audit_sample.csv' (HEADER, DELIMITER ',');"

    # 2. Split into 100-row chunks
    python -c "
    import csv, os; os.makedirs('chunks', exist_ok=True)
    rows = list(csv.reader(open('audit_sample.csv')))
    header, data = rows[0], rows[1:]
    for i in range(0, len(data), 100):
        with open(f'chunks/audit_chunk_{i//100+1:02d}.csv','w',newline='') as f:
            w=csv.writer(f); w.writerow(header); w.writerows(data[i:i+100])
    "

    # 3. Run this script
    export ANTHROPIC_API_KEY=...
    python classify.py --input-dir chunks --model claude-sonnet-4-6 --workers 10

    # 4. Merge labeled chunks
    python -c "
    import csv, glob
    rows=[]; header=None
    for p in sorted(glob.glob('chunks/audit_chunk_*_labeled.csv')):
        r=csv.reader(open(p)); h=next(r)
        if header is None: header=h
        rows.extend(r)
    w=csv.writer(open('audit_sample_labeled.csv','w',newline=''))
    w.writerow(header); w.writerows(rows)
    "

The classifier operates by reading the rubric and classifying each row
itself — see RUBRIC.md and prompt_template.md.

This script is intentionally minimal. It uses the official Anthropic Python
SDK and does NOT depend on the Claude Code CLI. Bring your own API key.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

try:
    from anthropic import Anthropic
except ImportError:
    print("Install the official Anthropic SDK:  pip install anthropic", file=sys.stderr)
    sys.exit(1)


# ----------------------------------------------------------------------------
# Prompt (mirrors prompt_template.md)
# ----------------------------------------------------------------------------

RUBRIC = """\
You are classifying a row from a verification-debt audit of Claude Code logs.

CLASSIFICATION RUBRIC

TP (real verification debt):
  - text claims a TASK is done AND
  - no verification visible in the preview AND
  - next_verification_event_index is NULL or >= 5

FP (heuristic misfired): ANY of
  - text is not really a completion claim (narrative, reflection, step transition)
  - verification IS visible in the preview ("tests passed", "8/8 green",
    "build succeeded", explicit pass/fail counts) — heuristic missed it
  - "completion" is intermediate progress not overall task done

AMB (ambiguous): cannot determine from preview alone. Common when the 500-char
preview truncated before the relevant context.

CALIBRATION EXAMPLES

| preview snippet | next_verif | label | reasoning |
|---|---|---|---|
| "Done. SYN-260 marked Done with evidence comment documenting all 6 deployed commits..." | NULL | TP | Marks ticket done with no verification visible |
| "Now I have the full picture. Let me read the CockpitProvider directly..." | 4 | FP | Narrative reflection, not a completion claim |
| "All packages green now (8/8 successful). Committing:" | 2 | FP | "8/8 green" is verification output the heuristic missed |
| "Now let me check the remaining routes to get complete coverage:" | 50 | FP | Step transition ("let me check"), not completion |
| "Done." (text_chars=5, preview_is_full=true) | 100 | AMB | One-word claim, no context to judge what was done |
| "Build successful. Now let me restart the gateway." | 5 | FP | "Build successful" is verification output |
| "I've fixed the issue. Here's the summary:" | NULL | TP | Real completion claim, never verified after |

OUTPUT FORMAT

Reply with ONLY a JSON object — no surrounding prose, no markdown fences.

{
  "classification": "TP" | "FP" | "AMB",
  "real_completion_claim": "Y" | "N",
  "verification_visible": "Y" | "N",
  "confidence": "high" | "medium" | "low",
  "reasoning": "one short sentence specific to THIS row, ≤ 120 chars"
}

The reasoning must reference something specific from THIS row's text_preview.
Do not reuse a template across rows.
"""


def render_row_prompt(row: dict) -> str:
    """Render a single row into the user-message body."""
    parts = [
        "ROW TO CLASSIFY",
        f"  text_preview: {row.get('text_preview', '')!r}",
        f"  text_chars: {row.get('text_chars', '')}",
        f"  preview_is_full: {row.get('preview_is_full', '')}",
        f"  next_verification_event_index: {row.get('next_verification_event_index') or 'NULL'}",
        f"  next_human_message_index: {row.get('next_human_message_index') or 'NULL'}",
        f"  project: {row.get('project', '')}",
        f"  tool_use_count: {row.get('tool_use_count', '')}",
    ]
    return "\n".join(parts)


def classify_row(client: Anthropic, model: str, row: dict) -> dict:
    """Classify a single row. Returns dict with the 5 label fields."""
    body = render_row_prompt(row)

    msg = client.messages.create(
        model=model,
        max_tokens=400,
        system=RUBRIC,
        messages=[{"role": "user", "content": body}],
    )

    text = "".join(b.text for b in msg.content if hasattr(b, "text"))
    text = text.strip()
    if text.startswith("```"):
        # strip code fences if model wraps anyway
        text = text.strip("`")
        first_newline = text.find("\n")
        if first_newline != -1:
            text = text[first_newline + 1:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

    try:
        result = json.loads(text)
    except json.JSONDecodeError:
        result = {
            "classification": "AMB",
            "real_completion_claim": "N",
            "verification_visible": "N",
            "confidence": "low",
            "reasoning": f"PARSE_ERROR: {text[:80]}",
        }

    return result


def classify_chunk(input_path: Path, output_path: Path, client: Anthropic, model: str, workers: int) -> dict:
    with input_path.open() as f:
        rows = list(csv.DictReader(f))

    if not rows:
        return {"input": str(input_path), "rows": 0, "skipped": True}

    header = list(rows[0].keys()) + [
        "classification",
        "real_completion_claim",
        "verification_visible",
        "confidence",
        "reasoning",
    ]

    def fallback(reason: str) -> dict:
        return {
            "classification": "AMB",
            "real_completion_claim": "N",
            "verification_visible": "N",
            "confidence": "low",
            "reasoning": reason,
        }

    labels: list[dict] = [fallback("not classified") for _ in rows]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(classify_row, client, model, row): idx for idx, row in enumerate(rows)}
        for fut in as_completed(futs):
            idx = futs[fut]
            try:
                labels[idx] = fut.result()
            except Exception as exc:
                labels[idx] = fallback(f"API_ERROR: {type(exc).__name__}")

    with output_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        for row, label in zip(rows, labels):
            row.update(label)
            w.writerow(row)

    cls_counts: dict[str, int] = {}
    conf_counts: dict[str, int] = {}
    reasons: set[str] = set()
    for label in labels:
        cls = str(label["classification"])
        conf = str(label["confidence"])
        cls_counts[cls] = cls_counts.get(cls, 0) + 1
        conf_counts[conf] = conf_counts.get(conf, 0) + 1
        reasons.add(str(label["reasoning"]))

    return {
        "input": str(input_path),
        "output": str(output_path),
        "rows": len(rows),
        "classifications": cls_counts,
        "confidence": conf_counts,
        "unique_reasons": len(reasons),
    }


def main() -> None:
    p = argparse.ArgumentParser(description="Verification-debt classifier")
    p.add_argument("--input-dir", required=True, help="Directory containing audit_chunk_NN.csv files")
    p.add_argument("--model", default="claude-sonnet-4-6", help="Anthropic model id")
    p.add_argument("--workers", type=int, default=10, help="Concurrent classifications per chunk")
    args = p.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY environment variable is required.", file=sys.stderr)
        sys.exit(1)

    client = Anthropic()
    in_dir = Path(args.input_dir)
    chunks = sorted(in_dir.glob("audit_chunk_*.csv"))
    chunks = [c for c in chunks if "_labeled" not in c.name]
    if not chunks:
        print(f"No audit_chunk_*.csv files found in {in_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Classifying {len(chunks)} chunks with model={args.model}, workers={args.workers}")

    for chunk in chunks:
        out = chunk.with_name(chunk.stem + "_labeled.csv")
        print(f"\n→ {chunk.name}")
        result = classify_chunk(chunk, out, client, args.model, args.workers)
        print(f"  rows={result['rows']}  classifications={result['classifications']}")
        print(f"  confidence={result['confidence']}  unique_reasons={result['unique_reasons']}")
        if result["unique_reasons"] < result["rows"] * 0.6:
            print("  WARNING: unique reasoning count < 60% of row count — classifier may be templating.")


if __name__ == "__main__":
    main()
