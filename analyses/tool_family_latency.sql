-- ============================================================================
-- Per-tool-family latency (Experiment 3)
-- ============================================================================
-- The entire.io / pgr post claims tool execution is 0.4% of end-to-end wall
-- clock. Our Codex telemetry mart already shows tool_dispatch p50 of 11.6ms
-- vs. model_stream_request p50 of 3,601ms — a 310× ratio.
--
-- This analysis estimates per-tool wall-clock latency from the Claude Code
-- conversation JSONL itself, by diffing successive timestamps:
--   tool_use   → assistant message timestamp
--   tool_result → user message timestamp (the message containing the result)
-- The diff approximates tool execution + I/O round-trip on the local CLI.
--
-- We also estimate model inference time per turn:
--   user_message[N].timestamp → assistant_turn[N+1].timestamp
-- This isolates how long Claude Code waited for the next assistant response
-- after sending tool results.
-- ============================================================================


-- 0. Tool result coverage check.
SELECT
    count(*) AS tool_events_total,
    sum(CASE WHEN result_row_index_in_session IS NOT NULL THEN 1 ELSE 0 END) AS with_result_row,
    round(100.0 * sum(CASE WHEN result_row_index_in_session IS NOT NULL THEN 1 ELSE 0 END) / count(*), 1) AS pct_with_result_row
FROM tool_events;


-- 1. Per-tool-family latency candidates, joining tool_events back to jsonl_rows
-- for the result timestamp. JSONL row timestamps can be equal, reversed, or
-- separated by long suspended-session gaps; keep those coverage facts visible
-- before reporting any filtered latency distribution.
CREATE OR REPLACE TEMP TABLE tool_latency_candidates AS
SELECT
    te.session_id,
    te.tool_family,
    te.tool_name,
    te.command_verb,
    (
        te.tool_family = 'file_read'
        OR te.tool_name IN ('Read', 'NotebookRead')
    ) AS is_file_retrieval,
    (
        te.tool_family = 'file_search'
        OR te.tool_name IN ('Grep', 'Glob')
    ) AS is_content_search,
    (
        te.tool_family = 'file_write'
        OR te.tool_name IN ('Edit', 'MultiEdit', 'Write', 'NotebookEdit')
    ) AS is_file_mutation,
    te."timestamp" AS tool_use_ts,
    jr."timestamp" AS tool_result_ts,
    epoch_ms(jr."timestamp" - te."timestamp") AS latency_ms,
    te.result_is_error,
    te.result_chars,
    CASE
        WHEN te."timestamp" IS NULL OR jr."timestamp" IS NULL THEN 'missing_timestamp'
        WHEN jr."timestamp" <= te."timestamp" THEN 'non_positive_delta'
        WHEN epoch_ms(jr."timestamp" - te."timestamp") >= 600000 THEN 'positive_over_10m'
        ELSE 'kept_positive_under_10m'
    END AS latency_filter_status
FROM tool_events te
JOIN jsonl_rows jr
  ON jr.session_id = te.session_id
 AND jr.row_index_in_session = te.result_row_index_in_session
WHERE te.result_row_index_in_session IS NOT NULL;


SELECT
    latency_filter_status,
    count(*) AS events,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_joined_tool_results
FROM tool_latency_candidates
GROUP BY latency_filter_status
ORDER BY events DESC;


CREATE OR REPLACE TEMP TABLE tool_latency AS
SELECT *
FROM tool_latency_candidates
WHERE latency_filter_status = 'kept_positive_under_10m'
  AND latency_ms IS NOT NULL;


-- 2. Per-family latency distribution over kept positive deltas under 10 min.
SELECT
    tool_family,
    count(*) AS events,
    round(100.0 * count(*) / (SELECT count(*) FROM tool_latency_candidates), 2) AS pct_of_all_joined_tool_results,
    round(avg(latency_ms), 1) AS avg_ms,
    round(quantile_cont(latency_ms, 0.50), 1) AS p50_ms,
    round(quantile_cont(latency_ms, 0.90), 1) AS p90_ms,
    round(quantile_cont(latency_ms, 0.95), 1) AS p95_ms,
    round(quantile_cont(latency_ms, 0.99), 1) AS p99_ms,
    max(latency_ms) AS max_ms
FROM tool_latency
GROUP BY tool_family
ORDER BY events DESC;


-- 3. Search-only latency (apples-to-apples vs. entire.io) over kept positive
-- deltas under 10 min.
-- file_read + file_search + bash search verbs.
SELECT
    CASE
        WHEN is_file_retrieval THEN 'file_retrieval'
        WHEN is_content_search THEN 'grep_glob'
        WHEN is_file_mutation THEN 'file_mutation'
        WHEN tool_family = 'shell' AND command_verb IN ('rg','grep','find','fd','ag','ack','locate')
            THEN 'bash_search'
        WHEN tool_family = 'shell' THEN 'bash_other'
        ELSE 'other'
    END AS bucket,
    count(*) AS events,
    round(100.0 * count(*) / (SELECT count(*) FROM tool_latency_candidates), 2) AS pct_of_all_joined_tool_results,
    round(avg(latency_ms), 1) AS avg_ms,
    round(quantile_cont(latency_ms, 0.50), 1) AS p50_ms,
    round(quantile_cont(latency_ms, 0.95), 1) AS p95_ms
FROM tool_latency
GROUP BY bucket
ORDER BY events DESC;


