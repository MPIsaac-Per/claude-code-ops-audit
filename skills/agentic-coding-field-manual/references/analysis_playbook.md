# Analysis Playbook

Use this reference when selecting or designing analyses for the Agentic Coding
Field Manual.

## Core Metrics To Refresh

- corpus size: sessions, human messages, assistant turns, tool events, errors
- data date: max timestamp in the event mart or raw logs
- model/version distribution
- tool family mix and top transitions
- error distribution and repeated-failure patterns
- verification-candidate count and audited true-positive rate, if labels exist
- token concentration by error/session bucket when token columns exist

## Analysis Families

### Autonomy Half-Life

Question: how long does the agent run before the human re-enters?

Useful surfaces: `human_messages`, `tool_events`, `assistant_turns`,
`human_intervention_points`, `session_metrics`.

Output:

- median/p75/p90 tool calls between human messages
- separate zero-tool chatter from nonzero agent runs
- share of re-entry spans that followed at least one error

Protocol to test: 5-10 tool-call micro-sprints with explicit stop/report gates.

### Agent Loop Map

Question: what execution loop does the agent actually run?

Useful surfaces: `tool_family_transitions`, `tool_transitions`,
`bash_command_patterns`.

Output:

- top transitions by tool family
- share of transitions inside search/edit/shell
- same-family loop share
- loops that correlate with repeated failure

Protocol to test: locate -> inspect -> edit -> narrow verification -> repeat.

### Verification Debt

Question: when the agent says work is complete, what evidence exists?

Useful surfaces: `plausible_completion_candidates`, audit labels, 
`verification_sequences`, `assistant_turns`.

Output:

- raw candidate count
- audited TP/FP/AMB split
- estimated true verification-debt turns
- examples must be sanitized or paraphrased

Protocol to test: completion receipts. "Done" must include command/result,
impossibility reason, or "implemented but unverified."

### Cost Of Stuckness

Question: where do tokens and time concentrate?

Useful surfaces: `assistant_turns`, `session_metrics`, `error_events`,
`post_error_next_10`, `error_recovery_summary`.

Output:

- token share by error bucket
- token share by long-loop bucket
- repeated-failure rate after error type
- top costly failure modes

Protocol to test: after two consecutive failures, stop execution and classify
the failure before retrying.

### Human Rescue Patterns

Question: what human interventions change the agent's next move?

Useful surfaces: `human_intervention_points`, `tool_events`,
`post_error_next_10`.

Output:

- next tool family after human re-entry following an error
- immediate next-tool failure/success rates
- prompt size vs next-tool result
- planning vs shell retry comparison

Protocol to test: diagnosis-before-retry. Force hypotheses and cheapest tests
before the next command.

### Prompt Shape And Outcome

Question: which prompt shapes correlate with cleaner execution?

Useful surfaces: `human_messages`, `session_outcome_signals`, fpk scripts,
tool/error/session tables.

Output:

- prompt length buckets vs next tool result
- explicit verification instruction vs later verification events
- anger/friction proxy vs session error/token buckets
- plan-first prompts vs execution-first prompts

Protocol to test: prompts that define loop shape and stop conditions, not just
desired final output.

## Publication Test

Before packaging an insight, ask:

- Is this more specific than "prompt better"?
- Does it tell a serious operator what to do differently tomorrow?
- Could another user measure it on their own logs?
- Are the caveats short enough to preserve the hook without weakening rigor?
- Is the artifact reusable: query, script, skill, checklist, or experiment?
