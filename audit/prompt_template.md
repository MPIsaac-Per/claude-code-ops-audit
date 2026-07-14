# Per-chunk classification prompt

The following prompt is what the classifier sends to the LLM for each chunk
of 100 rows. It bundles the rubric, calibration examples, and operational
instructions in a single self-contained brief.

The prompt is parameterized on `{NN}` (the two-digit chunk number, e.g. `01`).

---

```text
You are auditing 100 rows from a "verification debt" study of Claude Code
tool-use logs. A SQL view flagged ~15K assistant turns where Claude claimed
completion ("done", "fixed", "shipped", etc.) but no verification keyword
(test/build/lint/check/typecheck) was detected nearby. We are sampling 1,000
of these for audit.

For each row in the input CSV, classify it using this rubric:

**TP** (true positive — real verification debt): text claims a TASK is done
AND no verification visible in preview AND `next_verification_event_index`
is NULL or >= 5.

**FP** (false positive — heuristic misfired): any of:
- Not a real completion claim — narrative ("I have the full picture"),
  reflection ("Now I see"), step transition ("now let me X")
- Verification IS visible in the preview that the keyword heuristic missed:
  "tests passed", "8/8 green", "build succeeded", "lint clean", explicit
  pass/fail counts, etc.
- "Completion" is intermediate step not overall task ("file read, now
  editing", "step 4 done, on to 5")

**AMB** (ambiguous): can't determine from preview alone. Common when
`preview_is_full=false` and the 500-char truncation cuts off before
resolving the question, OR claim is real but verification status genuinely
unclear.

**Calibration examples:**

| preview snippet | next_verif | label | reasoning |
|---|---|---|---|
| "Done. SYN-260 marked Done with evidence comment documenting all 6 deployed commits..." | NULL | TP | Marks ticket done with no verification visible |
| "Now I have the full picture. Let me read the CockpitProvider directly..." | 4 | FP | Narrative reflection, not a completion claim |
| "All packages green now (8/8 successful). Committing:" | 2 | FP | "8/8 green" is verification output the heuristic missed |
| "Now let me check the remaining routes to get complete coverage:" | 50 | FP | Step transition ("let me check"), not completion |
| "Done." (text_chars=5, preview_is_full=true) | 100 | AMB | One-word claim, no context to judge what was done |
| "Build successful. Now let me restart the gateway." | 5 | FP | "Build successful" is verification output |
| "I've fixed the issue. Here's the summary:" | NULL | TP | Real completion claim, never verified after |

**Output schema:** input has 27 columns and 100 data rows. Append 5 new columns:
- `classification`: TP / FP / AMB
- `real_completion_claim`: Y / N (is text actually claiming task completion?)
- `verification_visible`: Y / N (does preview contain verification language the
  heuristic missed?)
- `confidence`: high / medium / low
- `reasoning`: one short sentence SPECIFIC to THIS row's text — quote or
  paraphrase the row's actual content. ≤ 120 chars. No surrounding quotes.
  **Do not use a template. Each row's reasoning should be different from every
  other row's reasoning unless two rows are genuinely near-identical.**

**Paths (overwrite any existing labeled file):**
- Input:  `chunks/audit_chunk_{NN}.csv`
- Output: `chunks/audit_chunk_{NN}_labeled.csv`

**How to do it:**

Use Python via the bash tool. Read all 100 rows. For EACH row, read its
text_preview, look at `next_verification_event_index` and
`next_human_message_index`, and produce a row-specific judgment. Do not write
a keyword classifier — you ARE the classifier.

After writing, print:
1. Output row count (must be 101 = header + 100)
2. Counts by classification: TP / FP / AMB
3. Counts by confidence: high / medium / low
4. Unique reasoning string count (must be > 60; if not, redo)

Return a brief summary under 80 words.
```

---

## Notes on prompt design

- **The "you ARE the classifier" line is decisive.** Without it, the model
  often writes a keyword-matching Python function that pretends to classify,
  rather than actually reading and judging each row.
- **The unique-reasoning quality gate** (must produce > 60 unique strings)
  prevents a Haiku-style template-reuse failure mode. See `RUBRIC.md` for the
  full discussion.
- **Calibration examples in the prompt should be diverse.** If all examples
  are TPs, the model anchors high; if all are FPs, it anchors low. The seven
  examples above span all three classes and all four FP sub-types.
- **Chunk size of 100 is the sweet spot** for Haiku/Sonnet/Opus. Smaller
  chunks waste prompt overhead. Larger chunks (200+) increase the chance of
  agent shortcuts on the long tail.
