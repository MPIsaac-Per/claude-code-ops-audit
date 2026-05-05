-- ============================================================================
-- Error distribution and recovery patterns
-- ============================================================================
-- The narrative around AI agent failure is "they hallucinate code" or "they
-- break tests." This corpus shows that authentication is the dominant failure
-- mode in real-world agent operation.
--
-- Expected findings (one operator, ~98K total errors):
--   - 51% of errors are auth-related
--   - Bash error rate is 12.65% across all calls
--   - WebFetch error rate is 16.4%
--   - 50.1% of sessions have ZERO errors
--   - Of erroring sessions, 35.9% hit first error within first 19 events
-- ============================================================================


-- 1. Error type distribution
SELECT
    CASE
        WHEN keyword_auth      THEN 'auth'
        WHEN keyword_not_found THEN 'not_found'
        WHEN keyword_timeout   THEN 'timeout'
        WHEN keyword_error     THEN 'generic_error'
        WHEN result_is_error   THEN 'tool_marked_error'
        ELSE 'other'
    END AS error_type,
    count(*) AS occurrences,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM content_blocks
WHERE row_type = 'user'
  AND block_type = 'tool_result'
  AND (result_is_error OR keyword_error OR keyword_auth OR keyword_not_found OR keyword_timeout)
GROUP BY 1
ORDER BY occurrences DESC;


-- 2. Tool error rate ranking (which tools fail most often?)
SELECT
    tool_name,
    count(*) AS calls,
    sum(CASE WHEN result_is_error THEN 1 ELSE 0 END) AS errors,
    round(100.0 * sum(CASE WHEN result_is_error THEN 1 ELSE 0 END) / count(*), 2) AS error_pct
FROM tool_events
WHERE tool_name IS NOT NULL
GROUP BY tool_name
HAVING count(*) >= 500
ORDER BY error_pct DESC;


-- 3. Time-to-first-error distribution
WITH first_err AS (
    SELECT t.session_id, MIN(t.event_index) AS first_err_event_index
    FROM tool_events t
    WHERE t.result_is_error
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


-- 4. Recovery: what happens in the next 10 events after an error?
-- Top recovery paths by frequency.
SELECT
    error_tool_family,
    error_tool_name,
    next_tool_family,
    next_tool_name,
    distance,
    occurrences,
    repeated_failure_count,
    success_or_test_signal_count
FROM error_recovery_summary
WHERE occurrences >= 50
ORDER BY occurrences DESC
LIMIT 25;


-- 5. Auth-error recovery rate vs other error types
WITH errs AS (
    SELECT
        CASE
            WHEN result_keyword_auth      THEN 'auth'
            WHEN result_keyword_not_found THEN 'not_found'
            WHEN result_keyword_timeout   THEN 'timeout'
            ELSE 'generic'
        END AS error_type,
        next_result_is_error
    FROM post_error_next_10
    WHERE distance = 1
)
SELECT
    error_type,
    count(*) AS error_to_next_pairs,
    sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) AS next_was_also_error,
    round(100.0 * sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) / count(*), 1) AS pct_repeated_failure
FROM errs
GROUP BY 1
ORDER BY pct_repeated_failure DESC;
