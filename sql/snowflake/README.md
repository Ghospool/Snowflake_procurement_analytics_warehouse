# Snowflake deployment

These scripts implement the [data contract](../../docs/data-contract.md). All amounts originate as integer USD cents; decimal USD columns are presentation values. Reporting is fixed at **2025-03-31**. No Snowflake account was available during development: these are manually deployable SQL scripts, not evidence of successful Snowflake execution or measured cost.

## Prerequisites

- Generate the six base CSVs, six partial correction CSVs and `data/expected.json` using the project generator. Run the project's local validation first; CSV headers, exact field counts and column order must match the contract. Positional COPY skips the header and does not itself check header names/order; do not treat transformed COPY's column-count format option as an exact-width validator. Header/width enforcement is an external prerequisite to this SQL-only loader.
- Start SnowSQL from the `purchase-to-pay-analytics/` project root. `PUT 'file://data/base/...'` and `PUT 'file://data/corrections/...'` resolve on that client machine, not on Snowflake. Use a Snowflake CLI/client that supports local PUT; Snowsight worksheets alone cannot run the local-file upload step. Some Windows client versions require replacing these relative URLs with quoted absolute `file://C:/...` URLs.
- Configure your own connection/authentication outside the repository. Never paste credentials into SQL.
- Use an authorized deployment role for object creation and `SECURITYADMIN` for role provisioning. Do not run the deployment as the loader. The object owner retains access to underlying RAW objects so STAGING/MART views work through their owner privileges.
- Configure the client to stop on SQL errors. For SnowSQL, start with `snowsql -c <your_connection> -o exit_on_error=true`. Keep one loader active; do not COPY more files while the refresh transaction is running.

## Run order

Run each file explicitly; **do not blindly glob all numbered files**, because correction loading and measurement are optional phases.

| Order | File | Purpose |
| --- | --- | --- |
| 1 | `00_setup.sql` | XSMALL warehouse, 60-second suspension, auto-resume, database, schemas, internal stage and CSV format |
| 2 | `01_landing_tables.sql` | Append-only VARCHAR landing tables with file name, row, content key and scan timestamp |
| 3 | `02_load_base.sql` | Six explicit base PUT/COPY operations using the `base/` stage prefix |
| 4 | `03_staging.sql` | Typed latest-natural-key views, raw parse/conflict and relationship diagnostics |
| 5 | `04_validate_staging.sql` | Show failing source rows; raise an exception if any source gate fails |
| 6 | `05_mart_objects.sql` | Persistent dimensions/facts and full-source MERGE input views |
| 7 | `06_refresh_marts.sql` | Revalidate source; transactionally MERGE dates, SCD2 history and all three facts |
| 8 | `07_analytics.sql` | Fixed-date spend, concentration, exceptions, balances and payment performance |
| 9 | `08_quality_objects.sql` | Deploy the failing-row reconciliation/quality view |
| 10 | `09_validate_marts.sql` | Show failures and raise on a failed mart gate; display deliberate business exceptions separately |
| 11 | `11_roles.sql` | Optional administrator-only provisioning and explicit object grants |
| Later | `10_load_corrections.sql` | Partial correction PUT/COPY operations using a separate `corrections/` prefix |
| Optional | `12_profile_and_cost.sql` | Actual query/operator/cost measurement commands; no invented results |

A first deployment in an interactive SnowSQL session can use the following client commands. `!source` is a SnowSQL command, not server-side SQL. Adapt to your CLI's file execution syntax if needed.

```sql
!source sql/snowflake/00_setup.sql
!source sql/snowflake/01_landing_tables.sql
!source sql/snowflake/02_load_base.sql
!source sql/snowflake/03_staging.sql
!source sql/snowflake/04_validate_staging.sql
!source sql/snowflake/05_mart_objects.sql
!source sql/snowflake/06_refresh_marts.sql
!source sql/snowflake/07_analytics.sql
!source sql/snowflake/08_quality_objects.sql
!source sql/snowflake/09_validate_marts.sql
!source sql/snowflake/11_roles.sql
```

`11_roles.sql` intentionally switches to `SECURITYADMIN`. Have an administrator assign the custom role to the intended user using the commented GRANT examples, then explicitly switch to `P2P_LOADER` for routine work. The loader cannot create objects, administer roles, delete RAW data or alter warehouse sizing. The reader has explicit SELECT grants on curated MART objects only, not RAW/STAGING or broad future-object grants. Regrant newly deployed views when adding/replacing objects; DDL is an owner operation, not routine ingestion.

## Incremental corrections and replay

Corrections are partial upserts. Never overwrite a base file with corrected content; never set COPY `FORCE = TRUE`. Keep each batch's files immutable, use the exact same prefix when replaying it, and finish all six COPY statements before refreshing. A new later batch should use a new immutable prefix and newer source timestamps, not reuse `corrections/` for different bytes.

