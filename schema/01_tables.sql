-- ============================================================================
-- claude-code-ops-audit — base table schema
-- ============================================================================
-- These are the 8 base tables of the Claude Code event mart. They are populated
-- from raw Claude Code session JSONL files (typically found in
-- ~/.claude/projects/<project>/<session-id>.jsonl).
--
-- Pipeline:
--   1. corpus_files   — file-level metadata (one row per JSONL file)
--   2. jsonl_rows     — one row per JSONL line, with parsed message metadata
--   3. content_blocks — one row per content block within an assistant or user message
--   4. assistant_turns — one row per assistant message, with aggregated content metrics
--   5. human_messages  — one row per user message
--   6. tool_events     — one row per tool_use, joined with its corresponding tool_result
--   7. progress_events — hook events, agent events, etc.
--   8. session_metrics — per-session aggregations
--
-- The derived views in 02_views.sql layer on top of these tables.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- corpus_files
-- File-level metadata. One row per ingested JSONL file.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS corpus_files (
    file_id          UBIGINT,
    source_blob      VARCHAR,        -- original file path or blob URI
    source_uri       VARCHAR,        -- canonical URI form
    local_path       VARCHAR,        -- path on local disk after download
    path_session_id  VARCHAR,        -- session_id parsed from filename if present
    blob_day         DATE,           -- date extracted from path or mtime
    blob_month       VARCHAR,        -- YYYY-MM bucket
    indexed_bytes    UBIGINT,
    local_bytes      UBIGINT,
    downloaded       BOOLEAN,
    local_mtime      TIMESTAMP
);


-- ----------------------------------------------------------------------------
-- jsonl_rows
-- One row per line in the JSONL file. Parsed message metadata, NOT the full
-- content blocks (those go in content_blocks).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS jsonl_rows (
    row_id                       UBIGINT,
    file_id                      UBIGINT,
    source_blob                  VARCHAR,
    session_id                   VARCHAR,
    path_session_id              VARCHAR,
    row_index_in_file            UINTEGER,
    row_index_in_session         UINTEGER,
    row_type                     VARCHAR,        -- 'user', 'assistant', 'tool_result', etc.
    "timestamp"                  TIMESTAMP WITH TIME ZONE,
    cwd                          VARCHAR,
    project                      VARCHAR,
    environment                  VARCHAR,        -- 'macbook', 'server', etc.
    "version"                    VARCHAR,        -- Claude Code version, e.g. '2.1.119'
    git_branch                   VARCHAR,
    entrypoint                   VARCHAR,
    user_type                    VARCHAR,
    permission_mode              VARCHAR,
    uuid                         VARCHAR,
    parent_uuid                  VARCHAR,
    is_sidechain                 BOOLEAN,        -- subagent execution
    request_id                   VARCHAR,
    message_model                VARCHAR,        -- e.g. 'claude-opus-4-7'
    stop_reason                  VARCHAR,
    input_tokens                 UBIGINT,
    output_tokens                UBIGINT,
    cache_creation_input_tokens  UBIGINT,
    cache_read_input_tokens      UBIGINT,
    content_block_count          UINTEGER,
    message_chars                UBIGINT,
    message_hash                 VARCHAR,
    message_preview              VARCHAR         -- truncated at 500 chars
);


