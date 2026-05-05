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
-- This pipeline populates the FOUR base tables that can be derived purely
-- from the JSONL: jsonl_rows, content_blocks, human_messages, assistant_turns,
-- tool_events, and session_metrics.
--
-- The progress_events and corpus_files tables are optional and depend on
-- additional metadata not present in raw JSONL (file mtime, etc.).
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
    row_number() OVER (PARTITION BY sessionId ORDER BY _rownum_in_file)::UINTEGER - 1 AS row_index_in_session,
    type AS row_type,
    timestamp::TIMESTAMP WITH TIME ZONE AS "timestamp",
    cwd,
    -- "project" is a derived label; here we use the parent directory name
    regexp_extract(cwd, '([^/]+)$', 1) AS project,
    -- "environment" is a tag the user may apply; default to hostname
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
FROM (
    SELECT
        *,
        filename,
        row_number() OVER (PARTITION BY filename) - 1 AS _rownum_in_file
    FROM read_json(getvariable('jsonl_glob'), format='newline_delimited', filename=true, union_by_name=true, ignore_errors=true)
);


-- ----------------------------------------------------------------------------
-- 2. content_blocks: explode message.content arrays into individual blocks
-- ----------------------------------------------------------------------------
-- This requires the original JSONL again to access the nested content arrays.
INSERT INTO content_blocks BY NAME
WITH src AS (
    SELECT *
    FROM read_json(getvariable('jsonl_glob'), format='newline_delimited', filename=true, union_by_name=true, ignore_errors=true)
),
exploded AS (
    SELECT
        s.sessionId AS session_id,
        s.timestamp::TIMESTAMP WITH TIME ZONE AS ts,
        s.cwd,
        s.type AS row_type,
        unnest(s.message.content) AS block,
        generate_subscripts(s.message.content, 1) - 1 AS block_index,
        row_number() OVER (PARTITION BY s.sessionId ORDER BY s.timestamp) - 1 AS row_index_in_session
    FROM src s
    WHERE s.type IN ('user', 'assistant')
      AND s.message.content IS NOT NULL
)
SELECT
    md5(session_id || '|' || row_index_in_session || '|' || block_index) AS block_id,
    NULL::UBIGINT AS row_id,
    NULL::UBIGINT AS file_id,
    session_id,
    row_index_in_session::UINTEGER,
    block_index::UINTEGER,
    row_type,
    block.type AS block_type,
    ts AS "timestamp",
    cwd,
    regexp_extract(cwd, '([^/]+)$', 1) AS project,
    NULL AS environment,
    block.id AS tool_use_id,
    block.name AS tool_name,
    -- Coarse tool family bucketing — adjust to taste
    CASE
        WHEN block.name = 'Bash' THEN 'shell'
        WHEN block.name IN ('Read', 'NotebookRead') THEN 'file_read'
        WHEN block.name IN ('Edit', 'Write', 'NotebookEdit') THEN 'file_write'
        WHEN block.name IN ('Grep', 'Glob') THEN 'file_search'
        WHEN block.name IN ('TodoWrite', 'Task', 'TaskCreate', 'TaskUpdate') THEN 'planning'
        WHEN block.name IN ('Agent', 'TaskOutput') THEN 'delegation'
        WHEN block.name IN ('WebFetch', 'WebSearch') THEN 'web'
        WHEN starts_with(block.name, 'mcp__') THEN 'mcp'
        ELSE 'other'
    END AS tool_family,
    NULL AS input_keys,
    -- Bash-specific extracted fields
    regexp_extract(coalesce(block.input.command, ''), '^(\S+)') AS command_verb,
    coalesce(length(block.input.command), 0)::UINTEGER AS command_chars,
    coalesce(len(string_split(block.input.command, '\n')), 1)::UINTEGER AS command_lines,
    contains(coalesce(block.input.command, ''), '|') AS command_has_pipe,
    contains(coalesce(block.input.command, ''), '>') AS command_has_redirect,
    contains(coalesce(block.input.command, ''), '$(') AS command_has_subshell,
    substr(coalesce(block.input.command, ''), 1, 500) AS command_preview,
    md5(coalesce(block.input.command, '')) AS command_hash,
    block.input.file_path AS file_path,
    regexp_extract(block.input.file_path, '\.([^.]+)$', 1) AS file_extension,
    regexp_extract(coalesce(block.input.url, ''), 'https?://([^/]+)', 1) AS url_domain,
    -- tool_result fields
    block.is_error AS result_is_error,
    NULL AS result_exit_code,
    coalesce(length(block.content::VARCHAR), 0)::UBIGINT AS result_chars,
    md5(coalesce(block.content::VARCHAR, '')) AS result_hash,
    substr(coalesce(block.content::VARCHAR, ''), 1, 500) AS result_preview,
    -- Keyword flags (regex-based; tune to your corpus)
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(error|exception|traceback|failed)') AS keyword_error,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(unauth|401|403|forbidden|invalid token|expired)') AS keyword_auth,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(not found|404|no such file|does not exist)') AS keyword_not_found,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(timeout|timed out|deadline)') AS keyword_timeout,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(passed|passing|tests pass|test pass|build success|lint clean|typecheck pass|0 errors|all green)') AS keyword_test,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(commit|push|merge|branch|HEAD)') AS keyword_git,
    regexp_matches(lower(coalesce(block.content::VARCHAR, '')), '(success|done|complete)') AS keyword_success
FROM exploded;


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
-- 4. human_messages: extract user-role rows
-- ----------------------------------------------------------------------------
INSERT INTO human_messages BY NAME
SELECT
    md5(session_id || '|' || row_index_in_session) AS human_message_id,
    NULL::UBIGINT AS row_id,
    NULL::UBIGINT AS file_id,
    session_id,
    row_index_in_session,
    row_number() OVER (PARTITION BY session_id ORDER BY row_index_in_session)::UINTEGER - 1 AS human_index_in_session,
    "timestamp",
    cwd,
    project,
    environment,
    message_chars AS prompt_chars,
    message_hash AS prompt_hash,
    message_preview AS prompt_preview
FROM jsonl_rows
WHERE row_type = 'user';


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
    NULL::UINTEGER AS distance_from_previous_human_message,
    NULL::UINTEGER AS distance_to_next_human_message,
    NULL::UINTEGER AS tools_since_previous_human,
    NULL::UINTEGER AS tools_until_next_human
FROM joined;


-- ----------------------------------------------------------------------------
-- 6. session_metrics: per-session aggregations
-- ----------------------------------------------------------------------------
INSERT INTO session_metrics BY NAME
SELECT
    session_id,
    1::UINTEGER AS source_files,
    min("timestamp") AS first_timestamp,
    max("timestamp") AS last_timestamp,
    count(*)::UBIGINT AS "rows",
    sum(CASE WHEN row_type = 'user' THEN 1 ELSE 0 END)::UBIGINT AS human_messages,
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
    NULL::DOUBLE AS tool_calls_per_human_message,
    NULL::DOUBLE AS edit_to_read_ratio
FROM jsonl_rows j
GROUP BY session_id;
