-- ============================================================================
-- First-Read efficiency (Experiment 2)
-- ============================================================================
-- The entire.io / pgr post argues that better first-look quality (definition-
-- first ranking, path-aware filtering) lifts MRR 0.32 → 0.41 and Hit@1
-- 26% → 34%. The downstream claim is that better first results should
-- reduce wandering, hence fewer total tool calls and fewer errors per task.
--
-- This analysis tests whether sessions that take FEWER pre-edit Reads
-- correlate with FEWER downstream errors and FEWER total tool calls.
--
-- Restricted to sessions with at least one file_write (Edit/Write) — sessions
-- without an edit are pure exploration and don't have a "first edit" anchor.
-- ============================================================================


-- 1. Coverage check: sessions with at least one edit.
WITH edit_sessions AS (
    SELECT DISTINCT session_id
    FROM tool_events
    WHERE tool_family = 'file_write'
       OR tool_name IN ('Edit', 'MultiEdit', 'Write', 'NotebookEdit')
)
SELECT
    (SELECT count(*) FROM edit_sessions) AS sessions_with_edits,
    (SELECT count(DISTINCT session_id) FROM tool_events) AS all_tool_sessions,
    round(100.0 * (SELECT count(*) FROM edit_sessions)
                 / NULLIF((SELECT count(DISTINCT session_id) FROM tool_events), 0), 1) AS pct_edit_sessions;


-- 2. Per-session pre-edit / post-edit metrics.
CREATE OR REPLACE TEMP TABLE first_edit_metrics AS
WITH first_edit AS (
    SELECT
        session_id,
        min(event_index) AS first_edit_index
    FROM tool_events
    WHERE tool_family = 'file_write'
       OR tool_name IN ('Edit', 'MultiEdit', 'Write', 'NotebookEdit')
    GROUP BY session_id
),
tool_events_classified AS (
    SELECT
        *,
        (
            tool_family = 'file_read'
            OR tool_name IN ('Read', 'NotebookRead')
        ) AS is_file_retrieval,
        (
            tool_family = 'file_search'
            OR tool_name IN ('Grep', 'Glob')
        ) AS is_file_search,
        (
            tool_family = 'file_write'
            OR tool_name IN ('Edit', 'MultiEdit', 'Write', 'NotebookEdit')
        ) AS is_file_mutation,
        coalesce(result_is_error, FALSE) AS result_explicit_error,
        coalesce(result_keyword_error, FALSE)
        OR coalesce(result_keyword_auth, FALSE)
        OR coalesce(result_keyword_not_found, FALSE)
        OR coalesce(result_keyword_timeout, FALSE) AS result_keyword_signal
    FROM tool_events
),
per_session AS (
    SELECT
        fe.session_id,
        fe.first_edit_index,
        sum(CASE WHEN te.is_file_retrieval AND te.event_index < fe.first_edit_index THEN 1 ELSE 0 END) AS pre_edit_reads,
        sum(CASE WHEN te.is_file_search AND te.event_index < fe.first_edit_index THEN 1 ELSE 0 END) AS pre_edit_searches,
        sum(CASE WHEN te.tool_family = 'shell' AND te.event_index < fe.first_edit_index THEN 1 ELSE 0 END) AS pre_edit_shells,
        sum(CASE WHEN te.event_index < fe.first_edit_index THEN 1 ELSE 0 END) AS pre_edit_total_tools,
        sum(CASE WHEN te.event_index >= fe.first_edit_index
                  AND te.result_explicit_error THEN 1 ELSE 0 END) AS post_edit_errors,
        sum(CASE WHEN te.event_index >= fe.first_edit_index
                  AND te.result_keyword_signal THEN 1 ELSE 0 END) AS post_edit_keyword_signals,
        count(*) AS total_tools,
        sum(CASE WHEN te.is_file_mutation THEN 1 ELSE 0 END) AS total_edits,
        sum(CASE WHEN te.result_explicit_error THEN 1 ELSE 0 END) AS total_errors,
        sum(CASE WHEN te.result_keyword_signal THEN 1 ELSE 0 END) AS total_keyword_signals
    FROM first_edit fe
    JOIN tool_events_classified te USING (session_id)
    GROUP BY fe.session_id, fe.first_edit_index
)
SELECT * FROM per_session;