-- ----------------------------------------------------------------------------
-- content_blocks
-- One row per content block within an assistant or user message.
-- Block types: 'text', 'tool_use', 'tool_result', 'thinking'.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS content_blocks (
    block_id              VARCHAR,
    row_id                UBIGINT,
    file_id               UBIGINT,
    session_id            VARCHAR,
    row_index_in_session  UINTEGER,
    block_index           UINTEGER,
    row_type              VARCHAR,        -- 'user', 'assistant'
    block_type            VARCHAR,        -- 'text', 'tool_use', 'tool_result', 'thinking'
    "timestamp"           TIMESTAMP WITH TIME ZONE,
    cwd                   VARCHAR,
    project               VARCHAR,
    environment           VARCHAR,

    -- tool_use fields
    tool_use_id           VARCHAR,
    tool_name             VARCHAR,
    tool_family           VARCHAR,        -- coarse grouping: 'shell', 'file_read', 'file_write', etc.
    input_keys            VARCHAR,        -- comma-separated input parameter names

    -- bash-specific extracted fields (when tool_name='Bash')
    command_verb          VARCHAR,        -- first word of the command
    command_chars         UINTEGER,
    command_lines         UINTEGER,
    command_has_pipe      BOOLEAN,
    command_has_redirect  BOOLEAN,
    command_has_subshell  BOOLEAN,
    command_preview       VARCHAR,        -- truncated at 500 chars
    command_hash          VARCHAR,

    -- file-tool-specific fields
    file_path             VARCHAR,
    file_extension        VARCHAR,
    url_domain            VARCHAR,        -- for WebFetch

    -- tool_result fields
    result_is_error       BOOLEAN,
    result_exit_code      INTEGER,
    result_chars          UBIGINT,
    result_hash           VARCHAR,
    result_preview        VARCHAR,        -- truncated at 500 chars

    -- keyword flags applied to result_preview
    keyword_error         BOOLEAN,
    keyword_auth          BOOLEAN,
    keyword_not_found     BOOLEAN,
    keyword_timeout       BOOLEAN,
    keyword_test          BOOLEAN,
    keyword_git           BOOLEAN,
    keyword_success       BOOLEAN
);


-- ----------------------------------------------------------------------------
-- assistant_turns
-- One row per assistant message. Aggregated metrics over content blocks.
-- The completion_claim and verification_claim flags are keyword heuristics
-- applied to the concatenated text content (see ingest pipeline).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS assistant_turns (
    assistant_turn_id            VARCHAR,
    row_id                       UBIGINT,
    file_id                      UBIGINT,
    session_id                   VARCHAR,
    row_index_in_session         UINTEGER,
    assistant_index_in_session   UINTEGER,
    "timestamp"                  TIMESTAMP WITH TIME ZONE,
    cwd                          VARCHAR,
    project                      VARCHAR,
    environment                  VARCHAR,
    model                        VARCHAR,
    "version"                    VARCHAR,
    stop_reason                  VARCHAR,

    text_block_count             UINTEGER,
    tool_use_count               UINTEGER,
    thinking_block_count         UINTEGER,
    text_chars                   UBIGINT,
    text_hash                    VARCHAR,
    text_preview                 VARCHAR,    -- 500 char preview of concatenated text blocks

    -- keyword heuristics applied to concatenated text content
    completion_claim             BOOLEAN,    -- "done", "complete", "fixed", "shipped", etc.
    verification_claim           BOOLEAN,    -- "tests passed", "build succeeded", etc.

    input_tokens                 UBIGINT,
    output_tokens                UBIGINT,
    cache_creation_input_tokens  UBIGINT,
    cache_read_input_tokens      UBIGINT
);


-- ----------------------------------------------------------------------------
-- human_messages
-- One row per user-role message containing at least one human text block.
-- Tool-result-only user rows are excluded.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS human_messages (
    human_message_id          VARCHAR,
    row_id                    UBIGINT,
    file_id                   UBIGINT,
    session_id                VARCHAR,
    row_index_in_session      UINTEGER,
    human_index_in_session    UINTEGER,
    "timestamp"               TIMESTAMP WITH TIME ZONE,
    cwd                       VARCHAR,
    project                   VARCHAR,
    environment               VARCHAR,
    prompt_chars              UBIGINT,
    prompt_hash               VARCHAR,
    prompt_preview            VARCHAR
);


