# Content Handoff

Use this reference when turning Field Manual findings into public artifacts or
handoffs for a content pipeline.

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
This corpus shows an autonomy half-life. In nonzero runs, the median human
re-entry arrived after 5 tool calls. The lesson is not "trust the agent more";
it is "run shorter controlled sprints with explicit stop gates."
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

## Content Pipeline Handoff

When a companion content repository exists, prepare a handoff that matches its
current layout and publishing model:

- suggested niche or category, if the target repo uses one
- proposed article slug
- canonical source URLs or local evidence files
- fact ledger candidates: metrics, dates, repo paths, query names
- internal-link targets if known
- publication caveats that `verify_facts.py` should preserve

Do not write into a companion content repo unless asked. If asked, inspect the
current layout and add a queued backlog entry or source/fact handoff using
existing project conventions.

## Social Handoff

Prepare thread drafts as Markdown. Only post through a social publishing tool
when the user explicitly asks.

Example command shape, to be adapted to the target repo:

```bash
cd <social-publishing-repo>
<publisher-command> thread /path/to/thread.md --post
<publisher-command> metrics
```

Verify the current CLI before relying on a command; the repo may still be under
active implementation.

## Persistence Boundary

Use three storage tiers:

- **Private knowledge base**: completed research briefs, small reproducibility
  bundles, content drafts, public-safe aggregate results.
- **This repo**: reusable public machinery, SQL, skills, templates, docs, and
  sanitized examples.
- **`.runs/`**: gitignored working logs, raw stdout, temporary CSVs, scratch
  notes, and messy execution traces.

Completed private research should use a local research-brief template, for
example:

```text
<private-knowledge-base>/agentic-coding-research/_templates/research_brief.md
```

Promote only cleaned artifacts. Do not promote `.duckdb`, `.parquet`, raw
`.jsonl`, heavy CSV extracts, labeled audit rows, secrets, raw prompt text, or
private tool-result previews.
