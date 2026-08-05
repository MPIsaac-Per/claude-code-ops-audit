-- ============================================================================
-- claude-code-ops-audit — JSONL → DuckDB ingest pipeline
-- ============================================================================
-- Loads Claude Code session JSONL files (typically in ~/.claude/projects/)
-- into the event mart schema defined in schema/01_tables.sql.
--
-- Usage:
--   1. Start DuckDB pointed at a fresh database:
--        duckdb my_corpus.duckdb
--   2. Set the JSONL_GLOB variable to point at your Claude Code logs.
--        SET VARIABLE jsonl_glob = '/Users/you/.claude/projects/**/*.jsonl';
--   3. Run the schema:
--        .read schema/01_tables.sql
--   4. Run this ingest:
--        .read ingest/jsonl_to_duckdb.sql
--   5. Run the views:
--        .read schema/02_views.sql
--
-- This pipeline populates the six base tables that can be derived purely
-- from the JSONL: jsonl_rows, content_blocks, human_messages, assistant_turns,
-- tool_events, and session_metrics.
--
-- The progress_events and corpus_files tables are optional and depend on
-- additional metadata not present in raw JSONL (file mtime, etc.).
--
-- Troubleshooting: a Binder Error like 'Referenced column "sessionId" not
-- found' means the glob matched only empty or non-conforming files, so
-- read_json inferred no schema. Point jsonl_glob at real Claude Code session
-- logs. A glob that matches no files at all fails earlier with an IO Error.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Helper: keyword detection for completion / verification claims
-- These regexes power the completion_claim / verification_claim flags on
-- assistant_turns. Tune them to your corpus if needed.
-- ----------------------------------------------------------------------------

-- The completion-claim pattern catches "done", "complete(d)", "fixed", "shipped",
-- "merged", "marked done", "all set", "ready for review", "implemented", etc.
-- The verification-claim pattern catches "tests pass", "build success", "0 errors",
-- "lint clean", "typecheck passed", "X/Y green", etc.
--
-- These are deliberately conservative — high precision, low recall. The audit
-- pipeline (audit/) corrects for false positives via LLM-assisted review.


-- Read the corpus once and assign scan-order indexes once. Re-reading the
-- glob for each table can produce inconsistent row indexes when timestamps
-- collide. The session ordering assumes the input contains one canonical
-- snapshot per session; see docs/METHODOLOGY.md for rolling archives.
CREATE OR REPLACE TEMP TABLE _raw_jsonl AS
WITH scanned AS (
    SELECT
        *,
        row_number() OVER () AS _scan_index
    FROM read_json(
        getvariable('jsonl_glob'),
        format='newline_delimited',
        filename=true,
        union_by_name=true,
        ignore_errors=true
    )
)
SELECT
    *,
    row_number() OVER (
        PARTITION BY filename
        ORDER BY _scan_index
    ) - 1 AS _rownum_in_file
FROM scanned;


-- ----------------------------------------------------------------------------
-- 1. jsonl_rows: load all JSONL lines into structured rows
-- ----------------------------------------------------------------------------
-- Adjust the path to your own Claude Code log location.
INSERT INTO jsonl_rows BY NAME
SELECT
    -- row_id assigned by sequence
    row_number() OVER (ORDER BY filename, _rownum_in_file) AS row_id,
    -- file_id placeholder; corpus_files population is optional
    NULL::UBIGINT AS file_id,
    filename AS source_blob,
    sessionId AS session_id,
    regexp_extract(filename, '/([0-9a-f-]{36})\.jsonl$', 1) AS path_session_id,
    _rownum_in_file::UINTEGER AS row_index_in_file,
    row_number() OVER (
        PARTITION BY sessionId
        ORDER BY filename, _rownum_in_file
    )::UINTEGER - 1 AS row_index_in_session,
    type AS row_type,
    timestamp::TIMESTAMP WITH TIME ZONE AS "timestamp",
    cwd,
    -- "project" is a derived label; here we use the parent directory name
    regexp_extract(cwd, '([^/]+)$', 1) AS project,
    -- "environment" is an optional tag the user may apply; not derived here
    NULL AS environment,
    version,
    gitBranch AS git_branch,
    NULL AS entrypoint,
    userType AS user_type,
    NULL AS permission_mode,
    uuid,
    parentUuid AS parent_uuid,
    isSidechain AS is_sidechain,
    requestId AS request_id,
    message.model AS message_model,
    message.stop_reason AS stop_reason,
    message.usage.input_tokens AS input_tokens,
    message.usage.output_tokens AS output_tokens,
    message.usage.cache_creation_input_tokens AS cache_creation_input_tokens,
    message.usage.cache_read_input_tokens AS cache_read_input_tokens,
    coalesce(len(message.content), 0)::UINTEGER AS content_block_count,
    coalesce(length(message.content::VARCHAR), 0)::UBIGINT AS message_chars,
    md5(coalesce(message.content::VARCHAR, '')) AS message_hash,
    substr(coalesce(message.content::VARCHAR, ''), 1, 500) AS message_preview
