-- ============================================================================
-- claude-code-ops-audit — derived views
-- ============================================================================
-- Reusable views that layer on top of the 8 base tables in 01_tables.sql.
-- These power most of the analyses in /analyses.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- error_events
-- All tool events whose result was an error or matched any error keyword.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW error_events AS
SELECT *
FROM tool_events
WHERE result_is_error
   OR result_keyword_error
   OR result_keyword_auth
   OR result_keyword_not_found
   OR result_keyword_timeout;


-- ----------------------------------------------------------------------------
-- post_error_next_10
-- For each error event, the up to 10 subsequent tool events in the same session.
-- Useful for analyzing recovery patterns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW post_error_next_10 AS
SELECT
    e.tool_event_id            AS error_event_id,
    e.session_id,
    e.event_index              AS error_event_index,
    e.tool_name                AS error_tool_name,
    e.tool_family              AS error_tool_family,
    e.result_keyword_auth,
    e.result_keyword_not_found,
    e.result_keyword_timeout,
    e.result_keyword_test,
    n.event_index - e.event_index AS distance,
    n.tool_name                AS next_tool_name,
    n.tool_family              AS next_tool_family,
    n.result_is_error          AS next_result_is_error,
    n.result_keyword_error     AS next_result_keyword_error,
    n.result_keyword_success   AS next_result_keyword_success,
    n.result_keyword_test      AS next_result_keyword_test
FROM error_events e
JOIN tool_events n
  ON n.session_id = e.session_id
 AND n.event_index >  e.event_index
 AND n.event_index <= e.event_index + 10;


-- ----------------------------------------------------------------------------
-- error_recovery_summary
-- Aggregated recovery patterns: for each (error_tool, next_tool, distance),
-- how many times did it occur, how often did it lead to repeated failure,
-- how often did it produce a success/test signal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW error_recovery_summary AS
SELECT
    error_tool_family,
    error_tool_name,
    next_tool_family,
    next_tool_name,
    distance,
    count(*) AS occurrences,
    sum(CASE WHEN next_result_is_error OR next_result_keyword_error THEN 1 ELSE 0 END) AS repeated_failure_count,
    sum(CASE WHEN next_result_keyword_success OR next_result_keyword_test THEN 1 ELSE 0 END) AS success_or_test_signal_count
FROM post_error_next_10
GROUP BY 1, 2, 3, 4, 5
ORDER BY occurrences DESC;


-- ----------------------------------------------------------------------------
-- tool_transitions
-- Pairs of (tool, next_tool) with counts. Powers the operating-loop diagrams.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW tool_transitions AS
SELECT
    tool_family,
    tool_name,
    next_tool_family,
    next_tool_name,
    count(*) AS transitions,
    sum(CASE WHEN result_is_error OR result_keyword_error THEN 1 ELSE 0 END) AS source_error_events,
    sum(CASE WHEN next_result_is_error THEN 1 ELSE 0 END) AS next_explicit_error_events
FROM tool_events
WHERE next_tool_name IS NOT NULL
  AND next_tool_name != ''
GROUP BY 1, 2, 3, 4
ORDER BY transitions DESC;


-- ----------------------------------------------------------------------------
-- tool_family_transitions
-- Coarser version of tool_transitions, grouped by family only.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW tool_family_transitions AS
SELECT
    tool_family,
    next_tool_family,
    count(*) AS transitions,
    count(DISTINCT session_id) AS sessions
FROM tool_events
WHERE next_tool_family IS NOT NULL
  AND next_tool_family != ''
GROUP BY 1, 2
ORDER BY transitions DESC;


-- ----------------------------------------------------------------------------
-- bash_command_patterns
-- Distribution of Bash command shapes (simple, long_one_liner, multi_line)
-- crossed with pipe/redirect/subshell flags. Error rates by shape.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bash_command_patterns AS
SELECT
    command_verb,
    command_has_pipe,
    command_has_redirect,
    command_has_subshell,
    CASE
        WHEN command_lines >= 3 THEN 'multi_line'
        WHEN command_chars >= 180 THEN 'long_one_liner'
        ELSE 'simple'
    END AS command_shape,
    count(*) AS bash_events,
    count(DISTINCT session_id) AS sessions,
    sum(CASE WHEN result_is_error OR result_keyword_error THEN 1 ELSE 0 END) AS error_events,
    sum(CASE WHEN result_keyword_test THEN 1 ELSE 0 END) AS test_surface_events,
    sum(CASE WHEN result_keyword_git  THEN 1 ELSE 0 END) AS git_surface_events