-- ----------------------------------------------------------------------------
-- tool_events
-- One row per tool_use, joined with its corresponding tool_result.
-- Adds sequencing info (previous/next tool, distances to human messages).
-- This is the main analysis table for tool behavior.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tool_events (
    tool_event_id                         VARCHAR,
    session_id                            VARCHAR,
    event_index                           UINTEGER,
    row_id                                UBIGINT,
    file_id                               UBIGINT,
    row_index_in_session                  UINTEGER,
    block_index                           UINTEGER,
    "timestamp"                           TIMESTAMP WITH TIME ZONE,
    cwd                                   VARCHAR,
    project                               VARCHAR,
    environment                           VARCHAR,
    model                                 VARCHAR,
    "version"                             VARCHAR,

    -- tool call fields
    tool_use_id                           VARCHAR,
    tool_name                             VARCHAR,
    tool_family                           VARCHAR,
    input_keys                            VARCHAR,

    -- bash-specific
    command_verb                          VARCHAR,
    command_chars                         UINTEGER,
    command_lines                         UINTEGER,
    command_has_pipe                      BOOLEAN,
    command_has_redirect                  BOOLEAN,
    command_has_subshell                  BOOLEAN,
    command_preview                       VARCHAR,
    command_hash                          VARCHAR,

    -- file/url fields
    file_path                             VARCHAR,
    file_extension                        VARCHAR,
    url_domain                            VARCHAR,

    -- joined tool_result fields
    result_row_id                         UBIGINT,
    result_block_id                       VARCHAR,
    result_row_index_in_session           UINTEGER,
    result_is_error                       BOOLEAN,
    result_exit_code                      INTEGER,
    result_chars                          UBIGINT,
    result_hash                           VARCHAR,
    result_preview                        VARCHAR,

    -- keyword flags on result_preview
    result_keyword_error                  BOOLEAN,
    result_keyword_auth                   BOOLEAN,
    result_keyword_not_found              BOOLEAN,
    result_keyword_timeout                BOOLEAN,
    result_keyword_test                   BOOLEAN,
    result_keyword_git                    BOOLEAN,
    result_keyword_success                BOOLEAN,

    -- sequencing
    previous_tool_name                    VARCHAR,
    previous_tool_family                  VARCHAR,
    next_tool_name                        VARCHAR,
    next_tool_family                      VARCHAR,
    next_result_is_error                  BOOLEAN,
    distance_from_previous_human_message  UINTEGER,
    distance_to_next_human_message        UINTEGER,
    tools_since_previous_human            UINTEGER,
    tools_until_next_human                UINTEGER
);


-- ----------------------------------------------------------------------------
-- progress_events
-- Hook events, agent invocations, sub-tasks.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS progress_events (
    progress_event_id     VARCHAR,
    row_id                UBIGINT,
    file_id               UBIGINT,
    session_id            VARCHAR,
    row_index_in_session  UINTEGER,
    "timestamp"           TIMESTAMP WITH TIME ZONE,
    cwd                   VARCHAR,
    project               VARCHAR,
    environment           VARCHAR,
    progress_type         VARCHAR,
    hook_event            VARCHAR,        -- 'PreToolUse', 'PostToolUse', 'Stop', etc.
    hook_name             VARCHAR,
    command_verb          VARCHAR,
    command_preview       VARCHAR,
    command_hash          VARCHAR,
    tool_use_id           VARCHAR,
    parent_tool_use_id    VARCHAR,
    agent_id              VARCHAR,
    has_nested_message    BOOLEAN,
    nested_message_type   VARCHAR
);


-- ----------------------------------------------------------------------------
-- session_metrics
-- One row per session. Pre-aggregated counts to speed up analyses.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_metrics (
    session_id                     VARCHAR,
    source_files                   UINTEGER,
    first_timestamp                TIMESTAMP WITH TIME ZONE,
    last_timestamp                 TIMESTAMP WITH TIME ZONE,
    "rows"                         UBIGINT,
    human_messages                 UBIGINT,
    assistant_turns                UBIGINT,
    tool_events                    UBIGINT,
    tool_results                   UBIGINT,
    error_events                   UBIGINT,
    explicit_error_events          UBIGINT,
    test_result_events             UBIGINT,
    git_result_events              UBIGINT,
    bash_events                    UBIGINT,
    read_events                    UBIGINT,
    edit_events                    UBIGINT,
    file_search_events             UBIGINT,
    planning_events                UBIGINT,
    delegation_events              UBIGINT,
    web_events                     UBIGINT,
    browser_mcp_events             UBIGINT,
    first_cwd                      VARCHAR,
    primary_project                VARCHAR,
    primary_environment            VARCHAR,
    models                         VARCHAR,        -- comma-separated set
    versions                       VARCHAR,        -- comma-separated set
    tool_calls_per_human_message   DOUBLE,
    edit_to_read_ratio             DOUBLE
);