-- 3. Bucket sessions by pre-edit read count and report downstream metrics.
SELECT
    CASE
        WHEN pre_edit_reads = 0 THEN '0_reads_before_edit'
        WHEN pre_edit_reads BETWEEN 1 AND 2 THEN '1_2_reads'
        WHEN pre_edit_reads BETWEEN 3 AND 5 THEN '3_5_reads'
        WHEN pre_edit_reads BETWEEN 6 AND 10 THEN '6_10_reads'
        WHEN pre_edit_reads BETWEEN 11 AND 20 THEN '11_20_reads'
        ELSE '21plus_reads'
    END AS pre_edit_read_bucket,
    count(*) AS sessions,
    round(avg(pre_edit_reads), 2) AS avg_pre_edit_reads,
    round(avg(pre_edit_searches), 2) AS avg_pre_edit_searches,
    round(avg(pre_edit_shells), 2) AS avg_pre_edit_shells,
    round(avg(pre_edit_total_tools), 2) AS avg_pre_edit_tools,
    round(avg(post_edit_errors), 2) AS avg_post_edit_errors,
    round(avg(post_edit_keyword_signals), 2) AS avg_post_edit_keyword_signals,
    round(avg(total_tools), 2) AS avg_total_tools,
    round(avg(total_errors), 2) AS avg_total_errors,
    round(avg(total_keyword_signals), 2) AS avg_total_keyword_signals,
    round(100.0 * avg(total_errors) / NULLIF(avg(total_tools), 0), 2) AS pct_explicit_error_rate,
    round(avg(total_edits), 2) AS avg_total_edits
FROM first_edit_metrics
GROUP BY pre_edit_read_bucket
ORDER BY MIN(pre_edit_reads);


-- 4. Same bucketing but for pre_edit_searches (Grep/Glob, not Read).
SELECT
    CASE
        WHEN pre_edit_searches = 0 THEN '0_searches_before_edit'
        WHEN pre_edit_searches BETWEEN 1 AND 2 THEN '1_2_searches'
        WHEN pre_edit_searches BETWEEN 3 AND 5 THEN '3_5_searches'
        WHEN pre_edit_searches >= 6 THEN '6plus_searches'
    END AS pre_edit_search_bucket,
    count(*) AS sessions,
    round(avg(pre_edit_searches), 2) AS avg_pre_edit_searches,
    round(avg(post_edit_errors), 2) AS avg_post_edit_errors,
    round(avg(post_edit_keyword_signals), 2) AS avg_post_edit_keyword_signals,
    round(avg(total_tools), 2) AS avg_total_tools,
    round(100.0 * avg(total_errors) / NULLIF(avg(total_tools), 0), 2) AS pct_explicit_error_rate
FROM first_edit_metrics
GROUP BY pre_edit_search_bucket
ORDER BY MIN(pre_edit_searches);


-- 5. Correlation: does pre-edit-read count predict total tool count?
-- A high positive correlation suggests that more wandering up front means
-- more wandering overall (consistent with the entire.io "first results
-- matter" thesis). A low correlation suggests they're decoupled.
SELECT
    round(corr(pre_edit_reads, total_tools), 3) AS corr_pre_reads_total_tools,
    round(corr(pre_edit_reads, total_errors), 3) AS corr_pre_reads_total_errors,
    round(corr(pre_edit_reads, post_edit_errors), 3) AS corr_pre_reads_post_errors,
    round(corr(pre_edit_searches, total_tools), 3) AS corr_pre_searches_total_tools,
    round(corr(pre_edit_total_tools, total_tools), 3) AS corr_pre_total_total_tools
FROM first_edit_metrics
WHERE total_tools > 0;


-- 6. Top-line summary: median, p75, p90 of pre-edit reads across all sessions.
SELECT
    count(*) AS sessions,
    round(avg(pre_edit_reads), 2) AS avg_pre_edit_reads,
    median(pre_edit_reads) AS median_pre_edit_reads,
    quantile_cont(pre_edit_reads, 0.75) AS p75_pre_edit_reads,
    quantile_cont(pre_edit_reads, 0.90) AS p90_pre_edit_reads,
    quantile_cont(pre_edit_reads, 0.95) AS p95_pre_edit_reads,
    max(pre_edit_reads) AS max_pre_edit_reads,
    round(avg(pre_edit_searches), 2) AS avg_pre_edit_searches,
    median(pre_edit_searches) AS median_pre_edit_searches
FROM first_edit_metrics;
