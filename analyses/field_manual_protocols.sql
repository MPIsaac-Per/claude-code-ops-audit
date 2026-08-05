-- ============================================================================
-- Field Manual protocols: analyses that convert agent telemetry into operator
-- guidance.
-- ============================================================================
-- These queries support the public "Agentic Coding Field Manual" angle:
-- evidence -> non-obvious finding -> concrete protocol.
--
-- Run:
--   duckdb ~/data/claude_code.duckdb < analyses/field_manual_protocols.sql
--
-- Required tables/views:
--   assistant_turns, human_messages, tool_events, session_metrics,
--   tool_family_transitions, plausible_completion_candidates,
--   human_intervention_points
-- ============================================================================


-- 0. Corpus basis for every public claim.
WITH explicit_errors_by_session AS (
    SELECT
        session_id,
        sum(CASE WHEN coalesce(result_is_error, FALSE) THEN 1 ELSE 0 END) AS explicit_failures
    FROM tool_events
    GROUP BY session_id
)
SELECT
    count(*) AS sessions,
    sum(tool_events) AS tool_events,
    sum(coalesce(explicit_failures, 0)) AS explicit_error_events,
    sum(human_messages) AS human_messages,
    sum(assistant_turns) AS assistant_turns,
    min(first_timestamp) AS first_timestamp,
    max(last_timestamp) AS last_timestamp
FROM session_metrics
LEFT JOIN explicit_errors_by_session USING (session_id);


