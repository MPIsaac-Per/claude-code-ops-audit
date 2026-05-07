-- ============================================================================
-- Codex telemetry, noise-filtered runtime analysis
-- ============================================================================
-- Run against the sanitized telemetry mart produced by:
--   analyses/build_telemetry_mart.py
--
-- Example:
--   duckdb /path/to/telemetry_mart.duckdb < analyses/codex_telemetry_filtered.sql
--
-- The raw Codex/OpenTelemetry export is extremely high-cardinality because
-- stream receive-loop spans and token/text delta log events are emitted many
-- times inside a small number of conversations. This query pack keeps raw
-- coverage visible, then separates low-signal stream/delta noise from
-- operational telemetry.
-- ============================================================================


-- 0. Raw coverage vs filtered operational telemetry.
WITH span_counts AS (
    SELECT
        count(*) AS raw_spans,
        sum(CASE WHEN span_name IN ('receiving', 'handle_responses') THEN 1 ELSE 0 END) AS stream_loop_spans,
        sum(CASE WHEN span_name NOT IN ('receiving', 'handle_responses') THEN 1 ELSE 0 END) AS operational_spans,
        count(DISTINCT trace_id_hash) FILTER (WHERE trace_id_hash <> '') AS raw_traces,
        count(DISTINCT trace_id_hash) FILTER (
            WHERE trace_id_hash <> ''
              AND span_name NOT IN ('receiving', 'handle_responses')
        ) AS operational_traces,
        count(DISTINCT turn_id_hash) FILTER (WHERE turn_id_hash <> '') AS span_turn_ids,
        count(DISTINCT call_id_hash) FILTER (WHERE call_id_hash <> '') AS span_call_ids
    FROM telemetry_spans
),
log_counts AS (
    SELECT
        count(*) AS raw_logs,
        sum(CASE WHEN event_kind LIKE 'response.%.delta' THEN 1 ELSE 0 END) AS response_delta_logs,
        sum(CASE WHEN event_kind IS NULL OR event_kind NOT LIKE 'response.%.delta' THEN 1 ELSE 0 END) AS operational_logs,
        count(DISTINCT conversation_id_hash) FILTER (WHERE conversation_id_hash <> '') AS conversations,
        sum(CASE WHEN event_name = 'codex.user_prompt' THEN 1 ELSE 0 END) AS user_prompts,
        sum(CASE WHEN event_name = 'codex.tool_result' THEN 1 ELSE 0 END) AS tool_results,
        count(DISTINCT conversation_id_hash) FILTER (
            WHERE conversation_id_hash <> ''
              AND event_name = 'codex.tool_result'
        ) AS tool_result_conversations
    FROM telemetry_logs
)
SELECT
    raw_logs,
    response_delta_logs,
    operational_logs,
    round(100.0 * response_delta_logs / raw_logs, 2) AS pct_logs_delta_noise,
    raw_spans,
    stream_loop_spans,
    operational_spans,
    round(100.0 * stream_loop_spans / raw_spans, 2) AS pct_spans_stream_loop_noise,
    raw_traces,
    operational_traces,
    conversations,
    user_prompts,
    span_turn_ids,
    tool_results,
    span_call_ids,
    tool_result_conversations
FROM span_counts, log_counts;


-- 1. Span categories after the receive-loop noise is removed.
WITH classified AS (
    SELECT
        *,
        CASE
            WHEN span_name IN ('receiving', 'handle_responses') THEN 'stream_loop_noise'
            WHEN span_name IN (
                'session_task.turn',
                'run_turn'
            ) THEN 'turn_orchestration'
            WHEN span_name IN (
                'responses_websocket.stream_request',
                'receiving_stream',
                'try_run_sampling_request',
                'run_sampling_request',
                'model_client.stream_responses_websocket',
                'model_client.websocket_connection',
                'stream_request'
            ) THEN 'model_stream_request'
            WHEN span_name IN (
                'build_tool_call',
                'handle_output_item_done',
                'handle_tool_call',
                'handle_tool_call_with_source',
                'dispatch_tool_call',
                'dispatch_tool_call_with_code_mode_result',
                'exec_command'
            ) THEN 'tool_dispatch'
            WHEN span_name LIKE 'app_server.%'
              OR rpc_method <> ''
              OR api_path <> '' THEN 'app_server_rpc'
            WHEN span_name IN (
                'getAuthStatus',
                'account/read',
                'config/read',
                'list_models',
                'get_model_info',
                'experimentalFeature/list',
                'experimentalFeature/enablement/set'
            ) THEN 'config_auth_capability'
            ELSE 'other_operational'
        END AS span_category
    FROM telemetry_spans
)
SELECT
    span_category,
    count(*) AS spans,
    count(DISTINCT trace_id_hash) FILTER (WHERE trace_id_hash <> '') AS traces,
    count(DISTINCT turn_id_hash) FILTER (WHERE turn_id_hash <> '') AS turn_ids,
    count(DISTINCT call_id_hash) FILTER (WHERE call_id_hash <> '') AS call_ids,
    round(avg(duration_ms), 3) AS avg_duration_ms,
    round(quantile_cont(duration_ms, 0.50), 3) AS p50_duration_ms,
    round(quantile_cont(duration_ms, 0.95), 3) AS p95_duration_ms
