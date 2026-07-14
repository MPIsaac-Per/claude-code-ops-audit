# Methodology

This document walks through the full pipeline from raw Claude Code session
JSONL files to publishable findings. It exists so anyone running the audit
on their own corpus can understand what each stage is doing and what the
caveats are.

## The corpus

Claude Code writes session transcripts to JSONL files at
`~/.claude/projects/<project>/<session-id>.jsonl`. Each JSONL line is a
single message, either:

- A user message (the human's input or tool result)
- An assistant message (Claude's response, possibly with tool_use blocks)

The full message is a JSON object with metadata (timestamp, cwd, model,
version, token usage) plus a `message.content` array of content blocks.
Content block types are:

- `text` — Claude's natural language output
- `tool_use` — a tool call with name and input
- `tool_result` — the result of a previous tool call (in user messages only)
- `thinking` — extended thinking blocks

A "session" is a single Claude Code invocation: one or more JSONL files keyed
by session_id.

## Pipeline overview

```
   ~/.claude/projects/**/*.jsonl
              │
              ▼
   ┌─────────────────────┐
   │   ingest pipeline   │   (ingest/jsonl_to_duckdb.sql)
   │   DuckDB read_json  │
   └─────────┬───────────┘
             │
             ▼
   ┌─────────────────────┐
   │     8 base tables   │   (schema/01_tables.sql)
   │  jsonl_rows         │
   │  content_blocks     │
   │  assistant_turns    │
   │  human_messages     │
   │  tool_events        │
   │  progress_events    │
   │  corpus_files       │
   │  session_metrics    │
   └─────────┬───────────┘
             │
             ▼
   ┌─────────────────────┐
   │     11 views        │   (schema/02_views.sql)
   │  tool_transitions   │
   │  error_recovery_*   │
   │  plausible_*        │
   │  ...                │
   └─────────┬───────────┘
             │
             ▼
   ┌─────────────────────────┐     ┌──────────────────────────┐
   │     analyses (SQL)      │     │     audit (LLM)          │
   │  model_drift            │     │  rubric, prompt template │
   │  parallel_tool_calls    │     │  parallel classifier     │
   │  cache_economics        │     │  manual spot check       │
   │  session_endings        │     │                          │
   │  error_distribution     │     │                          │
   └─────────────────────────┘     └──────────────────────────┘
```

## Stage 1: ingest

`ingest/jsonl_to_duckdb.sql` uses DuckDB's `read_json` function to load
JSONL files directly without an intermediate Python step. The pipeline
populates six of the eight base tables:

1. **jsonl_rows** — one row per JSONL line, with the message envelope
   (session_id, timestamp, model, version, token usage, content_block_count)
2. **content_blocks** — explodes `message.content` arrays into individual
   blocks. Records block_type (text / tool_use / tool_result / thinking)
   and block-specific fields (tool_name, command_preview, file_path, etc.)
3. **assistant_turns** — aggregates content_blocks per assistant message.
   Computes `tool_use_count`, `thinking_block_count`, `text_chars`,
   completion_claim and verification_claim flags
4. **human_messages** extracts user-role rows with human text blocks and
   excludes tool-result-only carrier messages.
5. **tool_events** — joins `tool_use` blocks with their corresponding
   `tool_result` blocks, computes sequencing (previous_tool_name,
   next_tool_name), keyword flags on the result text
6. **session_metrics** — per-session aggregations (count of bash events,
   error events, test events, edit events, etc.)

The two optional tables (`progress_events`, `corpus_files`) carry metadata
that depends on additional source material (hook events, file metadata)
and are not strictly required for the analyses.

### Heuristic flags

Several columns are populated by regex-based heuristics applied to text
content. They are conservative (high precision, lower recall) and the
audit pipeline corrects for false positives:

- `completion_claim` — text matches `\b(done|complete|completed|fixed|shipped|merged|implemented|all set|ready for review)\b`
- `verification_claim` — text matches `(tests? pass|build success|0 errors|all green|lint clean|typecheck pass|all checks pass)`
- `keyword_error`, `keyword_auth`, `keyword_not_found`, `keyword_timeout`,
  `keyword_test`, `keyword_git`, `keyword_success` — applied to tool_result text

Tune the regexes in `ingest/jsonl_to_duckdb.sql` to match your corpus's
language conventions.

## Stage 2: views

`schema/02_views.sql` defines 11 reusable views that layer on top of the
base tables. The most useful for analysis:

- `tool_transitions` — pairs of (tool, next_tool) with counts and source/next
  error counts. Powers the operating-loop diagrams.
- `error_recovery_summary` — for each (error_tool, next_tool, distance), how
  often it occurred and whether the next event was also an error or a
  success/test signal.
- `bash_command_patterns` — distribution of Bash commands by shape (simple,
  long_one_liner, multi_line) crossed with pipe/redirect/subshell flags.
- `plausible_completion_candidates` — assistant turns that claimed
  completion but had no verification keyword on the same turn. Used as
  the candidate generator for the verification-debt audit.
- `session_outcome_signals` — per-session boolean flags (has_git_surface,
  has_test_surface, has_file_mutation, is_long_loop, etc.).

## Stage 3: analyses

`analyses/*.sql` files demonstrate specific findings. Each file is
self-contained and runnable as `duckdb your.duckdb < analyses/foo.sql`.

The five analyses ship as starting points, not as exhaustive coverage of
what the mart can produce. See the README for the headline findings each
one supports.

## Stage 4: audit

The verification-debt audit refines the `plausible_completion_candidates`
view from "candidates that the heuristic flagged" to "actually-unverified
completion claims" via LLM-assisted classification.

### Why an audit is required

The candidate generator has a high false-positive rate because:

- Completion-claim language often appears in narrative context ("Now I have
  the full picture"), reflective sentences ("Now I see why X is happening"),
  or step transitions ("Now let me X").
- Verification language often appears in non-keyword forms — explicit
  pass/fail counts ("8/8 green"), commit hashes followed by "merged",
  exit-code 0 outputs, gate tables in markdown.

In our reference run on 1,000 candidate rows, ~76% turned out to be
heuristic misfires. The keyword scan alone is not a reliable signal.

### How the audit works

1. Pull a deterministic random sample from `plausible_completion_candidates`
   using a hash on (session_id, row_index_in_session) — guarantees
   reproducibility across runs.
2. Split into 100-row chunks.
3. For each chunk, dispatch parallel API calls to the Anthropic API. Each
   row is classified independently against the rubric.
4. Each row receives:
   - classification (TP/FP/AMB)
   - real_completion_claim (Y/N)
   - verification_visible (Y/N)
   - confidence (high/medium/low)
   - reasoning (one sentence specific to the row)
5. The labeled output is merged into a single CSV.

### Quality gates

Two checks before trusting the labeled output:

1. **Unique reasoning count.** If the model used <60% as many unique
   reasoning strings as input rows, it's pattern-matching rather than
   reading. Re-run with a stronger model or a sharper prompt.
2. **Spot check.** Manually review ~50 random rows from the labeled output.
   If your agreement rate with the LLM's labels is >85%, trust the rest.
   If 70-85%, use the labels with caveats. If <70%, the labels need to be
   re-derived.

### Model selection

In our reference run:

- **Haiku 4.5** produced 4-9 unique reasoning strings per 100-row chunk
  (template behavior). Cheap (~$2 for 1,000 rows) but classifications were
  low-quality. Not recommended.
- **Sonnet 4.6** produced 100 unique reasoning strings per 100-row chunk
  (genuine per-row judgment). Cost ~$3-5 for 1,000 rows. Recommended for
  this task.
- **Opus 4.7** would likely produce slightly better edge-case judgment at
  ~$30-50 for 1,000 rows. Use only if Sonnet's spot-check agreement is
  below 80%.

## Caveats

1. **Single-operator findings do not generalize.** What you find on your
   own logs is specific to your workflow, your tools, your projects, and
   your prompting style. The methodology generalizes; the specific
   numbers do not.
2. **Tool family bucketing is opinionated.** The `tool_family` field in
   `content_blocks` and `tool_events` reflects judgment calls (is `Skill`
   a delegation tool? is `mcp__playwright__*` a browser tool or an mcp
   tool?). Edit the bucketing in `ingest/jsonl_to_duckdb.sql` to match
   your tool surface.
3. **Time-confounding.** Per-version and per-model comparisons can be
   confounded by workload drift (your tasks change over time). Use
   same-project filters where possible.
4. **Heuristic dependencies are crude.** The flags exist to identify
   candidates, not to deliver verdicts. Audit results should always be
   interpreted as "what the LLM said about the keyword heuristic's
   candidates," not "the ground truth of the corpus."
5. **The 500-character preview is a real limit.** Many ambiguous cases
   resolve clearly with full text. The audit could be improved by going
   back to source JSONL for AMB-classified rows and re-running with the
   full assistant turn content.
6. **Privacy boundary is on you.** This methodology, applied to your own
   logs, will surface project names, file paths, and sensitive content
   from your sessions. The mart and the labeled audit CSVs are private
   data. Sanitize before publishing anything derived from them.
