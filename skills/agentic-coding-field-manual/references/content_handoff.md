# Content Handoff

Use this reference when turning Field Manual findings into public artifacts or
handoffs for content pipeline.

## Field Manual Claim Format

Use this structure for every public claim:

1. **Hook**: one memorable sentence.
2. **Evidence**: aggregate metric and corpus scope.
3. **Mechanism**: why the pattern likely happens.
4. **Protocol**: what to do differently.
5. **Experiment**: how readers can test it on their own logs.
6. **Caveat**: observational, single-operator, or audit-sample limitation.

Example:

```text
I measured the autonomy half-life of my coding agent. In nonzero runs, the
median human re-entry arrived after 5 tool calls. The lesson is not "trust the
agent more"; it is "run shorter controlled sprints with explicit stop gates."
```

## Blog Brief Template

Use `templates/blog_brief.md` for a full article outline. Keep the article
evidence-first and operational. A good article has one central thesis and 3-5
protocols, not a catalog of every query that was run.

## LinkedIn Packaging

LinkedIn should sound like a field note from a serious operator:

- first line names the concrete finding
- second line says why the common belief is wrong
- body uses short paragraphs and numbers
- end with a protocol readers can apply
- avoid overclaiming and empty thought-leadership language

Good formats:

- single post with one metric and one protocol
- document/carousel with Finding -> So What -> Protocol -> Try This
- teardown post showing a bad loop and the corrected loop

## X Packaging

X should use a sharper thread:

- post 1: contrarian claim plus metric
- posts 2-4: evidence and mechanism
- posts 5-7: protocol steps
- final post: repo link, reproducibility note, and caveat

Use `templates/x_thread.md` for thread shape.

## content pipeline Handoff

When `<user-home>/dev/content-pipeline` exists, prepare a handoff that
matches its content-factory model:

- suggested niche: `agentinfra-dev` unless the user names a different one
- proposed article slug
- canonical source URLs or local evidence files
- fact ledger candidates: metrics, dates, repo paths, query names
- internal-link targets if known
- publication caveats that `verify_facts.py` should preserve

Do not write into content pipeline unless asked. If asked, inspect the current
`niches/<slug>/` layout and add a queued backlog entry or source/fact handoff
using existing project conventions.

## social publishing tool Handoff

When `<user-home>/dev/social-publishing-tool` exists, prepare thread drafts as Markdown.
Only post through `social-publishing-tool` when the user explicitly asks.

Useful commands may include:

```bash
cd <user-home>/dev/social-publishing-tool
uv run social-publishing-tool thread /path/to/thread.md --post
uv run social-publishing-tool metrics
```

Verify the current CLI before relying on a command; the repo may still be under
active implementation.

## Persistence Boundary

Use three storage tiers:

- **private knowledge base**: completed research briefs, small reproducibility bundles, content
  drafts, public-safe aggregate results.
- **This repo**: reusable public machinery, SQL, skills, templates, docs, and
  sanitized examples.
- **`.runs/`**: gitignored working logs, raw stdout, temporary CSVs, scratch
  notes, and messy execution traces.

Completed private knowledge base research should use:

```text
<private-knowledge-base>/private content/Research/claude-code-corpus/_templates/field_manual_research_brief.md
```

Promote only cleaned artifacts. Do not promote `.duckdb`, `.parquet`, raw
`.jsonl`, heavy CSV extracts, labeled audit rows, secrets, raw prompt text, or
private tool-result previews.
