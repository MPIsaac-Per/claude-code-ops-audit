-- ============================================================================
-- Search share vs. entire.io / pgr (Experiment 1)
-- ============================================================================
-- The entire.io blog post on `pgr` reports that 48.8% of tool calls in its
-- 202,142-call corpus were search-related, sub-divided as:
--   49% file retrieval (Read-equivalent)
--   23.5% bash search (Bash with rg/grep/find verbs)
--   23.5% grep/content search (Grep/Glob-equivalent)
--
-- This query replicates the same split on a Claude Code corpus using:
--   file_read     → Read, NotebookRead
--   file_search   → Grep, Glob
--   shell_search  → Bash search/file-discovery behavior
--
-- We report three definitions of "shell search":
--   strict_token — first command token is rg, grep, find, fd, ag, ack, locate
--   strict_text  — command text contains those search verbs anywhere
--   wide_token   — strict_token + ls, cat, head, tail, wc, file, tree, less, more
--
-- strict_token is a conservative lower bound. strict_text catches compound
-- commands such as `cd repo && rg ...` and remote shell searches, but can also
-- count search words in heredocs or long prompts because command_preview is
-- only a truncated shell-text preview, not a parsed shell AST.
-- ============================================================================


CREATE OR REPLACE TEMP TABLE search_classified AS
WITH flags AS (
    SELECT
        *,
        (
            tool_family = 'file_read'
            OR tool_name IN ('Read', 'NotebookRead')
        ) AS is_file_retrieval,
        (
            tool_family = 'file_search'
            OR tool_name IN ('Grep', 'Glob')
        ) AS is_content_search,
        tool_family = 'shell'
            AND command_verb IN ('rg','grep','find','fd','ag','ack','locate') AS shell_search_strict_token,
        tool_family = 'shell'
            AND regexp_matches(
                coalesce(command_preview, ''),
                '(^|[;&|[:space:]])(rg|grep|find|fd|ag|ack|locate)([[:space:]]|$)',
                'i'
            ) AS shell_search_strict_text,
        tool_family = 'shell'
            AND command_verb IN (
                'rg','grep','find','fd','ag','ack','locate',
                'ls','cat','head','tail','wc','file','tree','less','more'
            ) AS shell_search_wide_token
    FROM tool_events
)
SELECT
    *,
    CASE
        WHEN is_file_retrieval THEN 'file_retrieval'
        WHEN is_content_search THEN 'grep_content_search'
        WHEN shell_search_strict_token THEN 'bash_search_strict_token'
        ELSE 'non_search'
    END AS strict_token_bucket,
    CASE
        WHEN is_file_retrieval THEN 'file_retrieval'
        WHEN is_content_search THEN 'grep_content_search'
        WHEN shell_search_strict_text THEN 'bash_search_strict_text'
        ELSE 'non_search'
    END AS strict_text_bucket,
    CASE
        WHEN is_file_retrieval THEN 'file_retrieval'
        WHEN is_content_search THEN 'grep_content_search'
        WHEN shell_search_wide_token THEN 'bash_search_wide_token'
        ELSE 'non_search'
    END AS wide_token_bucket
FROM flags;


-- 1. Total tool events as denominator.
SELECT
    count(*) AS total_tool_events,
    count(DISTINCT session_id) AS sessions
FROM tool_events;


-- 2. Tool family distribution (full taxonomy, for context).
WITH counts AS (
    SELECT tool_family, count(*) AS events
    FROM tool_events
    GROUP BY tool_family
)
SELECT
    tool_family,
    events,
    round(100.0 * events / sum(events) OVER (), 2) AS pct
FROM counts
ORDER BY events DESC;


-- 3. Search share replication, strict first-token Bash-search definition.
WITH counts AS (
    SELECT strict_token_bucket AS bucket, count(*) AS events
    FROM search_classified
    GROUP BY bucket
)
SELECT
    bucket,
    events,
    round(100.0 * events / sum(events) OVER (), 2) AS pct_of_all_tool_events,
    CASE
        WHEN bucket = 'non_search' THEN NULL
        ELSE round(
            100.0 * events
            / NULLIF(sum(events) FILTER (WHERE bucket <> 'non_search') OVER (), 0),
            2
        )
    END AS pct_of_search_subset
