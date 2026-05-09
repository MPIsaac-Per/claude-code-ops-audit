# claude-code-ops-audit

> Methodology and tooling for auditing your own Claude Code session logs.
> Bring your JSONLs, run the pipeline, draw conclusions.

This repository ships **methodology only — no data**. It's the schema, queries,
and audit prompts I used to derive findings about how Claude Code actually
behaves in real long-running sessions, applied to a single operator's corpus
of ~245,000 tool calls across ~4,200 sessions.

If you have your own Claude Code logs (`~/.claude/projects/`), you can run
this pipeline against them and reproduce the analyses on your own data.

## What's in here

| Path | Purpose |
|---|---|
| `schema/01_tables.sql` | The 8 base tables of the event mart |
| `schema/02_views.sql` | 11 derived views (transitions, recovery, candidates, etc.) |
| `ingest/jsonl_to_duckdb.sql` | Pipeline: raw JSONL → mart, all in DuckDB |
| `analyses/model_drift.sql` | Opus 4.5 vs 4.6 vs 4.7 head-to-head |
| `analyses/parallel_tool_calls.sql` | How often the model batches tool calls (spoiler: ~0.04%) |
| `analyses/cache_economics.sql` | Cache-read leverage by session depth |
| `analyses/session_endings.sql` | How sessions actually terminate |
| `analyses/error_distribution.sql` | Which tools fail, how, and how often |
| `analyses/field_manual_protocols.sql` | Field Manual query pack: autonomy half-life, agent loop map, verification-debt surface, stuckness cost, and rescue patterns |
| `analyses/codex_telemetry_filtered.sql` | Codex/OpenTelemetry runtime analysis with stream-loop span and response-delta noise separated from operational telemetry |
| `analyses/build_conversation_archive_catalog.py` | Catalog every rolling conversation blob while marking the canonical latest snapshot per session |
| `analyses/build_telemetry_mart.py` | Build a sanitized OTLP telemetry mart with sensitive values suppressed and hashed |
| `analyses/fpk_count.py` | fpk overall + by category and month (raw JSONL, no mart needed) |
| `analyses/fpk_correlate.py` | fpk by Claude model and CC version (raw JSONL, no mart needed) |
| `analyses/fpk_tui.py` | interactive fpk "rageboard" TUI inspired by devrage (raw JSONL, no mart needed) |
| `audit/RUBRIC.md` | Verification-debt classification rubric |
| `audit/prompt_template.md` | The per-row LLM prompt used in the audit |
| `audit/classify.py` | Parallel classifier using the Anthropic API |
| `skills/agentic-coding-field-manual/` | Codex skill for turning corpus data into public Field Manual research, protocols, and content |
| `skills/claude-code-supercharger/` | Codex skill with evidence-backed Claude Code operating protocols |
| `docs/PERSISTENCE.md` | Storage boundary for local runs, public repo machinery, and private research outputs |
| `docs/METHODOLOGY.md` | Full walkthrough |

## What's NOT in here

- No JSONL data
- No DuckDB database files
- No project names, file paths, or tool result content from any specific corpus
- No labeled audit CSV (text content is sensitive)

## Quick start

### Prerequisites

```bash
brew install duckdb           # or: pip install duckdb
pip install anthropic         # only if you plan to run the audit classifier
export ANTHROPIC_API_KEY=...  # only if you plan to run the audit classifier
```

### 1. Build the mart

```bash
mkdir -p ~/data
duckdb ~/data/claude_code.duckdb <<EOF
SET VARIABLE jsonl_glob = '$HOME/.claude/projects/**/*.jsonl';
.read schema/01_tables.sql
.read ingest/jsonl_to_duckdb.sql
.read schema/02_views.sql
EOF
```

For a typical heavy-user corpus, ingestion takes a few minutes and produces a
DuckDB file in the hundreds of MB to low GB range.

### 2. Run the analyses

Each `.sql` file in `analyses/` is a standalone script with multiple queries
and inline comments. Run them with:

```bash
duckdb ~/data/claude_code.duckdb < analyses/parallel_tool_calls.sql
duckdb ~/data/claude_code.duckdb < analyses/model_drift.sql
duckdb ~/data/claude_code.duckdb < analyses/cache_economics.sql
duckdb ~/data/claude_code.duckdb < analyses/session_endings.sql
duckdb ~/data/claude_code.duckdb < analyses/error_distribution.sql
```

The fpk analyses operate on raw JSONL directly (no mart required):

```bash
python3 analyses/fpk_count.py        # defaults to ~/.claude/projects/
python3 analyses/fpk_correlate.py    # add --corpus PATH for non-default location
python3 analyses/fpk_tui.py          # interactive rageboard dashboard
```

### 2b. Catalog rolling snapshots and telemetry overlays

If your logs are stored as rolling cloud snapshots, do not analyze every blob as
if each one were a distinct session. First catalog the full archive, then point
your behavioral analyses at the latest snapshot per session.

```bash
python3 analyses/build_conversation_archive_catalog.py \
  --index blob_index_live_conversations.json \
  --latest-index blob_index_live_latest_by_session.json \
  --downloads downloads_latest \
  --out .runs/conversation_archive_catalog
```

For Codex/OpenTelemetry exports, build a separate overlay mart. Raw sensitive
attributes such as user emails, account IDs, cwd values, tool arguments, and
tool outputs are not stored as text in this mart.

```bash
python3 analyses/build_telemetry_mart.py \
  --telemetry-root downloads_telemetry \
  --inventory blob_index_live.json \
  --out .runs/telemetry_mart
```

Run the noise-filtered Codex runtime analysis with:

```bash
duckdb .runs/telemetry_mart/telemetry_mart.duckdb < analyses/codex_telemetry_filtered.sql
```

The raw telemetry export can contain many stream receive-loop spans and response
delta logs inside a small number of conversations. Treat raw span/log counts as
coverage, not as conversation volume.

### 2c. Use the fpk tools

The fpk tools scan human prompts in raw Claude Code JSONL logs. They do not
need the DuckDB mart, and by default they use the ubiquitous Claude Code log
root:

```bash
~/.claude/projects
```

Run a quick terminal report:

```bash
python3 analyses/fpk_count.py
python3 analyses/fpk_correlate.py
```

Open the interactive rageboard:

```bash
python3 analyses/fpk_tui.py
```

The TUI has no third-party dependencies; it uses Python's built-in `curses`.
Use `tab` or `1`-`7` to switch panels, arrow keys to scroll, `r` to rescan,
and `q` to quit. For a static/non-interactive report:

```bash
python3 analyses/fpk_tui.py --print
```

For non-standard exports, all three scripts accept `--corpus`; the TUI also
accepts `FPK_CORPUS`:

```bash
python3 analyses/fpk_tui.py --corpus /non/standard/jsonl/export
FPK_CORPUS=/non/standard/jsonl/export python3 analyses/fpk_tui.py --print
```

`fpk_count.py` reports overall counts, category counts, monthly counts, and a
few sample contexts. `fpk_correlate.py` normalizes the rate as f-bombs per
1,000 human prompts by Claude model and Claude Code version. `fpk_tui.py`
combines those surfaces into overview, category, model, version, month,
session, and sample-context panels.

### 3. Run the verification-debt audit (optional)

The `plausible_completion_candidates` view flags assistant turns that look
like they might be unverified completion claims. ~76% of these are false
positives (the keyword heuristic misses verification text or misreads
narrative as a completion claim). The audit pipeline classifies them with an
LLM:

```bash
# Pull a 1,000-row deterministic sample
duckdb ~/data/claude_code.duckdb -c "
COPY (
    SELECT * FROM plausible_completion_candidates
    ORDER BY hash(session_id || row_index_in_session::TEXT)
    LIMIT 1000
) TO 'audit_sample.csv' (HEADER, DELIMITER ',', QUOTE '\"');"

# Split into 100-row chunks
mkdir -p chunks
python3 -c "
import csv
rows = list(csv.reader(open('audit_sample.csv')))
header, data = rows[0], rows[1:]
for i in range(0, len(data), 100):
    n = i // 100 + 1
    with open(f'chunks/audit_chunk_{n:02d}.csv','w',newline='') as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(data[i:i+100])
"

# Classify all chunks (parallel within each chunk; serial across chunks)
python3 audit/classify.py --input-dir chunks --model claude-sonnet-4-6 --workers 10
```