FROM _raw_jsonl;


-- ----------------------------------------------------------------------------
-- 2. content_blocks: explode message.content arrays into individual blocks
-- ----------------------------------------------------------------------------
INSERT INTO content_blocks BY NAME
WITH src AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY sessionId
            ORDER BY filename, _rownum_in_file
        ) - 1 AS _row_index_in_session
    FROM _raw_jsonl
),
exploded AS (
    SELECT
        s.sessionId AS session_id,
        s.timestamp::TIMESTAMP WITH TIME ZONE AS ts,
        s.cwd,
        s.type AS row_type,
        unnest(s.message.content) AS block,
        generate_subscripts(s.message.content, 1) - 1 AS block_index,
        s._row_index_in_session AS row_index_in_session
    FROM src s
    WHERE s.type IN ('user', 'assistant')
      AND s.message.content IS NOT NULL
),
normalized AS (
    SELECT
        e.*,
        json_extract_string(e.block::JSON, '$.type') AS block_type,
        coalesce(
            json_extract_string(e.block::JSON, '$.id'),
            json_extract_string(e.block::JSON, '$.tool_use_id')
        ) AS tool_use_id,
        json_extract_string(e.block::JSON, '$.name') AS tool_name,
        json_extract_string(e.block::JSON, '$.input.command') AS command_text,
        json_extract_string(e.block::JSON, '$.input.file_path') AS input_file_path,
        json_extract_string(e.block::JSON, '$.input.url') AS input_url,
        coalesce(
            json_extract_string(e.block::JSON, '$.text'),
            json_extract_string(e.block::JSON, '$.content'),
            ''
        ) AS block_text,
        coalesce(json_extract_string(e.block::JSON, '$.content'), '') AS block_content,
        try_cast(json_extract(e.block::JSON, '$.is_error') AS BOOLEAN) AS is_error
    FROM exploded e
)
SELECT
    md5(n.session_id || '|' || n.row_index_in_session || '|' || n.block_index) AS block_id,
    j.row_id,
    j.file_id,
    n.session_id,
    n.row_index_in_session::UINTEGER AS row_index_in_session,
    n.block_index::UINTEGER AS block_index,
    n.row_type,
    n.block_type,
    n.ts AS "timestamp",
    n.cwd,
    regexp_extract(n.cwd, '([^/]+)$', 1) AS project,
    j.environment,
    n.tool_use_id,
    n.tool_name,
    -- Coarse tool family bucketing — adjust to taste
    CASE
        WHEN n.tool_name = 'Bash' THEN 'shell'
        WHEN n.tool_name IN ('Read', 'NotebookRead') THEN 'file_read'
        WHEN n.tool_name IN ('Edit', 'Write', 'NotebookEdit') THEN 'file_write'
        WHEN n.tool_name IN ('Grep', 'Glob') THEN 'file_search'
        WHEN n.tool_name IN ('TodoWrite', 'Task', 'TaskCreate', 'TaskUpdate') THEN 'planning'
        WHEN n.tool_name IN ('Agent', 'TaskOutput') THEN 'delegation'
        WHEN n.tool_name IN ('WebFetch', 'WebSearch') THEN 'web'
        WHEN starts_with(n.tool_name, 'mcp__') THEN 'mcp'
        ELSE 'other'
    END AS tool_family,
    NULL AS input_keys,
    -- Bash-specific extracted fields
    regexp_extract(coalesce(n.command_text, ''), '^(\S+)') AS command_verb,
    coalesce(length(n.command_text), 0)::UINTEGER AS command_chars,
    coalesce(len(string_split(n.command_text, '\n')), 1)::UINTEGER AS command_lines,
    contains(coalesce(n.command_text, ''), '|') AS command_has_pipe,
    contains(coalesce(n.command_text, ''), '>') AS command_has_redirect,
    contains(coalesce(n.command_text, ''), '$(') AS command_has_subshell,
    substr(coalesce(n.command_text, ''), 1, 500) AS command_preview,
    md5(coalesce(n.command_text, '')) AS command_hash,
    n.input_file_path AS file_path,
    regexp_extract(n.input_file_path, '\.([^.]+)$', 1) AS file_extension,
    regexp_extract(coalesce(n.input_url, ''), 'https?://([^/]+)', 1) AS url_domain,
    -- tool_result fields
    n.is_error AS result_is_error,
    NULL AS result_exit_code,
    length(n.block_text)::UBIGINT AS result_chars,
    md5(n.block_text) AS result_hash,
    substr(n.block_text, 1, 500) AS result_preview,
    -- Keyword flags (regex-based; tune to your corpus)
    regexp_matches(lower(n.block_content), '(error|exception|traceback|failed)') AS keyword_error,
    regexp_matches(lower(n.block_content), '(unauth|401|403|forbidden|invalid token|expired)') AS keyword_auth,
    regexp_matches(lower(n.block_content), '(not found|404|no such file|does not exist)') AS keyword_not_found,
    regexp_matches(lower(n.block_content), '(timeout|timed out|deadline)') AS keyword_timeout,
    regexp_matches(lower(n.block_content), '(passed|passing|tests pass|test pass|build success|lint clean|typecheck pass|0 errors|all green)') AS keyword_test,
    regexp_matches(lower(n.block_content), '(commit|push|merge|branch|HEAD)') AS keyword_git,
    regexp_matches(lower(n.block_content), '(success|done|complete)') AS keyword_success