FROM counts
ORDER BY events DESC;


-- 4. Search share sensitivity: strict text scan catches compound Bash.
WITH counts AS (
    SELECT strict_text_bucket AS bucket, count(*) AS events
    FROM search_classified
    GROUP BY bucket
)
SELECT
    bucket,
    events,
    round(100.0 * events / sum(events) OVER (), 2) AS pct_of_all_tool_events,
    CASE
        WHEN bucket = 'non_search' THEN NULL
        ELSE round(
            100.0 * events
            / NULLIF(sum(events) FILTER (WHERE bucket <> 'non_search') OVER (), 0),
            2
        )
    END AS pct_of_search_subset
FROM counts
ORDER BY events DESC;


-- 5. Search share replication, wide first-token Bash-search definition.
WITH counts AS (
    SELECT wide_token_bucket AS bucket, count(*) AS events
    FROM search_classified
    GROUP BY bucket
)
SELECT
    bucket,
    events,
    round(100.0 * events / sum(events) OVER (), 2) AS pct_of_all_tool_events,
    CASE
        WHEN bucket = 'non_search' THEN NULL
        ELSE round(
            100.0 * events
            / NULLIF(sum(events) FILTER (WHERE bucket <> 'non_search') OVER (), 0),
            2
        )
    END AS pct_of_search_subset
FROM counts
ORDER BY events DESC;


-- 6. Bash-search sensitivity: first token vs command-text scan.
SELECT
    count(*) AS shell_events,
    sum(CASE WHEN shell_search_strict_token THEN 1 ELSE 0 END) AS strict_first_token_searches,
    sum(CASE WHEN shell_search_strict_text THEN 1 ELSE 0 END) AS strict_command_text_searches,
    sum(CASE WHEN shell_search_strict_text AND NOT shell_search_strict_token THEN 1 ELSE 0 END) AS text_searches_missed_by_first_token
FROM search_classified
WHERE tool_family = 'shell';


-- 7. Top bash command verbs by frequency (sanity check the search-verb set).
WITH counts AS (
    SELECT command_verb, count(*) AS events
    FROM tool_events
    WHERE tool_family = 'shell'
      AND command_verb IS NOT NULL
      AND command_verb <> ''
    GROUP BY command_verb
)
SELECT
    command_verb,
    events,
    round(100.0 * events / sum(events) OVER (), 2) AS pct_of_bash
FROM counts
ORDER BY events DESC
LIMIT 30;


-- 8. Search share by model — does the search-heavy pattern hold across
--    Opus generations, or does it shift?
WITH joined AS (
    SELECT
        coalesce(ast.model, te.model, 'unknown') AS model,
        te.tool_family,
        te.command_verb,
        te.is_file_retrieval,
        te.is_content_search,
        te.shell_search_strict_token,
        te.shell_search_strict_text,
        te.shell_search_wide_token
    FROM search_classified te
    LEFT JOIN assistant_turns ast
      ON ast.session_id = te.session_id
     AND ast.row_index_in_session = te.row_index_in_session
)
SELECT
    model,
    count(*) AS events,
    round(100.0 * sum(CASE WHEN is_file_retrieval THEN 1 ELSE 0 END) / count(*), 2) AS pct_file_retrieval,
    round(100.0 * sum(CASE WHEN is_content_search THEN 1 ELSE 0 END) / count(*), 2) AS pct_content_search,
    round(100.0 * sum(CASE WHEN shell_search_strict_token THEN 1 ELSE 0 END) / count(*), 2) AS pct_bash_search_strict_token,
    round(100.0 * sum(CASE WHEN shell_search_strict_text THEN 1 ELSE 0 END) / count(*), 2) AS pct_bash_search_strict_text,
    round(100.0 * sum(CASE WHEN shell_search_wide_token THEN 1 ELSE 0 END) / count(*), 2) AS pct_bash_search_wide_token,
    round(100.0 * sum(CASE WHEN is_file_retrieval
                             OR is_content_search
                             OR shell_search_strict_token
                            THEN 1 ELSE 0 END) / count(*), 2) AS pct_search_total_strict
FROM joined
WHERE model IS NOT NULL
GROUP BY model
HAVING count(*) >= 1000
ORDER BY events DESC;