FROM tool_events
WHERE tool_name = 'Bash'
GROUP BY 1, 2, 3, 4, 5
ORDER BY bash_events DESC;


-- ----------------------------------------------------------------------------
-- file_hotspots
-- Files referenced most often by tool calls. Used for codebase complexity proxy.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW file_hotspots AS
SELECT
    file_path,
    file_extension,
    tool_name,
    tool_family,
    count(*) AS events,
    count(DISTINCT session_id) AS sessions,
    sum(CASE WHEN result_is_error OR result_keyword_error THEN 1 ELSE 0 END) AS error_events
FROM tool_events
WHERE file_path IS NOT NULL
  AND file_path != ''
GROUP BY 1, 2, 3, 4
ORDER BY events DESC;


-- ----------------------------------------------------------------------------
-- verification_sequences
-- Augments tool_events with an is_verification_event flag.
-- A tool call is "verification" if it's a Bash command matching test/build/lint
-- keywords, or its result_preview matched the test keyword heuristic.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW verification_sequences AS
SELECT *,
    CASE
        WHEN tool_name = 'Bash'
             AND regexp_matches(command_preview, '(test|pytest|vitest|jest|build|lint|typecheck|check)', 'i') THEN TRUE
        WHEN result_keyword_test THEN TRUE
        ELSE FALSE
    END AS is_verification_event
FROM tool_events;


-- ----------------------------------------------------------------------------
-- human_intervention_points
-- Each human message paired with the previous tool event and its error status.
-- Shows what tools/situations the user re-enters after.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW human_intervention_points AS
SELECT
    h.*,
    prev.tool_event_id              AS previous_tool_event_id,
    prev.tool_name                  AS previous_tool_name,
    prev.tool_family                AS previous_tool_family,
    prev.result_is_error            AS previous_result_is_error,
    prev.result_keyword_error       AS previous_result_keyword_error,
    prev.result_keyword_auth        AS previous_result_keyword_auth,
    prev.result_keyword_test        AS previous_result_keyword_test,
    h.row_index_in_session - prev.row_index_in_session AS previous_tool_row_distance
FROM human_messages h
LEFT JOIN tool_events prev
  ON prev.session_id = h.session_id
 AND prev.event_index = (
        SELECT max(t.event_index)
        FROM tool_events t
        WHERE t.session_id = h.session_id
          AND t.row_index_in_session < h.row_index_in_session
     );


-- ----------------------------------------------------------------------------
-- plausible_completion_candidates
-- Assistant turns that claimed completion (per keyword heuristic) but had NO
-- verification keyword on the same turn. Records distance to the next
-- verification event in the session, and to the next human message.
--
-- This is the candidate generator for the verification-debt audit. It is NOT
-- a final classifier — manual review reveals ~76% false positive rate (the
-- model often verifies via output the keyword scan misses, or the "completion
-- claim" is actually narrative). Use the audit/ pipeline to refine.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW plausible_completion_candidates AS
SELECT
    a.*,
    -- text_preview is substr(text, 1, 500), so the preview is the full turn
    -- text whenever the turn fits in 500 chars. The audit rubric uses this.
    (a.text_chars <= 500) AS preview_is_full,
    sm.tool_events  AS session_tool_events,
    sm.error_events AS session_error_events,
    (
        SELECT min(t.event_index)
        FROM tool_events t
        WHERE t.session_id = a.session_id
          AND t.row_index_in_session > a.row_index_in_session
          AND (
              t.result_keyword_test
              OR (
                  t.tool_name = 'Bash'
                  AND regexp_matches(t.command_preview, '(test|pytest|vitest|jest|build|lint|typecheck|check)', 'i')
              )
          )
    ) AS next_verification_event_index,
    (
        SELECT min(h.human_index_in_session)
        FROM human_messages h
        WHERE h.session_id = a.session_id
          AND h.row_index_in_session > a.row_index_in_session
    ) AS next_human_message_index
FROM assistant_turns a
LEFT JOIN session_metrics sm USING (session_id)
WHERE a.completion_claim
  AND NOT a.verification_claim;


-- ----------------------------------------------------------------------------
-- session_outcome_signals
-- Per-session boolean flags for git/test/edit/error surfaces and "long loop".
-- Useful for clustering sessions into archetypes downstream.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW session_outcome_signals AS
SELECT
    sm.*,
    (git_result_events  > 0)  AS has_git_surface,
    (test_result_events > 0)  AS has_test_surface,
    (edit_events        > 0)  AS has_file_mutation,
    (error_events       > 0)  AS has_error_surface,
    (tool_events     >= 100)  AS is_long_loop
FROM session_metrics sm;