```sql
USE ROLE P2P_LOADER;
USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
!source sql/snowflake/10_load_corrections.sql
!source sql/snowflake/04_validate_staging.sql
!source sql/snowflake/06_refresh_marts.sql
!source sql/snowflake/09_validate_marts.sql
```

The STAGING winner is greatest `source_updated_at` per natural key, including `(supplier_id, effective_from)` for suppliers. File and ingestion ordering only choose between identical-payload ties: conflicting payloads at the same source timestamp fail validation. Conflict checks inspect all landed versions, not just the selected winner. Nonnegative integer/date/timestamp parsing, required keys, parents, effective supplier coverage, document line-number uniqueness and line presence are gated before MERGE. Invalid optional PO references deliberately survive as exception rows.

Inspect corrected winners and restated supplier history with explicit SQL, and compare monetary changes and stable fixture IDs with `data/expected.json` rather than hard-coding invented expected totals here.

```sql
SELECT payment_id, invoice_id, amount_cents, source_updated_at, batch_id
FROM STAGING.STG_PAYMENTS WHERE batch_id = 'CORRECTION' ORDER BY payment_id;
SELECT invoice_line_id, invoice_id, quantity, unit_price_cents, source_updated_at
FROM STAGING.STG_INVOICE_LINES WHERE batch_id = 'CORRECTION' ORDER BY invoice_line_id;
SELECT d.supplier_id, d.supplier_key, d.category, d.valid_from, d.valid_to, d.is_current
FROM MART.DIM_SUPPLIER d
WHERE d.supplier_id IN (
    SELECT supplier_id FROM STAGING.STG_SUPPLIERS WHERE batch_id = 'CORRECTION'
)
ORDER BY d.supplier_id, d.valid_from;
SELECT * FROM STAGING.MART_QUALITY_FAILURES ORDER BY check_name, record_key;
```

For an identical correction replay, capture row counts and order-independent payload hashes in the same session, replay the four routine files above, and compare the result. The fingerprint is a practical replay diagnostic, not a mathematical collision-proof proof; the row-level checks in `09_validate_marts.sql` remain required.

```sql
SET replay_before = (
    SELECT HASH_AGG(object_name, row_count, payload_hash)
    FROM (
        SELECT 'DIM_DATE' AS object_name, COUNT(*) AS row_count, HASH_AGG(*) AS payload_hash FROM MART.DIM_DATE
        UNION ALL SELECT 'DIM_SUPPLIER', COUNT(*), HASH_AGG(*) FROM MART.DIM_SUPPLIER
        UNION ALL SELECT 'FACT_PURCHASING', COUNT(*), HASH_AGG(*) FROM MART.FACT_PURCHASING
        UNION ALL SELECT 'FACT_INVOICE', COUNT(*), HASH_AGG(*) FROM MART.FACT_INVOICE
        UNION ALL SELECT 'FACT_PAYMENT', COUNT(*), HASH_AGG(*) FROM MART.FACT_PAYMENT
    )
);
!source sql/snowflake/10_load_corrections.sql
!source sql/snowflake/04_validate_staging.sql
!source sql/snowflake/06_refresh_marts.sql
!source sql/snowflake/09_validate_marts.sql
SELECT $replay_before = HASH_AGG(object_name, row_count, payload_hash) AS identical_replay
FROM (
    SELECT 'DIM_DATE' AS object_name, COUNT(*) AS row_count, HASH_AGG(*) AS payload_hash FROM MART.DIM_DATE
    UNION ALL SELECT 'DIM_SUPPLIER', COUNT(*), HASH_AGG(*) FROM MART.DIM_SUPPLIER
    UNION ALL SELECT 'FACT_PURCHASING', COUNT(*), HASH_AGG(*) FROM MART.FACT_PURCHASING
    UNION ALL SELECT 'FACT_INVOICE', COUNT(*), HASH_AGG(*) FROM MART.FACT_INVOICE
    UNION ALL SELECT 'FACT_PAYMENT', COUNT(*), HASH_AGG(*) FROM MART.FACT_PAYMENT
);
```

Expect `identical_replay = TRUE` only after actually executing this procedure. Test base replay before loading corrections by substituting `02_load_base.sql` for `10_load_corrections.sql` in the same procedure. COPY's file load history is finite; physical RAW duplicates can eventually be appended after its deduplication window, but identical-payload staging deduplication still yields the same fact/dimension state. RAW physical row counts are not latest-source business counts.

## Model and semantics

