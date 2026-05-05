-- ============================================================================
-- Model generation drift: Opus 4.5 vs 4.6 vs 4.7 head-to-head
-- ============================================================================
-- Compares behavioral metrics across three Opus generations on the same
-- corpus. Same-project filter at the bottom controls for workload drift.
--
-- Expected findings (one operator, ~389K Opus turns):
--   - tool error rate falls monotonically (7.23% → 5.74% → 3.92%)
--   - extended thinking usage regresses in 4.6 (29.2% → 7.2% → 24.2%)
--   - average output tokens grows ~17x from 4.5 to 4.7 (72 → 243 → 1,227)
-- ============================================================================


-- 1. Headline behavioral metrics across Claude models
SELECT
    model,
    count(*) AS turns,
    round(100.0 * sum(CASE WHEN tool_use_count > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_with_tools,
    round(avg(tool_use_count), 2) AS avg_tools_per_turn,
    round(avg(thinking_block_count), 3) AS avg_thinking_blocks,
    round(100.0 * sum(CASE WHEN thinking_block_count > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_using_thinking,
    round(avg(text_chars), 0) AS avg_text_chars,
    round(avg(output_tokens), 0) AS avg_output_tokens,
    round(100.0 * sum(CASE WHEN completion_claim THEN 1 ELSE 0 END) / count(*), 1) AS pct_completion_claim,
    round(100.0 * sum(CASE WHEN verification_claim THEN 1 ELSE 0 END) / count(*), 1) AS pct_verification_claim
FROM assistant_turns
WHERE model LIKE 'claude-%'
GROUP BY model
HAVING count(*) >= 1000
ORDER BY model;


-- 2. Tool error rate per Opus generation
SELECT
    a.model,
    count(*) AS calls,
    sum(CASE WHEN t.result_is_error THEN 1 ELSE 0 END) AS errors,
    round(100.0 * sum(CASE WHEN t.result_is_error THEN 1 ELSE 0 END) / count(*), 2) AS error_pct
FROM tool_events t
JOIN assistant_turns a USING (session_id, row_index_in_session)
WHERE a.model LIKE 'claude-opus%'
GROUP BY a.model
ORDER BY a.model;


-- 3. Bash error rate per Opus generation (the workhorse tool)
SELECT
    a.model,
    count(*) AS bash_calls,
    sum(CASE WHEN t.result_is_error THEN 1 ELSE 0 END) AS bash_errors,
    round(100.0 * sum(CASE WHEN t.result_is_error THEN 1 ELSE 0 END) / count(*), 2) AS bash_error_pct
FROM tool_events t
JOIN assistant_turns a USING (session_id, row_index_in_session)
WHERE a.model LIKE 'claude-opus%'
  AND t.tool_name = 'Bash'
GROUP BY a.model
ORDER BY a.model;


-- 4. Tool mix per Opus generation (top 10 tools by share)
WITH calls AS (
    SELECT cb.tool_name, a.model
    FROM content_blocks cb
    JOIN assistant_turns a USING (session_id, row_index_in_session)
    WHERE cb.block_type = 'tool_use'
      AND a.model LIKE 'claude-opus%'
),
totals AS (
    SELECT model, count(*) AS total FROM calls GROUP BY model
)
SELECT
    c.model,
    c.tool_name,
    count(*) AS calls,
    round(100.0 * count(*) / t.total, 1) AS pct
FROM calls c
JOIN totals t USING (model)
GROUP BY c.model, c.tool_name, t.total
QUALIFY row_number() OVER (PARTITION BY c.model ORDER BY count(*) DESC) <= 10
ORDER BY c.model, calls DESC;


-- 5. Same-project sanity check (workload-controlled).
-- Filter to the projects present across all three Opus generations to
-- isolate model effect from workload drift.
-- NOTE: edit the IN (...) list to match your own corpus's stable projects.
SELECT
    model,
    count(*) AS turns,
    round(avg(thinking_block_count), 3) AS avg_thinking_blocks,
    round(100.0 * sum(CASE WHEN thinking_block_count > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_thinking,
    round(avg(output_tokens), 0) AS avg_output_tokens,
    round(avg(tool_use_count), 2) AS avg_tools_per_turn
FROM assistant_turns
WHERE model LIKE 'claude-opus%'
  -- AND project IN ('your-project-1', 'your-project-2', ...)  -- uncomment to filter
GROUP BY model
ORDER BY model;
