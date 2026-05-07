-- ============================================================================
-- Error distribution and recovery patterns
-- ============================================================================
-- `result_is_error` is the reliable explicit failure label. Keyword flags are
-- useful as "error-surface" signals, but they can fire on normal result text
-- such as source code, search output, web pages, and delegated task summaries.
-- Keep those surfaces separate unless you have manually validated them.
-- ============================================================================


-- 1. Keyword-signal distribution across tool results.
-- This is not a failure distribution; it is a text-surface distribution.
SELECT
    CASE
        WHEN coalesce(keyword_auth, FALSE)      THEN 'auth'
        WHEN coalesce(keyword_not_found, FALSE) THEN 'not_found'
        WHEN coalesce(keyword_timeout, FALSE)   THEN 'timeout'
        WHEN coalesce(keyword_error, FALSE)     THEN 'generic_error'
        ELSE 'other'
    END AS keyword_signal_type,
    count(*) AS occurrences,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM content_blocks
WHERE row_type = 'user'
  AND block_type = 'tool_result'
  AND (
      coalesce(keyword_error, FALSE)
      OR coalesce(keyword_auth, FALSE)
      OR coalesce(keyword_not_found, FALSE)
      OR coalesce(keyword_timeout, FALSE)
  )
GROUP BY 1
ORDER BY occurrences DESC;


-- 2. Explicit tool error ranking (which tools are marked failed?)
WITH classified AS (
    SELECT
        *,
        coalesce(result_is_error, FALSE) AS explicit_error,
        coalesce(result_keyword_error, FALSE)
        OR coalesce(result_keyword_auth, FALSE)
        OR coalesce(result_keyword_not_found, FALSE)
        OR coalesce(result_keyword_timeout, FALSE) AS keyword_signal
    FROM tool_events
)
SELECT
    tool_name,
    count(*) AS calls,
    sum(CASE WHEN explicit_error THEN 1 ELSE 0 END) AS explicit_errors,
    round(100.0 * sum(CASE WHEN explicit_error THEN 1 ELSE 0 END) / count(*), 2) AS explicit_error_pct,
    sum(CASE WHEN keyword_signal THEN 1 ELSE 0 END) AS keyword_signal_events,
    round(100.0 * sum(CASE WHEN keyword_signal THEN 1 ELSE 0 END) / count(*), 2) AS keyword_signal_pct
FROM classified
WHERE tool_name IS NOT NULL
GROUP BY tool_name
HAVING count(*) >= 500
ORDER BY explicit_error_pct DESC;


-- 3. Time-to-first explicit error distribution.
WITH first_err AS (
    SELECT t.session_id, MIN(t.event_index) AS first_err_event_index
    FROM tool_events t
    WHERE coalesce(t.result_is_error, FALSE)
    GROUP BY t.session_id
)
SELECT
    CASE
        WHEN first_err_event_index IS NULL  THEN 'no errors in session'
        WHEN first_err_event_index < 5      THEN 'within first 5 events'
        WHEN first_err_event_index < 20     THEN '5-19'
        WHEN first_err_event_index < 100    THEN '20-99'
        WHEN first_err_event_index < 500    THEN '100-499'
        ELSE '500+'
    END AS first_error_at,
    count(*) AS sessions,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM session_metrics sm
LEFT JOIN first_err USING (session_id)
GROUP BY 1
ORDER BY MIN(COALESCE(first_err_event_index, 999999));


-- 4. Recovery: what happens in the next 10 events after an explicit error?
-- Top recovery paths by frequency.
WITH explicit_errors AS (
    SELECT *
    FROM tool_events
    WHERE coalesce(result_is_error, FALSE)
),
post_error_next_10_explicit AS (
    SELECT
        e.tool_event_id AS error_event_id,
        e.session_id,
        e.event_index AS error_event_index,
        e.tool_name AS error_tool_name,
        e.tool_family AS error_tool_family,
        n.event_index - e.event_index AS distance,
        n.tool_name AS next_tool_name,
        n.tool_family AS next_tool_family,
        coalesce(n.result_is_error, FALSE) AS next_result_is_error,
        coalesce(n.result_keyword_success, FALSE) AS next_result_keyword_success,
        coalesce(n.result_keyword_test, FALSE) AS next_result_keyword_test
    FROM explicit_errors e
    JOIN tool_events n
      ON n.session_id = e.session_id
     AND n.event_index > e.event_index
     AND n.event_index <= e.event_index + 10
),
summary AS (
    SELECT
        error_tool_family,
        error_tool_name,
        next_tool_family,
        next_tool_name,
        distance,
        count(*) AS occurrences,
        sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) AS repeated_failure_count,
        sum(CASE WHEN next_result_keyword_success OR next_result_keyword_test THEN 1 ELSE 0 END) AS success_or_test_signal_count
    FROM post_error_next_10_explicit
    GROUP BY 1, 2, 3, 4, 5
)
SELECT
    error_tool_family,
    error_tool_name,
    next_tool_family,
    next_tool_name,
    distance,
    occurrences,
    repeated_failure_count,
    success_or_test_signal_count
FROM summary
WHERE occurrences >= 50
ORDER BY occurrences DESC
LIMIT 25;


-- 5. Explicit-error recovery rate, with keyword labels only used as
-- explanatory subtypes of explicit failures.
WITH errs AS (
    SELECT
        CASE
            WHEN coalesce(e.result_keyword_auth, FALSE)      THEN 'auth'
            WHEN coalesce(e.result_keyword_not_found, FALSE) THEN 'not_found'
            WHEN coalesce(e.result_keyword_timeout, FALSE)   THEN 'timeout'
            ELSE 'generic'
        END AS error_type,
        coalesce(n.result_is_error, FALSE) AS next_result_is_error
    FROM tool_events e
    JOIN tool_events n
      ON n.session_id = e.session_id
     AND n.event_index = e.event_index + 1
    WHERE coalesce(e.result_is_error, FALSE)
)
SELECT
    error_type,
    count(*) AS error_to_next_pairs,
    sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) AS next_was_also_error,
    round(100.0 * sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) / count(*), 1) AS pct_repeated_failure
FROM errs
GROUP BY 1
ORDER BY pct_repeated_failure DESC;
