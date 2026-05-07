---
name: agentic-coding-field-manual
description: Use when turning Claude Code or coding-agent corpus data into public Field Manual research, evidence-backed protocols, scripts, blog outlines, LinkedIn posts, X threads, or repo updates. Trigger when asked to update the corpus analysis, find non-obvious agentic-coding lessons, create the "so what", package findings into skills/tools, or coordinate with content pipeline and social publishing tool.
metadata:
  short-description: Turn agent logs into field-manual research and content
---

# Agentic Coding Field Manual

Use this skill to convert real coding-agent telemetry into public, repeatable
operating guidance. The output should feel like a performance lab, not a tips
list: evidence -> non-obvious finding -> concrete protocol -> public artifact.

## Operating Standard

Default to the freshest available data. If a local event mart or raw logs exist,
refresh or query them before writing. If refresh is expensive or blocked, say so
and mark stale metrics with the run date.

Never publish private paths, client names, secret values, raw prompts, tool
result text, or project-specific snippets unless the operator explicitly cleared
them. Public outputs should use aggregate metrics and sanitized examples.

Treat corpus findings as observational unless an A/B experiment was run. Prefer
phrasing like "in this corpus", "correlates with", and "the protocol to test is"
over causal overreach.

## Workflow

1. **Refresh / verify the data**
   - Inspect the repo for existing schema, analyses, and mart location.
   - If available, query the latest DuckDB event mart before drafting claims.
   - Record corpus size, data date, and any stale-data caveats.

2. **Run or create analyses**
   - Start from existing analyses, then add only analyses that sharpen the Field
     Manual thesis.
   - Prefer measurements that map to behavior: intervention timing, stuckness,
     verification, retry loops, tool transitions, cost/token concentration, and
     human rescue patterns.

3. **Extract the non-obvious angle**
   - A good angle contradicts default advice. Example: "more autonomy" is less
     useful than "shorter controlled sprints increase usable autonomy."
   - Reject generic advice like "write clear prompts" unless the corpus shows a
     concrete mechanism.

4. **Write the so-what**
   - Every finding must produce an action: a protocol, skill rule, script,
     checklist, or experiment.
   - The format is: Finding -> Interpretation -> Do This -> Test This.

5. **Package artifacts**
   - Add reusable SQL/scripts when the analysis should be rerun.
   - Add or update Codex skills when a protocol should be installed.
   - Create content briefs for blog, LinkedIn, and X only after the evidence and
     caveats are clear.
   - Persist completed research to private knowledge base using the Field Manual research brief
     template. Keep messy run logs in `.runs/` and public machinery in this repo.

6. **Coordinate with companion repos when present**
   - content pipeline: `<user-home>/dev/content-pipeline`
   - X instrumentation: `<user-home>/dev/social-publishing-tool`
   - Do not modify companion repos unless the user asks. Prepare handoff files
     or exact commands when useful.

## High-Value Analysis Families

Use `references/analysis_playbook.md` for query ideas, metrics, and expected
artifacts. Use `references/content_handoff.md` when turning a finding into blog,
LinkedIn, X, or content pipeline inputs.

## Output Shape

For a research/content request, return:

- the five highest-signal findings, ordered by public value
- one concrete protocol per finding
- the strongest contrarian or non-obvious line
- recommended artifact: SQL/script, skill, blog, LinkedIn carousel, X thread
- caveats that must survive publication

For repo changes, keep the commit surface small and public-safe. Do not add raw
corpus exports, labeled audit rows, or private project names.
