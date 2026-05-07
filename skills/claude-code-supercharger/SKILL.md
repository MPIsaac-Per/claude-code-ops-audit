---
name: claude-code-supercharger
description: Use when actively coding with Claude Code or another coding agent and the user wants higher efficacy, less thrash, stronger verification, shorter agent loops, or top-tier agentic-coding operating discipline. Applies the Field Manual protocols: micro-sprints, loop shaping, verification receipts, diagnosis-before-retry, stuckness interrupts, and human rescue.
metadata:
  short-description: Evidence-backed Claude Code operating protocols
---

# Claude Code Supercharger

Use this skill while doing real coding work with Claude Code. The goal is to
shape the agent's execution loop, not merely improve wording.

## Core Rule

Work in controlled loops:

```text
locate -> inspect -> edit -> narrow verification -> report receipts -> repeat
```

Avoid long unattended execution unless the user explicitly asks for it. If the
task is large, split it into 5-10 tool-call micro-sprints and stop at each gate
with evidence.

## Protocols

### 1. Micro-Sprint Protocol

Use when the task can drift or has unknowns.

Instruction to follow:

```text
Run a 5-10 tool-call sprint. Then stop and report:
1. what changed
2. what evidence was collected
3. what remains uncertain
4. the next smallest useful action
```

### 2. Loop Shaping

Before editing, locate and inspect the relevant implementation and call sites.
After editing, run the narrowest meaningful verification before broad checks.

Do not broaden scope until either:

- the narrow verification passes
- the current hypothesis fails
- the user asks to expand

### 3. Verification Receipts

Never say work is done unless the response includes one of:

- exact command/check run and result
- exact reason verification was impossible
- explicit label: `implemented but unverified`

For code changes, final answers should distinguish implementation from
verification.

### 4. Diagnosis Before Retry

If two consecutive tool calls fail, stop execution and classify the failure:

- auth / permission
- missing file or path drift
- command misuse
- dependency/environment
- test failure
- product logic failure
- external service/network

Then name the cheapest disambiguating check and run only that.

### 5. Stuckness Interrupt

Watch for repeated failures, repeated searches, repeated edits to the same
file, or broad commands after narrow failures. When detected, switch from doing
mode to diagnosis mode.

Use this prompt internally:

```text
I may be thrashing. I will stop and state:
1. the current hypothesis
2. evidence for it
3. evidence against it
4. the smallest next check
```

### 6. Human Rescue

When the user intervenes after an error, treat the intervention as a mode
change, not just another instruction. Re-read the user's latest message,
summarize the new constraint, and avoid repeating the failed action unchanged.

## Final Answer Discipline

For completed coding work, include:

- what changed
- where it changed
- verification command/result
- any residual risk or unverified area

Keep it concise. The point is operational confidence, not ceremony.