FROM normalized n
JOIN jsonl_rows j
  ON j.session_id = n.session_id
 AND j.row_index_in_session = n.row_index_in_session;


-- ----------------------------------------------------------------------------
-- 3. assistant_turns: aggregate content_blocks per assistant message
-- ----------------------------------------------------------------------------
INSERT INTO assistant_turns BY NAME
WITH per_turn AS (
    SELECT
        session_id,
        row_index_in_session,
        any_value(timestamp) AS ts,
        any_value(cwd) AS cwd,
        any_value(project) AS project,
        sum(CASE WHEN block_type = 'text' THEN 1 ELSE 0 END)::UINTEGER AS text_block_count,
        sum(CASE WHEN block_type = 'tool_use' THEN 1 ELSE 0 END)::UINTEGER AS tool_use_count,
        sum(CASE WHEN block_type = 'thinking' THEN 1 ELSE 0 END)::UINTEGER AS thinking_block_count,
        sum(CASE WHEN block_type = 'text' THEN result_chars ELSE 0 END)::UBIGINT AS text_chars,
        string_agg(CASE WHEN block_type = 'text' THEN result_preview END, ' ' ORDER BY block_index) AS concatenated_text
    FROM content_blocks
    WHERE row_type = 'assistant'
    GROUP BY session_id, row_index_in_session
)
SELECT
    md5(session_id || '|' || row_index_in_session) AS assistant_turn_id,
    NULL::UBIGINT AS row_id,
    NULL::UBIGINT AS file_id,
    session_id,
    row_index_in_session,
    row_number() OVER (PARTITION BY session_id ORDER BY row_index_in_session)::UINTEGER - 1 AS assistant_index_in_session,
    ts AS "timestamp",
    cwd,
    project,
    NULL AS environment,
    -- model/version come from jsonl_rows; need to JOIN
    (SELECT message_model FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS model,
    (SELECT version FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS "version",
    (SELECT stop_reason FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS stop_reason,
    text_block_count,
    tool_use_count,
    thinking_block_count,
    text_chars,
    md5(coalesce(concatenated_text, '')) AS text_hash,
    substr(coalesce(concatenated_text, ''), 1, 500) AS text_preview,
    -- Completion-claim heuristic: lead-of-message keywords
    regexp_matches(lower(coalesce(concatenated_text, '')), '\b(done|complete|completed|fixed|shipped|merged|implemented|all set|ready for review)\b') AS completion_claim,
    -- Verification-claim heuristic
    regexp_matches(lower(coalesce(concatenated_text, '')), '(tests? pass|build success|build successful|0 errors|all green|lint clean|typecheck pass|all checks pass)') AS verification_claim,
    (SELECT input_tokens FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS input_tokens,
    (SELECT output_tokens FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS output_tokens,
    (SELECT cache_creation_input_tokens FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS cache_creation_input_tokens,
    (SELECT cache_read_input_tokens FROM jsonl_rows j WHERE j.session_id = pt.session_id AND j.row_index_in_session = pt.row_index_in_session) AS cache_read_input_tokens
FROM per_turn pt;


-- ----------------------------------------------------------------------------
-- 4. human_messages: extract user-role rows containing human text
-- ----------------------------------------------------------------------------
INSERT INTO human_messages BY NAME
WITH per_message AS (
    SELECT
        session_id,
        row_index_in_session,
        any_value("timestamp") AS "timestamp",
        any_value(cwd) AS cwd,
        any_value(project) AS project,
        any_value(environment) AS environment,
        sum(result_chars)::UBIGINT AS prompt_chars,
        string_agg(result_preview, ' ' ORDER BY block_index) AS prompt_text
    FROM content_blocks
    WHERE row_type = 'user'
      AND block_type = 'text'
    GROUP BY session_id, row_index_in_session
)
SELECT
    md5(p.session_id || '|' || p.row_index_in_session) AS human_message_id,
    j.row_id,
    j.file_id,
    p.session_id,
    p.row_index_in_session,
    row_number() OVER (
        PARTITION BY p.session_id
        ORDER BY p.row_index_in_session
    )::UINTEGER - 1 AS human_index_in_session,
    p."timestamp",
    p.cwd,
    p.project,
    p.environment,
    p.prompt_chars,
    md5(coalesce(p.prompt_text, '')) AS prompt_hash,
    substr(coalesce(p.prompt_text, ''), 1, 500) AS prompt_preview
FROM per_message p
JOIN jsonl_rows j
  ON j.session_id = p.session_id
 AND j.row_index_in_session = p.row_index_in_session;


-- ----------------------------------------------------------------------------
-- 5. tool_events: join tool_use blocks with their tool_result blocks
-- ----------------------------------------------------------------------------
-- Two-pass: first build event-keyed table, then add sequencing via window funcs.
INSERT INTO tool_events BY NAME
WITH tool_uses AS (
    SELECT * FROM content_blocks WHERE block_type = 'tool_use'
),
tool_results AS (
    SELECT * FROM content_blocks WHERE block_type = 'tool_result'
),
joined AS (
    SELECT
        u.session_id,
        u.row_index_in_session,
        u.block_index,
        u.tool_use_id,
        u.tool_name,
        u.tool_family,
        u.cwd,
        u.project,
        u.environment,
        u."timestamp",
        u.command_verb,
        u.command_chars,
        u.command_lines,
        u.command_has_pipe,
        u.command_has_redirect,
        u.command_has_subshell,
        u.command_preview,
        u.command_hash,
        u.file_path,
        u.file_extension,
        u.url_domain,
        r.row_index_in_session AS result_row_index_in_session,
        r.block_id AS result_block_id,
        r.result_is_error,
        r.result_exit_code,
        r.result_chars,
        r.result_hash,
        r.result_preview,
        r.keyword_error AS result_keyword_error,
        r.keyword_auth AS result_keyword_auth,
        r.keyword_not_found AS result_keyword_not_found,
        r.keyword_timeout AS result_keyword_timeout,
        r.keyword_test AS result_keyword_test,
        r.keyword_git AS result_keyword_git,
        r.keyword_success AS result_keyword_success
    FROM tool_uses u
    LEFT JOIN tool_results r
      ON r.session_id = u.session_id
     AND r.tool_use_id = u.tool_use_id
),
-- Nearest human message on either side of each tool event, by session row
-- index. human_messages is already populated at this point in the script.
with_humans AS (
    SELECT
        joined.*,
        (
            SELECT max(h.row_index_in_session)
            FROM human_messages h
            WHERE h.session_id = joined.session_id
              AND h.row_index_in_session < joined.row_index_in_session
        ) AS _prev_human_row,
        (
            SELECT min(h.row_index_in_session)
            FROM human_messages h
            WHERE h.session_id = joined.session_id
              AND h.row_index_in_session > joined.row_index_in_session
        ) AS _next_human_row
    FROM joined
)
SELECT
    md5(session_id || '|' || row_index_in_session || '|' || block_index) AS tool_event_id,
    session_id,
    row_number() OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index)::UINTEGER - 1 AS event_index,
    NULL::UBIGINT AS row_id,
    NULL::UBIGINT AS file_id,
    row_index_in_session,
    block_index,
    "timestamp",
    cwd, project, environment,
    NULL AS model, NULL AS "version",
    tool_use_id, tool_name, tool_family,
    NULL AS input_keys,
    command_verb, command_chars, command_lines,
    command_has_pipe, command_has_redirect, command_has_subshell,
    command_preview, command_hash,
    file_path, file_extension, url_domain,
    NULL::UBIGINT AS result_row_id,
    result_block_id,
    result_row_index_in_session,
    result_is_error, result_exit_code, result_chars, result_hash, result_preview,
    result_keyword_error, result_keyword_auth, result_keyword_not_found,
    result_keyword_timeout, result_keyword_test, result_keyword_git, result_keyword_success,
    lag(tool_name)  OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index) AS previous_tool_name,
    lag(tool_family) OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index) AS previous_tool_family,
    lead(tool_name) OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index) AS next_tool_name,
    lead(tool_family) OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index) AS next_tool_family,
    lead(result_is_error) OVER (PARTITION BY session_id ORDER BY row_index_in_session, block_index) AS next_result_is_error,
    -- Distances are session-row deltas to the nearest human message; the tool
    -- counts are 1-based positions within the run between two human messages.
    -- All four are NULL when no human message exists on that side.
    (row_index_in_session - _prev_human_row)::UINTEGER AS distance_from_previous_human_message,
    (_next_human_row - row_index_in_session)::UINTEGER AS distance_to_next_human_message,
    CASE WHEN _prev_human_row IS NOT NULL THEN
        row_number() OVER (
            PARTITION BY session_id, _prev_human_row
            ORDER BY row_index_in_session, block_index
        )::UINTEGER
    END AS tools_since_previous_human,
    CASE WHEN _next_human_row IS NOT NULL THEN
        row_number() OVER (
            PARTITION BY session_id, _next_human_row
            ORDER BY row_index_in_session DESC, block_index DESC
        )::UINTEGER
    END AS tools_until_next_human
FROM with_humans;


-- ----------------------------------------------------------------------------
-- 6. session_metrics: per-session aggregations
-- ----------------------------------------------------------------------------
INSERT INTO session_metrics BY NAME
SELECT
    session_id,
    count(DISTINCT source_blob)::UINTEGER AS source_files,
    min("timestamp") AS first_timestamp,
    max("timestamp") AS last_timestamp,
    count(*)::UBIGINT AS "rows",
    (SELECT count(*) FROM human_messages hm WHERE hm.session_id = j.session_id)::UBIGINT AS human_messages,
    sum(CASE WHEN row_type = 'assistant' THEN 1 ELSE 0 END)::UBIGINT AS assistant_turns,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id)::UBIGINT AS tool_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.result_block_id IS NOT NULL)::UBIGINT AS tool_results,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND (te.result_is_error OR te.result_keyword_error))::UBIGINT AS error_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.result_is_error)::UBIGINT AS explicit_error_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.result_keyword_test)::UBIGINT AS test_result_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.result_keyword_git)::UBIGINT AS git_result_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_name = 'Bash')::UBIGINT AS bash_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'file_read')::UBIGINT AS read_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'file_write')::UBIGINT AS edit_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'file_search')::UBIGINT AS file_search_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'planning')::UBIGINT AS planning_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'delegation')::UBIGINT AS delegation_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'web')::UBIGINT AS web_events,
    (SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'mcp')::UBIGINT AS browser_mcp_events,
    any_value(cwd) AS first_cwd,
    mode(project) AS primary_project,
    mode(environment) AS primary_environment,
    string_agg(DISTINCT message_model, ',' ORDER BY message_model) AS models,
    string_agg(DISTINCT version, ',' ORDER BY version) AS versions,
    ((SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id)::DOUBLE
        / NULLIF((SELECT count(*) FROM human_messages hm WHERE hm.session_id = j.session_id), 0)
    ) AS tool_calls_per_human_message,
    ((SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'file_write')::DOUBLE
        / NULLIF((SELECT count(*) FROM tool_events te WHERE te.session_id = j.session_id AND te.tool_family = 'file_read'), 0)
    ) AS edit_to_read_ratio
FROM jsonl_rows j
GROUP BY session_id;

DROP TABLE _raw_jsonl;