-- 1. Autonomy half-life.
-- How many tool calls happen before the human re-enters?
WITH spans AS (
    SELECT
        h.session_id,
        h.human_index_in_session,
        (
            SELECT count(*)
            FROM tool_events t
            WHERE t.session_id = h.session_id
              AND t.row_index_in_session > prev.row_index_in_session
              AND t.row_index_in_session < h.row_index_in_session
        ) AS tools_since_prior_human,
        (
            SELECT count(*)
            FROM tool_events t
            WHERE t.session_id = h.session_id
              AND t.row_index_in_session > prev.row_index_in_session
              AND t.row_index_in_session < h.row_index_in_session
              AND coalesce(t.result_is_error, FALSE)
        ) AS errors_since_prior_human
    FROM human_messages h
    JOIN human_messages prev
      ON prev.session_id = h.session_id
     AND prev.human_index_in_session = h.human_index_in_session - 1
    WHERE h.human_index_in_session > 0
)
SELECT
    'all_reentries' AS span_set,
    count(*) AS spans,
    round(avg(tools_since_prior_human), 2) AS avg_tools,
    median(tools_since_prior_human) AS median_tools,
    quantile_cont(tools_since_prior_human, 0.75) AS p75_tools,
    quantile_cont(tools_since_prior_human, 0.90) AS p90_tools,
    quantile_cont(tools_since_prior_human, 0.95) AS p95_tools,
    round(100.0 * sum(CASE WHEN tools_since_prior_human = 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_zero_tool,
    round(100.0 * sum(CASE WHEN errors_since_prior_human > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_after_error
FROM spans
UNION ALL
SELECT
    'nonzero_agent_runs' AS span_set,
    count(*) AS spans,
    round(avg(tools_since_prior_human), 2) AS avg_tools,
    median(tools_since_prior_human) AS median_tools,
    quantile_cont(tools_since_prior_human, 0.75) AS p75_tools,
    quantile_cont(tools_since_prior_human, 0.90) AS p90_tools,
    quantile_cont(tools_since_prior_human, 0.95) AS p95_tools,
    round(100.0 * sum(CASE WHEN tools_since_prior_human = 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_zero_tool,
    round(100.0 * sum(CASE WHEN errors_since_prior_human > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_after_error
FROM spans
WHERE tools_since_prior_human > 0;


-- 2. Agent loop map.
-- How much of the work lives in the search/edit/shell core?
WITH trans AS (
    SELECT tool_family, next_tool_family, transitions
    FROM tool_family_transitions
),
totals AS (
    SELECT sum(transitions) AS total_transitions FROM trans
)
SELECT
    'same_family' AS pattern,
    sum(CASE WHEN tool_family = next_tool_family THEN transitions ELSE 0 END) AS transitions,
    round(100.0 * sum(CASE WHEN tool_family = next_tool_family THEN transitions ELSE 0 END) / max(total_transitions), 1) AS pct
FROM trans, totals
UNION ALL
SELECT
    'search_edit_shell_core' AS pattern,
    sum(CASE WHEN tool_family IN ('file_search', 'file_read', 'file_write', 'shell')
              AND next_tool_family IN ('file_search', 'file_read', 'file_write', 'shell')
             THEN transitions ELSE 0 END) AS transitions,
    round(100.0 * sum(CASE WHEN tool_family IN ('file_search', 'file_read', 'file_write', 'shell')
                            AND next_tool_family IN ('file_search', 'file_read', 'file_write', 'shell')
                           THEN transitions ELSE 0 END) / max(total_transitions), 1) AS pct
FROM trans, totals
UNION ALL
SELECT
    'shell_edit_back_and_forth' AS pattern,
    sum(CASE WHEN (tool_family = 'shell' AND next_tool_family IN ('file_read', 'file_write'))
               OR (tool_family IN ('file_read', 'file_write') AND next_tool_family = 'shell')
             THEN transitions ELSE 0 END) AS transitions,
    round(100.0 * sum(CASE WHEN (tool_family = 'shell' AND next_tool_family IN ('file_read', 'file_write'))
                              OR (tool_family IN ('file_read', 'file_write') AND next_tool_family = 'shell')
                           THEN transitions ELSE 0 END) / max(total_transitions), 1) AS pct
FROM trans, totals;


-- 3. Top transitions for Sankey / carousel visuals.
SELECT
    tool_family,
    next_tool_family,
    transitions,
    sessions,
    round(100.0 * transitions / sum(transitions) OVER (), 2) AS pct_of_transitions
FROM tool_family_transitions
ORDER BY transitions DESC
LIMIT 20;


-- 4. Verification debt candidate surface.
-- Raw candidates are not final truth. Use audit/classify.py for sampled labels.
SELECT
    count(*) AS assistant_turns,
    sum(CASE WHEN completion_claim THEN 1 ELSE 0 END) AS completion_claim_turns,
    sum(CASE WHEN completion_claim AND verification_claim THEN 1 ELSE 0 END) AS completion_with_same_turn_verification,
    (SELECT count(*) FROM plausible_completion_candidates) AS plausible_completion_candidates,
    round(100.0 * (SELECT count(*) FROM plausible_completion_candidates) / NULLIF(count(*), 0), 2) AS pct_all_turns_flagged,
    round(100.0 * (SELECT count(*) FROM plausible_completion_candidates) / NULLIF(sum(CASE WHEN completion_claim THEN 1 ELSE 0 END), 0), 1) AS pct_completion_claims_flagged
FROM assistant_turns;


-- 5. Cost of stuckness.
-- How much token volume concentrates in sessions with many errors?
WITH token_by_session AS (
    SELECT
        session_id,
        sum(coalesce(input_tokens, 0)) AS fresh_input,
        sum(coalesce(cache_read_input_tokens, 0)) AS cache_read,
        sum(coalesce(cache_creation_input_tokens, 0)) AS cache_creation,
        sum(coalesce(output_tokens, 0)) AS output_tokens,
        sum(
            coalesce(input_tokens, 0)
          + coalesce(cache_read_input_tokens, 0)
          + coalesce(cache_creation_input_tokens, 0)
          + coalesce(output_tokens, 0)
        ) AS total_tokens
    FROM assistant_turns
    GROUP BY session_id
),
explicit_errors_by_session AS (
    SELECT
        session_id,
        sum(CASE WHEN coalesce(result_is_error, FALSE) THEN 1 ELSE 0 END) AS explicit_error_events
    FROM tool_events
    GROUP BY session_id
),
labeled AS (
    SELECT
        sm.session_id,
        CASE
            WHEN coalesce(ee.explicit_error_events, 0) = 0 THEN 'no_error_sessions'
            WHEN coalesce(ee.explicit_error_events, 0) BETWEEN 1 AND 2 THEN '1_2_errors'
            WHEN coalesce(ee.explicit_error_events, 0) BETWEEN 3 AND 9 THEN '3_9_errors'
            ELSE '10plus_errors'
        END AS error_bucket,
        coalesce(ee.explicit_error_events, 0) AS error_events,
        sm.tool_events,
        sm.human_messages,
        coalesce(tb.total_tokens, 0) AS total_tokens,
        coalesce(tb.cache_read, 0) AS cache_read,
        coalesce(tb.output_tokens, 0) AS output_tokens
    FROM session_metrics sm
    LEFT JOIN token_by_session tb USING (session_id)
    LEFT JOIN explicit_errors_by_session ee USING (session_id)
)
SELECT
    error_bucket,
    count(*) AS sessions,
    round(avg(error_events), 1) AS avg_errors,
    round(avg(tool_events), 1) AS avg_tool_events,
    round(avg(human_messages), 1) AS avg_human_messages,
    round(avg(total_tokens), 0) AS avg_total_tokens,
    round(avg(cache_read), 0) AS avg_cache_read_tokens,
    round(avg(output_tokens), 0) AS avg_output_tokens
FROM labeled
GROUP BY error_bucket
ORDER BY min(error_events);


-- 6. Token concentration in high-error sessions.
WITH token_by_session AS (
    SELECT
        session_id,
        sum(
            coalesce(input_tokens, 0)
          + coalesce(cache_read_input_tokens, 0)
          + coalesce(cache_creation_input_tokens, 0)
          + coalesce(output_tokens, 0)
        ) AS total_tokens
    FROM assistant_turns
    GROUP BY session_id
),
explicit_errors_by_session AS (
    SELECT
        session_id,
        sum(CASE WHEN coalesce(result_is_error, FALSE) THEN 1 ELSE 0 END) AS explicit_error_events
    FROM tool_events
    GROUP BY session_id
),
labeled AS (
    SELECT
        sm.session_id,
        coalesce(ee.explicit_error_events, 0) AS error_events,
        coalesce(tb.total_tokens, 0) AS total_tokens
    FROM session_metrics sm
    LEFT JOIN token_by_session tb USING (session_id)
    LEFT JOIN explicit_errors_by_session ee USING (session_id)
)
SELECT
    round(100.0 * sum(CASE WHEN error_events >= 10 THEN 1 ELSE 0 END) / count(*), 1) AS pct_sessions_10plus_errors,
    round(100.0 * sum(CASE WHEN error_events >= 10 THEN total_tokens ELSE 0 END) / NULLIF(sum(total_tokens), 0), 1) AS pct_tokens_in_10plus_error_sessions,
    round(100.0 * sum(CASE WHEN error_events = 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_sessions_no_errors,
    round(100.0 * sum(CASE WHEN error_events = 0 THEN total_tokens ELSE 0 END) / NULLIF(sum(total_tokens), 0), 1) AS pct_tokens_in_no_error_sessions
FROM labeled;


-- 7. Human rescue patterns.
-- After a human re-enters following an error, what does the agent do next?
WITH interventions AS (
    SELECT
        h.session_id,
        h.row_index_in_session AS human_row,
        h.prompt_chars,
        prev.tool_event_id AS previous_tool_event_id,
        (
            SELECT min(t.event_index)
            FROM tool_events t
            WHERE t.session_id = h.session_id
              AND t.row_index_in_session > h.row_index_in_session
        ) AS next_event_index
    FROM human_messages h
    JOIN tool_events prev
      ON prev.session_id = h.session_id
     AND prev.event_index = (
        SELECT max(t.event_index)
        FROM tool_events t
        WHERE t.session_id = h.session_id
          AND t.row_index_in_session < h.row_index_in_session
     )
    WHERE coalesce(prev.result_is_error, FALSE)
),
nexts AS (
    SELECT
        i.*,
        t.tool_family AS next_tool_family,
        t.result_is_error,
        t.result_keyword_success,
        t.result_keyword_test
    FROM interventions i
    JOIN tool_events t
      ON t.session_id = i.session_id
     AND t.event_index = i.next_event_index
)
SELECT
    next_tool_family,
    count(*) AS interventions,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
    round(avg(prompt_chars), 0) AS avg_prompt_chars,
    round(100.0 * sum(CASE WHEN coalesce(result_is_error, FALSE) THEN 1 ELSE 0 END) / count(*), 1) AS pct_next_tool_failed,
    round(100.0 * sum(CASE WHEN result_keyword_success OR result_keyword_test THEN 1 ELSE 0 END) / count(*), 1) AS pct_next_success_or_test
FROM nexts
GROUP BY next_tool_family
HAVING count(*) >= 50
ORDER BY interventions DESC;