- `DIM_DATE` contains every day of 2025 with integer YYYYMMDD keys. Fact dates outside that range fail validation rather than being silently dropped.
- `DIM_SUPPLIER` uses deterministic `supplier_id || '|' || YYYY-MM-DD` keys, half-open effective intervals, and a final `9999-12-31` end date. All latest supplier versions feed its MERGE. A late version shortens the previous interval; a corrected version restates its attributes. There is no destructive table recreation or delete/truncate phase.
- Purchasing is one PO line; invoicing is one invoice line; payment is one invoice allocation. Facts use the supplier version on order, invoice or payment date respectively. Payment supplier history must not be inferred from the invoice's supplier key.
- Normal matched-row updates require a newer effective source timestamp. A separate changed-payload MERGE branch restates dependency changes even when a fact's own timestamp is unchanged: supplier keys, parent fields, PO match flags, invoice total mismatch and duplicate-number peers. No watermark discards these historical changes. Full-source refresh scans favor transparency at portfolio scale over a production change-dependency framework.
- Duplicate invoice numbers use `UPPER(TRIM(invoice_number))` within supplier; internal whitespace is preserved. The six independent flags overlap. Exception rate counts distinct invoices, never lines or summed flag counts.
- Spend is invoice-line amount, never the sum of commitments, invoices and payments. Concentration ranks stable supplier IDs across their historical versions and uses the full spend denominator. HHI is exposed both as a fraction and on the 0–10,000 scale; shares are NULL if total spend is zero.
- Unmatched spend includes NO_PO and INVALID_PO_REFERENCE separately and jointly, but excludes supplier mismatch alone.
- `INVOICE_TOTALS` aggregates lines first. Payments are independently aggregated by invoice before balances join them. Header totals are repeated on fact lines and are never summed across those lines. Balances use line-derived totals, show header discrepancies, retain negative overpayments and exclude payments after the reporting date.
- Payment performance first aggregates allocations by invoice/day, then finds the first cumulative payment date reaching the line-derived invoice total. Future payments cannot settle an as-of invoice. `days_late` is signed (negative means early) for settled invoices and NULL for unsettled invoices; `signed_days_from_due` is an explicit alias of the same metric, and `overdue_days` measures currently unpaid lateness. A zero-total invoice is settled on invoice date without requiring cash.

## Validation and recovery

`SOURCE_ROW_ERRORS` includes file/row provenance. `SOURCE_VERSION_CONFLICTS` exposes equal-timestamp payload conflicts. `SOURCE_ORDER_ERRORS` rejects previously unseen corrections whose timestamp precedes an already-landed version of the same key; first-arrival grouping lets identical old file replays remain valid. For versions first seen in one COPY scan, timestamp order defines the version order, not physical CSV row order. `RELATIONSHIP_ERRORS` identifies missing parents/versions and duplicate document line numbers. `MART_QUALITY_FAILURES` exposes failing keys, expected values and actual values for source-to-target keys/amounts/counts, supplier history, fact grains, interval/date foreign keys, invoice header consistency, flag calculations, balances and paid-in-full dates. Snowflake standard-table primary/foreign keys are informational: the executable checks are the enforcement mechanism.

A deliberate header mismatch, overpayment or invalid PO reference is not itself an ETL failure; its incorrect amount or flag is. The final diagnostic queries show those business exceptions separately. No observations have been claimed as observed Snowflake results.

If a source gate fails, stop before refresh, inspect the failing rows, and repair/reload through the deployment owner according to the source contract. Append-only history intentionally keeps conflicting/invalid evidence: a malformed historical row or equal-timestamp conflict is not automatically erased by a newer row. Quarantining/removing bad landed evidence requires an explicitly approved administrator repair, not an automatic loader delete. If a mart refresh fails, its DML rolls back as a unit. A separate post-refresh quality failure stops the run but does not undo an already committed refresh; repair the cause and rerun. Do not run concurrent writers.

## Measurement and limitations

Run `12_profile_and_cost.sql` only when deliberately measuring. It disables result reuse, captures the actual measured query ID, requests operator statistics and session history, and separates optional administrator-only attribution/metering queries. Replace the example metering interval with the real observed UTC window. Record data state, warehouse/cache state, query IDs, concurrency, scan/spill statistics and observed credits. Hourly metering, idle/resume billing and attribution are different measures; no fabricated execution time, Query Profile screenshot or dollar saving is supplied. No tasks are provisioned.

The scripts use finite Snowflake NUMBER precision: individual values outside NUMBER(38,0) fail source validation, while products, aggregated totals or USD conversions outside supported precision cause a runtime numeric error and transaction rollback, not a row-level validation result. Full-source MERGEs are intentionally simple, not a high-volume CDC implementation. Natural-key deletes, multi-invoice cash disbursements, reversals, tax, FX, credit notes and receipts are out of scope. Empty or older replays are not deletions. Existing tables/warehouse are preserved with `IF NOT EXISTS`; that does not migrate an incompatible preexisting schema. Redeploy DDL only as the owner, reapply role grants after replaced views, and validate on a real Snowflake account before claiming production readiness.