A reference cost: classifying 1,000 rows with Sonnet 4.6 ran ~$3 of API spend
in our reference run.

## What you can find

The `analyses/` queries surface:

- **Parallel tool calls are essentially nonexistent.** Across 245K tool calls,
  the model batched ≥2 tool calls in 0.04% of opportunities. Opus 4.7 has
  zero batched turns. (Despite the API supporting it and the system prompt
  instructing it.)
- **Cache reads dominate to 99.9% in deep sessions.** By turn 200+, the
  agent reads ~194,000 cached tokens for every ~116 fresh tokens.
- **Each Opus generation makes fewer tool errors.** Bash error rate fell
  from 12.57% (Opus 4.5) to 4.98% (Opus 4.7). Same-project filter holds.
- **Opus 4.6 was a thinking regression.** Extended-thinking usage dropped
  from 29.2% (4.5) to 7.2% (4.6), then recovered to 24.2% in 4.7.
- **15% of sessions end mid-tool-stream.** The agent was still working when
  the session ended.
- **Auth is the #1 error mode** in API-integration-heavy corpora. ~51% of
  errors are authentication failures, not hallucinations or bad code.
- **fpk: f-bombs per 1,000 prompts.** This optional friction analysis scans
  prompt text for profanity markers and correlates the rate with model and CLI
  version metadata. Treat it as a deliberately informal proxy for visible
  frustration in a human-AI loop, not as a benchmark. See
  `analyses/fpk_count.py`, `analyses/fpk_correlate.py`, and the interactive
  `analyses/fpk_tui.py` dashboard.

Your numbers will differ. That's the point — run it on your own logs.

## Field Manual skills

This repo also includes two installable Codex skills that turn the audit into a
public operating system for agentic coding:

- `skills/agentic-coding-field-manual/` mines the freshest available corpus
  data, creates non-obvious analyses, extracts the "so what", and packages the
  result into tools, skills, blog briefs, LinkedIn posts, and X threads.
- `skills/claude-code-supercharger/` applies the current operating protocols
  while coding: micro-sprints, loop shaping, verification receipts,
  diagnosis-before-retry, stuckness interrupts, and human rescue.

The key thesis is that elite agentic coding is not just better prompting. It is
management of the agent's execution loop.

Completed Field Manual research should be promoted to a private knowledge base,
while this repo keeps reusable public machinery and `.runs/` stays local. See
`docs/PERSISTENCE.md`.

## Caveats baked into the methodology

1. **The keyword heuristics are crude.** The completion-claim and
   verification-claim flags catch lots of false positives. The audit pipeline
   exists to correct for this. Treat raw heuristic counts as candidates, not
   conclusions.
2. **Tool family bucketing is opinionated.** See `ingest/jsonl_to_duckdb.sql`
   for the family map. Edit it to match your tool surface.
3. **Single-operator findings don't generalize.** What you find on your own
   logs is specific to your workflow. The methodology generalizes; the
   numbers don't.
4. **Sample size matters per cell.** Per-version comparisons need 1,000+
   turns per version for reliable signal. Bucket sparse versions into eras.

## Background

A writeup of findings derived from running this methodology on a single
operator's corpus is forthcoming. Until then, the README and the inline
comments in each `.sql` file capture the core observations.

## Prior art / related

- Anthropic's Claude Code product: <https://docs.claude.com/claude-code>
- DuckDB documentation: <https://duckdb.org/docs/>
- Anthropic Python SDK: <https://github.com/anthropics/anthropic-sdk-python>

## License

MIT — see `LICENSE`.

## Contributing

Methodology PRs and adapter scripts for other agentic CLI tools (Cursor logs,
Codex CLI logs, Aider history, etc.) are welcome. Issues that report
discrepancies or fail-to-reproduce on different corpora are also welcome.