-- 4. Model-inference time per turn.
-- For each user message that contains tool_results, find the next
-- assistant turn and diff timestamps. This is approximately the time
-- Claude Code spent waiting for the model to respond after handing back
-- tool results.
CREATE OR REPLACE TEMP TABLE turn_latency_candidates AS
WITH ordered AS (
    SELECT
        session_id,
        row_index_in_session,
        row_type,
        "timestamp" AS ts,
        lead(row_type) OVER (PARTITION BY session_id ORDER BY row_index_in_session) AS next_row_type,
        lead("timestamp") OVER (PARTITION BY session_id ORDER BY row_index_in_session) AS next_ts
    FROM jsonl_rows
)
SELECT
    session_id,
    row_index_in_session,
    epoch_ms(next_ts - ts) AS inference_ms,
    CASE
        WHEN next_ts IS NULL THEN 'no_next_row'
        WHEN next_row_type <> 'assistant' THEN 'next_row_not_assistant'
        WHEN next_ts <= ts THEN 'non_positive_delta'
        WHEN epoch_ms(next_ts - ts) >= 600000 THEN 'positive_over_10m'
        ELSE 'kept_positive_under_10m'
    END AS latency_filter_status
FROM ordered
WHERE row_type = 'user';


SELECT
    latency_filter_status,
    count(*) AS user_turns,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_user_turns
FROM turn_latency_candidates
GROUP BY latency_filter_status
ORDER BY user_turns DESC;


CREATE OR REPLACE TEMP TABLE turn_latency AS
SELECT *
FROM turn_latency_candidates
WHERE latency_filter_status = 'kept_positive_under_10m';


SELECT
    'model_inference_per_turn' AS metric,
    count(*) AS turns,
    round(avg(inference_ms), 1) AS avg_ms,
    round(quantile_cont(inference_ms, 0.50), 1) AS p50_ms,
    round(quantile_cont(inference_ms, 0.90), 1) AS p90_ms,
    round(quantile_cont(inference_ms, 0.95), 1) AS p95_ms,
    round(quantile_cont(inference_ms, 0.99), 1) AS p99_ms
FROM turn_latency;


-- 5. Filtered ratio: model inference (median) vs kept tool-result deltas.
-- This is whole-system JSONL wall time, not in-process tool execution. Treat it
-- as a permission/suspension-sensitive upper-bound view of tool latency.
WITH t AS (
    SELECT round(quantile_cont(latency_ms, 0.50), 1) AS p50_tool_ms
    FROM tool_latency
), m AS (
    SELECT round(quantile_cont(inference_ms, 0.50), 1) AS p50_inference_ms
    FROM turn_latency
)
SELECT
    t.p50_tool_ms,
    m.p50_inference_ms,
    round(m.p50_inference_ms / NULLIF(t.p50_tool_ms, 0), 1) AS inference_to_tool_ratio_p50
FROM t, m;


-- 6. Same filtered ratio at p95 — captures tail behavior.
WITH t AS (
    SELECT round(quantile_cont(latency_ms, 0.95), 1) AS p95_tool_ms
    FROM tool_latency
), m AS (
    SELECT round(quantile_cont(inference_ms, 0.95), 1) AS p95_inference_ms
    FROM turn_latency
)
SELECT
    t.p95_tool_ms,
    m.p95_inference_ms,
    round(m.p95_inference_ms / NULLIF(t.p95_tool_ms, 0), 1) AS inference_to_tool_ratio_p95
FROM t, m;


-- 7. Wall-clock share — fraction of session time captured by kept positive
-- tool-result deltas and kept positive user→assistant deltas. This is not pure
-- tool execution vs pure model inference; it is a filtered whole-system
-- timestamp-diff estimate.
WITH session_time AS (
    SELECT
        session_id,
        epoch_ms(max("timestamp") - min("timestamp")) AS session_wall_ms
    FROM jsonl_rows
    GROUP BY session_id
    HAVING count(*) > 5
),
tool_time AS (
    SELECT session_id, sum(latency_ms) AS tool_ms
    FROM tool_latency
    GROUP BY session_id
),
inference_time AS (
    SELECT
        session_id,
        sum(epoch_ms(next_ts - ts)) AS inference_ms
    FROM (
        SELECT
            session_id,
            "timestamp" AS ts,
            lead("timestamp") OVER (PARTITION BY session_id ORDER BY row_index_in_session) AS next_ts,
            row_type,
            lead(row_type) OVER (PARTITION BY session_id ORDER BY row_index_in_session) AS next_row_type
        FROM jsonl_rows
    )
    WHERE row_type = 'user'
      AND next_row_type = 'assistant'
      AND next_ts > ts
      AND epoch_ms(next_ts - ts) < 600000
    GROUP BY session_id
)
SELECT
    count(*) AS sessions,
    round(sum(s.session_wall_ms) / 1000.0 / 60.0, 1) AS total_wall_minutes,
    round(sum(coalesce(t.tool_ms, 0)) / 1000.0 / 60.0, 1) AS kept_tool_delta_minutes,
    round(sum(coalesce(i.inference_ms, 0)) / 1000.0 / 60.0, 1) AS kept_user_to_assistant_delta_minutes,
    round(100.0 * sum(coalesce(t.tool_ms, 0)) / NULLIF(sum(s.session_wall_ms), 0), 2) AS pct_wall_in_kept_tool_deltas,
    round(100.0 * sum(coalesce(i.inference_ms, 0)) / NULLIF(sum(s.session_wall_ms), 0), 2) AS pct_wall_in_kept_user_to_assistant_deltas,
    round(sum(coalesce(i.inference_ms, 0))::DOUBLE / NULLIF(sum(coalesce(t.tool_ms, 0)), 0), 2) AS kept_user_to_assistant_to_tool_delta_ratio
FROM session_time s
LEFT JOIN tool_time t USING (session_id)
LEFT JOIN inference_time i USING (session_id);
