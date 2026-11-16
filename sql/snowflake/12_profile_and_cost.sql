-- Measurement runbook only. No timings, operator counts, or credit results are asserted.
USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'p2p_profile_baseline';

-- Keep warehouse size, data state (BASE or corrected), session settings and query
-- text fixed across comparisons. Warm warehouse cache is distinct from result cache.
SELECT s.category, DATE_TRUNC('month', f.invoice_date)::DATE AS invoice_month,
       SUM(f.invoiced_amount_cents) AS spend_cents,
       COUNT(DISTINCT f.invoice_id) AS invoice_count
FROM MART.FACT_INVOICE f
JOIN MART.DIM_SUPPLIER s ON s.supplier_key = f.supplier_key
WHERE f.invoice_date <= '2025-03-31'::DATE
GROUP BY s.category, DATE_TRUNC('month', f.invoice_date)::DATE
ORDER BY s.category, invoice_month;
SET profile_query_id = LAST_QUERY_ID();
SELECT $profile_query_id AS measured_query_id;

-- Available for supported completed queries; inspect actual output, not estimates.
-- Use this query ID to open the Query Profile in Snowsight as well.
SELECT * FROM TABLE(GET_QUERY_OPERATOR_STATS($profile_query_id));
SELECT query_id, query_tag, warehouse_name, warehouse_size, execution_status,
       total_elapsed_time, compilation_time, execution_time,
       queued_provisioning_time, queued_overload_time,
       bytes_scanned, partitions_scanned, partitions_total,
       bytes_spilled_to_local_storage, bytes_spilled_to_remote_storage,
       rows_produced, percentage_scanned_from_cache
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
WHERE query_id = $profile_query_id;

-- Inspect scan pruning, join input/output row counts, spills and dominant operators.
-- Do not join payment allocations directly to invoice lines to make a faster-looking
-- but wrong result. Check correctness with 09_validate_marts.sql before timing.
-- Repeat the measured SELECT and capture a new query ID for each run; report cold
-- and warm conditions separately. Record the median and range only after actual runs.

-- OPTIONAL ADMINISTRATOR SECTION. ACCOUNT_USAGE visibility is NOT granted to the
-- loader or reader. Run only with an existing authorized monitoring role; views lag.
-- Query-level compute attribution does not include all warehouse idle/billing costs.
SELECT query_id, warehouse_name, start_time, end_time,
       credits_attributed_compute, credits_used_query_acceleration
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE query_id = $profile_query_id;

-- Pick an explicit observed experiment window before executing these statements.
-- Replace these example bounds with the real UTC run window; do not infer dollars
-- without the account's contracted credit price. Never sum per-query elapsed time
-- and call it warehouse credits.
SET measurement_start = '2025-03-31 00:00:00'::TIMESTAMP_LTZ;
SET measurement_end = '2025-04-01 00:00:00'::TIMESTAMP_LTZ;
SELECT warehouse_name, start_time, end_time, credits_used_compute,
       credits_used_cloud_services, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'P2P_WH'
  AND start_time < $measurement_end AND end_time > $measurement_start
ORDER BY start_time;
-- Metering uses hourly buckets; overlapping buckets need not equal the exact
-- experiment interval, and other sessions can share their cost. Use an isolated
-- run window and disclose cache state, concurrency, resume and minimum billing.
-- XSMALL with AUTO_SUSPEND=60/AUTO_RESUME=TRUE is a configuration, not cost evidence.
ALTER SESSION UNSET QUERY_TAG;
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