FROM classified
WHERE span_category <> 'stream_loop_noise'
GROUP BY 1
ORDER BY spans DESC;


-- 2. Top operational spans after receive-loop noise removal.
SELECT
    span_name,
    count(*) AS spans,
    count(DISTINCT trace_id_hash) FILTER (WHERE trace_id_hash <> '') AS traces,
    count(DISTINCT turn_id_hash) FILTER (WHERE turn_id_hash <> '') AS turn_ids,
    count(DISTINCT call_id_hash) FILTER (WHERE call_id_hash <> '') AS call_ids,
    round(avg(duration_ms), 3) AS avg_duration_ms,
    round(quantile_cont(duration_ms, 0.50), 3) AS p50_duration_ms,
    round(quantile_cont(duration_ms, 0.95), 3) AS p95_duration_ms
FROM telemetry_spans
WHERE span_name NOT IN ('receiving', 'handle_responses')
GROUP BY 1
ORDER BY spans DESC
LIMIT 30;


-- 3. Operational log events after response-delta noise removal.
SELECT
    event_name,
    event_kind,
    count(*) AS logs,
    count(DISTINCT conversation_id_hash) FILTER (WHERE conversation_id_hash <> '') AS conversations,
    count(DISTINCT tool_name) FILTER (WHERE tool_name <> '') AS tool_names,
    round(avg(duration_ms), 3) AS avg_duration_ms,
    round(quantile_cont(duration_ms, 0.50), 3) AS p50_duration_ms,
    round(quantile_cont(duration_ms, 0.95), 3) AS p95_duration_ms
FROM telemetry_logs
WHERE event_kind IS NULL
   OR event_kind NOT LIKE 'response.%.delta'
GROUP BY 1, 2
ORDER BY logs DESC
LIMIT 40;


-- 4. Model mix using operational logs only.
SELECT
    model,
    count(*) AS operational_logs,
    count(DISTINCT conversation_id_hash) FILTER (WHERE conversation_id_hash <> '') AS conversations,
    sum(CASE WHEN event_name = 'codex.user_prompt' THEN 1 ELSE 0 END) AS user_prompts,
    sum(CASE WHEN event_name = 'codex.tool_result' THEN 1 ELSE 0 END) AS tool_results
FROM telemetry_logs
WHERE model <> ''
  AND (
      event_kind IS NULL
      OR event_kind NOT LIKE 'response.%.delta'
  )
GROUP BY 1
ORDER BY operational_logs DESC;


-- 5. Per-conversation operational log distribution after delta removal.
WITH per_conversation AS (
    SELECT
        conversation_id_hash,
        count(*) AS operational_logs,
        sum(CASE WHEN event_name = 'codex.user_prompt' THEN 1 ELSE 0 END) AS user_prompts,
        sum(CASE WHEN event_name = 'codex.tool_result' THEN 1 ELSE 0 END) AS tool_results,
        sum(CASE WHEN event_kind = 'response.completed' THEN 1 ELSE 0 END) AS response_completed_events
    FROM telemetry_logs
    WHERE conversation_id_hash <> ''
      AND (
          event_kind IS NULL
          OR event_kind NOT LIKE 'response.%.delta'
      )
    GROUP BY 1
)
SELECT
    count(*) AS conversations,
    sum(operational_logs) AS operational_logs,
    round(avg(operational_logs), 1) AS avg_operational_logs_per_conversation,
    quantile_cont(operational_logs, 0.50) AS p50_operational_logs_per_conversation,
    quantile_cont(operational_logs, 0.90) AS p90_operational_logs_per_conversation,
    quantile_cont(operational_logs, 0.95) AS p95_operational_logs_per_conversation,
    max(operational_logs) AS max_operational_logs_per_conversation,
    sum(user_prompts) AS user_prompts,
    sum(tool_results) AS tool_results,
    sum(response_completed_events) AS response_completed_events
FROM per_conversation;

