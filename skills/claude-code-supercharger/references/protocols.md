# Protocol Reference

These protocols came from observational analysis of a Claude Code operating
corpus. Treat them as practices to test, not universal laws.

## Micro-Sprints

Use short agent runs with explicit evidence gates. This reduces drift and makes
human steering cheaper.

## Loop Shaping

Force the agent into the engineering loop it already uses most:

```text
search -> inspect -> edit -> shell verification
```

## Verification Receipts

Completion claims need attached evidence. A useful receipt is a command/result,
a passed check, a visible artifact, or an explicit reason verification could
not be performed.

## Diagnosis Before Retry

Repeated failure is where token burn compounds. Two failed tool calls should
trigger classification and a single disambiguating test, not another broad
retry.

## Human Rescue

Human interventions work best when they change the agent's mode: from execution
to diagnosis, from broad search to narrow check, or from completion to evidence.
