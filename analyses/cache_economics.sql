-- ============================================================================
-- Cache economics: how does prompt-cache leverage scale with session length?
-- ============================================================================
-- Anthropic's prompt caching charges ~10% of fresh-input rates for cache reads.
-- This query measures real-world cache leverage — what percentage of every
-- turn's input tokens come from cache vs fresh.
--
-- Expected findings (one operator, multi-month corpus):
--   - Even early turns (1-5) are 93%+ cache by token count
--   - Deep turns (200+) are 99.94% cache: ~194,000 cache tokens vs 116 fresh
--   - This is the load-bearing economic substrate of agentic coding
-- ============================================================================


-- 1. Cache leverage by turn position in session
SELECT
    CASE
        WHEN assistant_index_in_session BETWEEN 0   AND 4   THEN '01-05 (early)'
        WHEN assistant_index_in_session BETWEEN 5   AND 19  THEN '06-20'
        WHEN assistant_index_in_session BETWEEN 20  AND 49  THEN '21-50'
        WHEN assistant_index_in_session BETWEEN 50  AND 99  THEN '51-100'
        WHEN assistant_index_in_session BETWEEN 100 AND 199 THEN '101-200'
        WHEN assistant_index_in_session >= 200              THEN '200+ (deep)'
    END AS turn_position,
    count(*) AS turns,
    round(avg(input_tokens),                 0) AS avg_fresh_input,
    round(avg(cache_read_input_tokens),      0) AS avg_cache_read,
    round(avg(cache_creation_input_tokens),  0) AS avg_cache_creation,
    round(avg(output_tokens),                0) AS avg_output,
    round(100.0 * avg(cache_read_input_tokens) / NULLIF(avg(cache_read_input_tokens) + avg(input_tokens), 0), 2) AS pct_cache_of_input
FROM assistant_turns
WHERE input_tokens IS NOT NULL
GROUP BY 1
ORDER BY MIN(assistant_index_in_session);


-- 2. Per-session cache leverage distribution
-- (does any session NOT lean heavily on cache? short sessions?)
WITH sess AS (
    SELECT session_id,
           sum(input_tokens) AS total_fresh,
           sum(cache_read_input_tokens) AS total_cache,
           count(*) AS turns
    FROM assistant_turns
    WHERE input_tokens IS NOT NULL
    GROUP BY session_id
)
SELECT
    CASE
        WHEN turns < 10 THEN 'short (<10 turns)'
        WHEN turns < 50 THEN 'medium (10-49)'
        WHEN turns < 200 THEN 'long (50-199)'
        ELSE 'very long (200+)'
    END AS session_size,
    count(*) AS sessions,
    round(avg(total_fresh), 0) AS avg_total_fresh,
    round(avg(total_cache), 0) AS avg_total_cache,
    round(100.0 * avg(total_cache) / NULLIF(avg(total_cache) + avg(total_fresh), 0), 2) AS pct_cache
FROM sess
GROUP BY 1
ORDER BY MIN(turns);


-- 3. Cost-without-cache estimate
-- How much would deep sessions cost without prompt caching?
-- Uses Opus pricing as of 2026: $15/MTok input, $1.50/MTok cache read.
SELECT
    CASE
        WHEN assistant_index_in_session < 50 THEN 'turns 1-49'
        WHEN assistant_index_in_session < 200 THEN 'turns 50-199'
        ELSE 'turns 200+'
    END AS turn_position,
    count(*) AS turns,
    round(avg(input_tokens) * 15.0 / 1000000, 4) AS cost_per_turn_no_cache_usd,
    round(avg(cache_read_input_tokens) * 1.50 / 1000000, 4) AS cost_per_turn_with_cache_usd,
    round(((avg(input_tokens) + avg(cache_read_input_tokens)) * 15.0 / 1000000) - ((avg(input_tokens) * 15.0 + avg(cache_read_input_tokens) * 1.50) / 1000000), 4) AS cache_savings_per_turn_usd
FROM assistant_turns
WHERE input_tokens IS NOT NULL
GROUP BY 1
ORDER BY MIN(assistant_index_in_session);
