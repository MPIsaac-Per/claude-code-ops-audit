# Verification debt classification rubric

Used to label the output of `plausible_completion_candidates` (defined in
`schema/02_views.sql`) into one of three classes: TP, FP, or AMB.

The candidate generator is a keyword heuristic: assistant turns that contain
completion-claim language (`done`, `complete`, `fixed`, `shipped`, etc.) AND
do NOT contain verification-claim language (`tests passed`, `build succeeded`,
etc.) on the same turn. About 76% of these candidates turn out to be heuristic
misfires when manually classified — see the methodology doc for the full
audit results.

## The three classes

### TP (true positive — real verification debt)

The text **claims a TASK was completed** AND no verification is visible in
the preview AND `next_verification_event_index` is NULL or >= 5.

Signals:

- "Done. [feature/ticket/PR] is now [shipped/marked/closed/merged]."
- "All tasks complete. Here's the summary..."
- "Fixed. The issue was..."
- "Implemented [thing] in [file]."

The defining property: the agent asserted task completion AND there is no
observable verification artifact (no test output, no build success line, no
explicit pass/fail count) within the preview or in the subsequent tool
stream.

### FP (false positive — heuristic misfire)

ANY of the following:

1. **Not actually a completion claim.** The text uses keywords like "complete"
   or "done" in a non-completion sense:
   - Narrative reflection: *"Now I have the full picture."*
   - Insight: *"Now I see why X is happening."*
   - Step transition: *"Now let me check the next thing."* / *"Let me complete
     this analysis by..."*
   - Self-introduction: *"I'm ready to help you..."* (skipped reasoning, not
     completion)

2. **Verification IS visible in the preview** but the keyword scan missed it:
   - *"All packages green now (8/8 successful)."* — "8/8 green" is verification
   - *"Build successful. Now restarting."* — "build successful" is verification
   - *"Typecheck passed."* — explicit verification
   - Commit hashes followed by pass/fail counts
   - *"31/31 green."*

3. **"Completion" is intermediate progress, not overall task done:**
   - *"I've read the file, now let me edit it."*
   - *"Step 4 done, moving to step 5."*

### AMB (ambiguous — cannot determine from preview alone)

Most common when `preview_is_full = false` and the 500-character truncation
cuts off before the relevant context. Or the claim is real but the
verification status is genuinely unclear from the visible text.

When in doubt, prefer AMB over a low-confidence TP/FP.

## Calibration examples

| text_preview snippet | next_verif | label | reasoning |
|---|---|---|---|
| "Done. SYN-260 marked Done with evidence comment documenting all 6 deployed commits..." | NULL | TP | Marks ticket done with no verification visible |
| "Now I have the full picture. Let me read the CockpitProvider directly..." | 4 | FP | Narrative reflection, not a completion claim |
| "All packages green now (8/8 successful). Committing:" | 2 | FP | "8/8 green" is verification output the heuristic missed |
| "Now let me check the remaining routes to get complete coverage:" | 50 | FP | Step transition ("let me check"), not completion |
| "Done." (text_chars=5, preview_is_full=true) | 100 | AMB | One-word claim, no context to judge what was done |
| "Build successful. Now let me restart the gateway." | 5 | FP | "Build successful" is verification output |
| "I've fixed the issue. Here's the summary:" | NULL | TP | Real completion claim, never verified after |

## Output schema

For each row, the classifier emits five new columns:

| Column | Type | Meaning |
|---|---|---|
| `classification` | TP / FP / AMB | The class label |
| `real_completion_claim` | Y / N | Is the text actually claiming a task is done? |
| `verification_visible` | Y / N | Does the preview contain verification language the heuristic missed? |
| `confidence` | high / medium / low | Confidence in this row's classification |
| `reasoning` | text (≤120 chars) | One sentence specific to THIS row's content. No template re-use. |

## Calibration discipline

The reasoning column is the highest-leverage quality signal. If you find that
your classifier is producing the same reasoning string across many rows
(template re-use), the classifier is pattern-matching rather than reading.

Quality gate: run `select count(distinct reasoning), count(*) from labeled`
on the output. The unique-reason count should be approximately equal to the
row count. If it's <60% of the row count, the classifier likely needs to be
re-prompted or the model swapped.

In our reference run, **Haiku 4.5 produced 4-9 unique reasonings across 100
rows per chunk** (template behavior). **Sonnet 4.6 produced 100 unique
reasonings out of 100 rows per chunk** (genuine per-row judgment). The
difference is large and worth verifying before trusting the labels.
