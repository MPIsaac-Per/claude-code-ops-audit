# Research Persistence

This repo separates reusable public machinery from private research outputs.

## Storage Tiers

### private knowledge base: Completed Research Source Of Truth

Completed Field Manual research belongs in private knowledge base:

```text
<user-home>/<private-cloud-storage>/<private-cloud-storage>/__Knowledge Base/private knowledge base/<private-knowledge-base>/private content/Research/claude-code-corpus/
```

Use a timestamped Markdown brief for every completed analysis:

```text
YYYYMMDDHHMMSS_Field_Manual_<Finding_Name>.md
```

Use the private knowledge base template:

```text
<private-knowledge-base>/private content/Research/claude-code-corpus/_templates/field_manual_research_brief.md
```

Small reproducibility bundles may live under:

```text
<private-knowledge-base>/private content/Research/claude-code-corpus/_data/YYYYMMDDHHMMSS_<slug>/
```

Allowed private knowledge base bundle files:

- `manifest.json`
- `queries.sql`
- `results_summary.csv`
- `chart_specs.json`
- `content_brief.md`
- `linkedin_post.md`
- `x_thread.md`

Do not put `.duckdb`, `.parquet`, raw `.jsonl`, heavy CSV extracts, labeled
audit rows, secrets, or private prompt/tool-result text in private knowledge base bundles.

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
metadata into private knowledge base.

## Promotion Checklist

Before marking research complete:

- Data date and corpus size are recorded.
- Query path or SQL text is preserved.
- Metrics are aggregate and public-safe.
- Caveats are included.
- The "so what" maps to a protocol or tool.
- Public content drafts do not expose private project names, file paths, raw
  prompts, secrets, or client data.
- Heavy data stays outside private knowledge base and outside git.
