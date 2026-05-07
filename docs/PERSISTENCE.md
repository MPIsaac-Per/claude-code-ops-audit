# Research Persistence

This repo separates reusable public machinery from private research outputs.

## Storage Tiers

### Private Knowledge Base: Completed Research Source Of Truth

Completed Field Manual research belongs in your private knowledge base, not in
this public methodology repo:

```text
<private-knowledge-base>/agentic-coding-research/
```

Use a timestamped Markdown brief for every completed analysis:

```text
YYYYMMDDHHMMSS_Field_Manual_<Finding_Name>.md
```

Use a private research-brief template if your knowledge base has one:

```text
<private-knowledge-base>/agentic-coding-research/_templates/research_brief.md
```

Small reproducibility bundles may live under:

```text
<private-knowledge-base>/agentic-coding-research/_data/YYYYMMDDHHMMSS_<slug>/
```

Allowed private bundle files:

- `manifest.json`
- `queries.sql`
- `results_summary.csv`
- `chart_specs.json`
- `content_brief.md`
- `linkedin_post.md`
- `x_thread.md`

Do not put `.duckdb`, `.parquet`, raw `.jsonl`, heavy CSV extracts, labeled
audit rows, secrets, or private prompt/tool-result text in private bundles.

### This Repo: Public Method And Machinery

Persist only reusable, public-safe artifacts here:

- SQL analysis packs
- schema and ingest code
- installable skills
- templates
- docs and methodology
- sanitized examples

Do not commit run outputs or private corpus extracts.

### Local Run Folders: Messy Execution Trace

Use gitignored local folders for active analysis:

```text
.runs/YYYYMMDD-HHMMSS-<slug>/
  run.log
  stdout.txt
  manifest.json
  results.csv
  notes.md
```

Promote only cleaned summaries, query files, content drafts, and reproducibility
metadata into your private knowledge base.

## Corpus Layers

Keep these layers distinct:

- **Archive catalog:** every cloud/blob snapshot, used for provenance and
  coverage. It is not the default denominator for behavioral claims because
  rolling snapshots repeat the same session over time.
- **Latest-session mart:** the canonical conversation/transcript analysis layer.
  Use this for behavioral claims, tool-call rates, verification debt, session
  endings, rescue loops, and content findings.
- **Telemetry overlay mart:** OTLP/log/span data from Codex or related clients.
  Use this for latency, event-stream, tool-dispatch, and app/runtime questions.
  Keep raw sensitive telemetry attributes suppressed by default.
- **Unified Field Manual outputs:** public-safe claims, protocols, tools, and
  social drafts promoted to a private knowledge base after review.

## Promotion Checklist

Before marking research complete:

- Data date and corpus size are recorded.
- Query path or SQL text is preserved.
- Metrics are aggregate and public-safe.
- Caveats are included.
- The "so what" maps to a protocol or tool.
- Public content drafts do not expose private project names, file paths, raw
  prompts, secrets, or client data.
- Heavy data stays outside the public repo and outside git.
