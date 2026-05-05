-- ============================================================================
-- Parallel tool calls: how often does the model batch tools in a single turn?
-- ============================================================================
-- The Anthropic API supports multiple tool_use blocks per assistant message.
-- Claude Code's system prompt explicitly instructs the model to batch
-- independent tool calls. This query measures how often it actually happens.
--
-- Expected findings (one operator, ~245K tool calls):
--   - 0.022% of all assistant turns batch tool calls (97 of 446,639)
--   - 0.040% of tool-using turns batch (97 of 245,153)
--   - Opus 4.7 has zero batched turns (0 / 29,044)
--   - Sonnet/Haiku batch ~10x more than Opus (still ~0.25%)
--   - Cross-validated against content_blocks (no data artifact)
-- ============================================================================


-- 1. Headline distribution: tools per turn
SELECT
    CASE
        WHEN tool_use_count = 0 THEN '0 (text only)'
        WHEN tool_use_count = 1 THEN '1'
        WHEN tool_use_count = 2 THEN '2'
        WHEN tool_use_count = 3 THEN '3'
        WHEN tool_use_count = 4 THEN '4'
        WHEN tool_use_count BETWEEN 5 AND 9 THEN '5-9'
        WHEN tool_use_count >= 10 THEN '10+'
    END AS tools_per_turn,
    count(*) AS turns,
    round(100.0 * count(*) / sum(count(*)) OVER (), 3) AS pct
FROM assistant_turns
GROUP BY 1
ORDER BY min(tool_use_count);


-- 2. Cross-check via content_blocks (independent count for data integrity)
WITH per_turn AS (
    SELECT session_id, row_index_in_session,
           count(*) FILTER (WHERE block_type = 'tool_use') AS blocks_tool_uses
    FROM content_blocks
    WHERE row_type = 'assistant'
    GROUP BY session_id, row_index_in_session
)
SELECT
    blocks_tool_uses AS tools_per_turn,
    count(*) AS turns,
    round(100.0 * count(*) / sum(count(*)) OVER (), 3) AS pct
FROM per_turn
GROUP BY 1
ORDER BY 1;


-- 3. Batching by model (Opus generations diverge sharply from Sonnet/Haiku)
SELECT
    model,
    count(*) AS tool_turns,
    sum(CASE WHEN tool_use_count >= 2 THEN 1 ELSE 0 END) AS batched_turns,
    round(100.0 * sum(CASE WHEN tool_use_count >= 2 THEN 1 ELSE 0 END) / count(*), 3) AS pct_batched
FROM assistant_turns
WHERE tool_use_count > 0
  AND model IS NOT NULL
GROUP BY model
HAVING count(*) >= 1000
ORDER BY tool_turns DESC;


-- 4. What tools, when they DO batch, get batched together?
WITH batched AS (
    SELECT session_id, row_index_in_session
    FROM assistant_turns
    WHERE tool_use_count >= 2
)
SELECT cb.tool_name, count(*) AS calls_in_batched_turns
FROM content_blocks cb
JOIN batched b USING (session_id, row_index_in_session)
WHERE cb.block_type = 'tool_use'
GROUP BY cb.tool_name
ORDER BY calls_in_batched_turns DESC;


-- 5. Behavioral hypothesis: batched turns use far more thinking
-- (suggests extended thinking is the path to batching, not prompt instructions)
SELECT
    CASE WHEN tool_use_count = 0 THEN 'text_only'
         WHEN tool_use_count = 1 THEN 'serial_1_tool'
         WHEN tool_use_count >= 2 THEN 'batched_2plus'
    END AS turn_kind,
    count(*) AS turns,
    round(avg(thinking_block_count), 3) AS avg_thinking_blocks,
    round(100.0 * sum(CASE WHEN thinking_block_count > 0 THEN 1 ELSE 0 END) / count(*), 1) AS pct_with_thinking,
    round(avg(output_tokens), 1) AS avg_output_tokens
FROM assistant_turns
GROUP BY 1
ORDER BY MIN(tool_use_count);
