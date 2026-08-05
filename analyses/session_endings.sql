-- ============================================================================
-- How do sessions end?
-- ============================================================================
-- Classifies the final assistant turn of each session into an "ending type."
--
-- Expected findings (one operator, ~3,600 ended sessions):
--   - 41.1% end with text and no completion claim
--   - 35.6% end with a completion claim but no verification keyword
--   - 15.4% end mid-tool-stream (the agent was still working when terminated)
--   - 5.8% end cleanly with both completion and verification
--
-- Two smaller buckets also appear: 'session ends with tool + completion claim'
-- (the closing turn claims completion without a verification keyword while
-- still firing tools) and 'other' (empty final turns).
-- ============================================================================


WITH last_turns AS (
    SELECT
        a.session_id,
        a.tool_use_count   AS final_tools,
        a.text_chars       AS final_text_chars,
        a.completion_claim,
        a.verification_claim,
        a.text_preview,
        row_number() OVER (
            PARTITION BY a.session_id
            ORDER BY a.row_index_in_session DESC
        ) AS rn
    FROM assistant_turns a
)
SELECT
    CASE
        WHEN final_tools > 0 AND completion_claim = FALSE THEN 'session ends mid-tool-stream'
        -- Verified endings win over the tool + completion bucket, so a closing
        -- turn that both claims and verifies is never counted as unverified.
        WHEN completion_claim AND verification_claim       THEN 'session ends with claim + verification'
        WHEN final_tools > 0 AND completion_claim         THEN 'session ends with tool + completion claim'
        WHEN completion_claim AND NOT verification_claim   THEN 'session ends with completion claim, no verification'
        WHEN NOT completion_claim AND final_text_chars > 0 THEN 'session ends with text, no claim'
        ELSE 'other'
    END AS ending_type,
    count(*) AS sessions,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM last_turns
WHERE rn = 1
GROUP BY 1
ORDER BY sessions DESC;


-- Drill-down: of sessions ending mid-tool-stream, which tools were they about
-- to fire? (suggests context exhaustion vs interrupt cause)
WITH last_turns AS (
    SELECT
        a.session_id,
        a.row_index_in_session,
        a.tool_use_count,
        a.completion_claim,
        row_number() OVER (
            PARTITION BY a.session_id
            ORDER BY a.row_index_in_session DESC
        ) AS rn
    FROM assistant_turns a
)
SELECT cb.tool_name, count(*) AS truncation_events
FROM last_turns lt
JOIN content_blocks cb USING (session_id, row_index_in_session)
WHERE lt.rn = 1
  AND lt.tool_use_count > 0
  AND lt.completion_claim = FALSE
  AND cb.block_type = 'tool_use'
GROUP BY cb.tool_name
ORDER BY truncation_events DESC
LIMIT 20;
